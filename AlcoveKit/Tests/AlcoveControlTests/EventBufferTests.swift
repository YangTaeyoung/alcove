import XCTest
@testable import AlcoveControl
import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

/// Polls `condition` every 10 ms until it holds or `timeout` passes; returns whether it held.
func eventually(timeout: Duration = .seconds(20), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Holds callers at `pass` until `open` is called, and counts them.
actor Latch {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    func pass() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

/// Which case `state` is.
private func kind(_ state: AgentLinkState) -> String {
    switch state {
    case .connected: return "connected"
    case .connecting: return "connecting"
    case .notConnected: return "not connected"
    }
}

final class EventBufferTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testSequenceNumbersCountFromOne() async {
        let buffer = EventBuffer()
        let empty = await buffer.since(0)
        XCTAssertTrue(empty.events.isEmpty)
        XCTAssertEqual(empty.next, 0)

        await buffer.append(name: "window.opened", payload: ["title": "A"], at: t0)
        await buffer.append(name: "window.closed", payload: ["title": "A"], at: t0.addingTimeInterval(1))
        let all = await buffer.since(0)
        XCTAssertEqual(all.events, [
            GuestEvent(seq: 1, time: t0, name: "window.opened", payload: ["title": "A"]),
            GuestEvent(seq: 2, time: t0.addingTimeInterval(1), name: "window.closed", payload: ["title": "A"]),
        ])
        XCTAssertEqual(all.next, 2)
    }

    func testSinceReturnsOnlyNewerEvents() async {
        let buffer = EventBuffer()
        for i in 1...5 { await buffer.append(name: "e\(i)", payload: [:], at: t0) }
        let tail = await buffer.since(3)
        XCTAssertEqual(tail.events.map(\.seq), [4, 5])
        XCTAssertEqual(tail.next, 5)
        let none = await buffer.since(5)
        XCTAssertTrue(none.events.isEmpty)
        XCTAssertEqual(none.next, 5)
        let beyond = await buffer.since(Int.max)
        XCTAssertTrue(beyond.events.isEmpty)
        XCTAssertEqual(beyond.next, 5)
        let negative = await buffer.since(-4)
        XCTAssertEqual(negative.events.count, 5)
    }

    func testKeepsTheNewest500() async {
        let buffer = EventBuffer()
        for i in 1...620 { await buffer.append(name: "e", payload: ["i": .int(Int64(i))], at: t0) }
        let all = await buffer.since(0)
        XCTAssertEqual(all.events.count, 500)
        XCTAssertEqual(all.events.first?.seq, 121)
        XCTAssertEqual(all.events.last?.seq, 620)
        XCTAssertEqual(all.next, 620)
        let tail = await buffer.since(618)
        XCTAssertEqual(tail.events.map(\.seq), [619, 620])
    }

    func testEventJSONCarriesSequenceTimeNameAndPayload() {
        let event = GuestEvent(seq: 7, time: Date(timeIntervalSince1970: 1_800_000_000.25), name: "dialog.opened",
                               payload: ["window": ["title": "저장 \"확인\""], "seq": 99, "name": "shadowed"])
        XCTAssertEqual(event.json, ["seq": 7, "time": "2027-01-15T08:00:00.250Z", "name": "dialog.opened",
                                    "window": ["title": "저장 \"확인\""]])
    }

    private func connectedClient(to agent: FakeAgent) async throws -> AgentClient {
        _ = agent.start()
        addTeardownBlock { agent.stop() }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        return client
    }

    func testFollowAppendsTheAgentEventsOfAConnection() async throws {
        let agent = FakeAgent()
        let client = try await connectedClient(to: agent)
        let buffer = EventBuffer()
        let now = t0
        let feed = buffer.follow(client, now: { now })
        defer { feed.cancel() }

        agent.sendLine(["t": "clipboard.changed", "text": "ignored"])
        agent.sendLine(["t": "ev", "name": "window.opened", "window": ["id": "0x1a", "title": "메모장"]])
        agent.sendLine(["t": "ev", "name": "process.exited", "pid": 44, "code": 3, "path": "C:\\x.exe"])
        let arrived = await eventually { await buffer.since(0).events.count == 2 }
        XCTAssertTrue(arrived)
        let events = await buffer.since(0).events
        XCTAssertEqual(events, [
            GuestEvent(seq: 1, time: t0, name: "window.opened", payload: ["window": ["id": "0x1a", "title": "메모장"]]),
            GuestEvent(seq: 2, time: t0, name: "process.exited", payload: ["pid": 44, "code": 3, "path": "C:\\x.exe"]),
        ])
    }

    func testEventsOfALaterConnectionContinueTheSequence() async throws {
        let buffer = EventBuffer()
        let first = FakeAgent()
        let firstClient = try await connectedClient(to: first)
        let firstFeed = buffer.follow(firstClient)
        first.sendLine(["t": "ev", "name": "window.opened", "title": "one"])
        let one = await eventually { await buffer.since(0).next == 1 }
        XCTAssertTrue(one)
        first.drop()
        await firstFeed.value

        let second = FakeAgent()
        let secondClient = try await connectedClient(to: second)
        let secondFeed = buffer.follow(secondClient)
        defer { secondFeed.cancel() }
        second.sendLine(["t": "ev", "name": "window.closed", "title": "one"])
        let two = await eventually { await buffer.since(0).next == 2 }
        XCTAssertTrue(two)
        let events = await buffer.since(0).events
        XCTAssertEqual(events.map(\.seq), [1, 2])
        XCTAssertEqual(events.map(\.name), ["window.opened", "window.closed"])
        let newer = await buffer.since(1).events
        XCTAssertEqual(newer.map(\.name), ["window.closed"])
    }

    func testFirstIsTheOldestEventStillKept() async {
        let buffer = EventBuffer()
        let empty = await buffer.since(0)
        XCTAssertEqual(empty.first, 0)
        for _ in 1...3 { await buffer.append(name: "e", payload: [:], at: t0) }
        let some = await buffer.since(2)
        XCTAssertEqual(some.first, 1)
        XCTAssertEqual(some.events.map(\.seq), [3])
        for _ in 1...EventBuffer.capacity { await buffer.append(name: "e", payload: [:], at: t0) }
        let rolled = await buffer.since(Int.max)
        XCTAssertEqual(rolled.first, 4)
        XCTAssertEqual(rolled.next, EventBuffer.capacity + 3)
    }

    // MARK: - the agent link

    /// A started fake agent offering `caps`; stopped when the test ends.
    private func fakeAgent(caps: [String]) -> FakeAgent {
        let agent = FakeAgent()
        agent.caps = caps
        agent.handler = { m, _ in m["op"]?.stringValue == "ui.ping" ? [agentReply(m, ["pong": true])] : [] }
        _ = agent.start()
        addTeardownBlock { agent.stop() }
        return agent
    }

    func testLinkWithZeroTimeoutReturnsOnlyAConnectedClientAndStartsOneAttempt() async throws {
        let agent = fakeAgent(caps: ["clipboard"])
        let latch = Latch()
        let running = LockedBox(true)
        let buffer = EventBuffer()
        let link = AgentLink(events: buffer, isRunning: { running.value }, endpoint: {
            await latch.pass()
            return (agent.port, nil)
        })
        let first = await link.agent(timeout: .zero)
        XCTAssertNil(first)
        let second = await link.agent(timeout: .zero)
        XCTAssertNil(second)
        var attempts = await link.warmUpCount
        XCTAssertEqual(attempts, 1)
        let reached = await eventually { await latch.arrivals == 1 }
        XCTAssertTrue(reached)

        await latch.open()
        let connected = await eventually { await link.agent(timeout: .zero) != nil }
        XCTAssertTrue(connected)
        attempts = await link.warmUpCount
        XCTAssertEqual(attempts, 1)
        let arrivals = await latch.arrivals
        XCTAssertEqual(arrivals, 1)
        let found = await link.agent(timeout: .seconds(30))
        let client = try XCTUnwrap(found)
        let same = await link.agent(timeout: .zero)
        XCTAssertTrue(same === client)

        agent.sendLine(["t": "ev", "name": "window.opened", "window": ["title": "one"]])
        let fed = await eventually { await buffer.since(0).next == 1 }
        XCTAssertTrue(fed)

        agent.drop()
        let ended = await eventually { await !client.isConnected }
        XCTAssertTrue(ended)
        let afterTheEnd = await link.agent(timeout: .zero)
        XCTAssertNil(afterTheEnd)
        attempts = await link.warmUpCount
        XCTAssertEqual(attempts, 2)

        running.value = false
        let stopped = await link.agent(timeout: .seconds(30))
        XCTAssertNil(stopped)
    }

    func testLinkDoesNotAdoptAConnectionBegunBeforeADrop() async throws {
        let stale = fakeAgent(caps: ["stale"]), current = fakeAgent(caps: ["current"])
        let latch = Latch()
        let calls = LockedBox(0)
        let link = AgentLink(events: EventBuffer(), isRunning: { true }, endpoint: {
            let n = calls.value
            calls.value = n + 1
            if n == 0 { await latch.pass() }
            return (n == 0 ? stale.port : current.port, nil)
        })
        let pending = Task { await link.agent(timeout: .seconds(60)) }
        let reached = await eventually { await latch.arrivals == 1 }
        XCTAssertTrue(reached)
        await link.drop()
        await latch.open()
        let adopted = await pending.value
        let caps = await adopted?.hello?.capabilities
        XCTAssertEqual(caps, ["current"])
        XCTAssertEqual(calls.value, 2)
    }

    func testLinkAdoptsOneClientForTwoConcurrentReconnects() async throws {
        let agents = [fakeAgent(caps: ["first"]), fakeAgent(caps: ["second"])]
        let latch = Latch()
        let calls = LockedBox(0)
        let buffer = EventBuffer()
        let link = AgentLink(events: buffer, isRunning: { true }, endpoint: {
            let n = calls.value
            calls.value = n + 1
            await latch.pass()
            return (agents[min(n, 1)].port, nil)
        })
        let one = Task { await link.agent(timeout: .seconds(60)) }
        let two = Task { await link.agent(timeout: .seconds(60)) }
        let both = await eventually { await latch.arrivals == 2 }
        XCTAssertTrue(both)
        await latch.open()
        let a = await one.value, b = await two.value
        XCTAssertNotNil(a)
        XCTAssertTrue(a === b)
        let cached = await link.agent(timeout: .zero)
        XCTAssertTrue(cached === a)
        let connected = await a?.isConnected
        XCTAssertEqual(connected, true)

        let caps = await a?.hello?.capabilities
        let adopted = try XCTUnwrap(agents.first { $0.caps == caps })
        for agent in agents { agent.sendLine(["t": "ev", "name": "window.opened", "window": ["title": .string(agent.caps[0])]]) }
        adopted.sendLine(["t": "ev", "name": "window.closed", "window": ["title": .string(adopted.caps[0])]])
        let fed = await eventually { await buffer.since(0).events.last?.name == "window.closed" }
        XCTAssertTrue(fed)
        let titles = await buffer.since(0).events.map { $0.windowTitle }
        XCTAssertEqual(titles, [adopted.caps[0], adopted.caps[0]])
    }

    func testLinkSaysWhetherAConnectionIsBeingMade() async throws {
        let unreachable = FakeAgent()
        unreachable.stop()
        let reachable = fakeAgent(caps: ["clipboard"])
        let latch = Latch()
        let port = LockedBox(unreachable.port)
        let link = AgentLink(events: EventBuffer(), retryDelay: .milliseconds(10), isRunning: { true }, endpoint: {
            await latch.pass()
            return (port.value, nil)
        })
        var connecting = await link.isConnecting
        XCTAssertFalse(connecting)

        let first = await link.agent(timeout: .zero)
        XCTAssertNil(first)
        connecting = await link.isConnecting
        XCTAssertTrue(connecting)
        let held = await eventually { await latch.arrivals == 1 }
        XCTAssertTrue(held)
        connecting = await link.isConnecting
        XCTAssertTrue(connecting)

        await latch.open()
        let failed = await eventually { await !link.isConnecting }
        XCTAssertTrue(failed)
        let second = await link.agent(timeout: .zero)
        XCTAssertNil(second)
        connecting = await link.isConnecting
        XCTAssertFalse(connecting)

        port.value = reachable.port
        let connected = await eventually { await link.agent(timeout: .zero) != nil }
        XCTAssertTrue(connected)
        let settled = await eventually { await !link.isConnecting }
        XCTAssertTrue(settled)

        await link.drop()
        port.value = unreachable.port
        let afterTheDrop = await link.agent(timeout: .zero)
        XCTAssertNil(afterTheDrop)
        let failedAgain = await eventually { await !link.isConnecting }
        XCTAssertTrue(failedAgain)
    }

    func testLinkStateNamesTheClientOrWhetherOneIsBeingConnected() async throws {
        let unreachable = FakeAgent()
        unreachable.stop()
        let reachable = fakeAgent(caps: ["clipboard"])
        let latch = Latch()
        let port = LockedBox(unreachable.port)
        let running = LockedBox(true)
        let link = AgentLink(events: EventBuffer(), retryDelay: .milliseconds(10), isRunning: { running.value }, endpoint: {
            await latch.pass()
            return (port.value, nil)
        })
        let first = await link.state()
        XCTAssertEqual(kind(first), "connecting")
        var attempts = await link.warmUpCount
        XCTAssertEqual(attempts, 1)
        let held = await eventually { await latch.arrivals == 1 }
        XCTAssertTrue(held)
        let whileItRuns = await link.state()
        XCTAssertEqual(kind(whileItRuns), "connecting")
        attempts = await link.warmUpCount
        XCTAssertEqual(attempts, 1)

        await latch.open()
        let failed = await eventually { kind(await link.state()) == "not connected" }
        XCTAssertTrue(failed)

        port.value = reachable.port
        let connected = await eventually { kind(await link.state()) == "connected" }
        XCTAssertTrue(connected)
        guard case .connected(let client) = await link.state() else { return XCTFail("the link lost its client") }
        let cached = await link.agent(timeout: .zero)
        XCTAssertTrue(cached === client)
        let connecting = await link.isConnecting
        XCTAssertFalse(connecting)

        running.value = false
        let stopped = await link.state()
        XCTAssertEqual(kind(stopped), "not connected")
        let dropped = await eventually { await !client.isConnected }
        XCTAssertTrue(dropped)
    }

    func testLinkIsNotConnectingInThePauseAfterAnAttemptThatFailedAcrossADrop() async throws {
        let unreachable = FakeAgent()
        unreachable.stop()
        let latch = Latch()
        let link = AgentLink(events: EventBuffer(), retryDelay: .seconds(600), isRunning: { true }, endpoint: {
            await latch.pass()
            return (unreachable.port, nil)
        })
        let first = await link.state()
        XCTAssertEqual(kind(first), "connecting")
        let held = await eventually { await latch.arrivals == 1 }
        XCTAssertTrue(held)
        await link.drop()
        let inFlight = await link.isConnecting
        XCTAssertTrue(inFlight)

        await latch.open()
        let paused = await eventually { await !link.isConnecting }
        XCTAssertTrue(paused, "the pause after the failed attempt counts as connecting")
        let state = await link.state()
        XCTAssertEqual(kind(state), "not connected")
        let attempts = await link.warmUpCount
        XCTAssertEqual(attempts, 1)
        let arrivals = await latch.arrivals
        XCTAssertEqual(arrivals, 1)
    }

    func testLinkStaysConnectingWhileACallerPausesBeforeItsNextAttempt() async throws {
        let unreachable = FakeAgent()
        unreachable.stop()
        let reachable = fakeAgent(caps: ["clipboard"])
        let first = Latch(), second = Latch()
        let calls = LockedBox(0)
        let link = AgentLink(events: EventBuffer(), retryDelay: .milliseconds(300), isRunning: { true }, endpoint: {
            let n = calls.value
            calls.value = n + 1
            await (n == 0 ? first : second).pass()
            return (n == 0 ? unreachable.port : reachable.port, nil)
        })
        let pending = Task { await link.agent(timeout: .seconds(3600)) }
        let held = await eventually { await first.arrivals == 1 }
        XCTAssertTrue(held)
        await link.drop()
        await first.open()
        var readings: [Bool] = []
        while await second.arrivals == 0 {
            readings.append(await link.isConnecting)
            try await Task.sleep(for: .milliseconds(5))
        }
        readings.append(await link.isConnecting)
        XCTAssertFalse(readings.contains(false), "\(readings)")

        await second.open()
        let adopted = await pending.value
        XCTAssertNotNil(adopted)
        let state = await link.state()
        XCTAssertEqual(kind(state), "connected")
        let settled = await link.isConnecting
        XCTAssertFalse(settled)
    }

    func testLinkPingsTheUIHelperOfAnAgentThatHasOne() async throws {
        let withUI = fakeAgent(caps: ["clipboard", "ui"])
        let link = AgentLink(events: EventBuffer(), isRunning: { true }, endpoint: { (withUI.port, nil) })
        let client = await link.agent(timeout: .seconds(60))
        XCTAssertNotNil(client)
        await link.helperStart?.value
        XCTAssertEqual(agentRequests(withUI, "ui.ping").count, 1)
        _ = await link.agent(timeout: .seconds(60))
        await link.helperStart?.value
        XCTAssertEqual(agentRequests(withUI, "ui.ping").count, 1)

        let plain = fakeAgent(caps: ["clipboard", "files", "exec"])
        plain.handler = { m, _ in [agentReply(m, ["pong": true])] }
        let other = AgentLink(events: EventBuffer(), isRunning: { true }, endpoint: { (plain.port, nil) })
        let connected = await other.agent(timeout: .seconds(60))
        let plainClient = try XCTUnwrap(connected)
        let started = await other.helperStart
        XCTAssertNil(started)
        _ = try await plainClient.call("ping", [:], timeout: .seconds(20))
        XCTAssertTrue(agentRequests(plain, "ui.ping").isEmpty)
    }

    func testLinkCallsItsObserverForEveryConnectionItAdopts() async throws {
        let agents = [fakeAgent(caps: ["clipboard"]), fakeAgent(caps: ["clipboard"]), fakeAgent(caps: ["clipboard"])]
        let port = LockedBox(agents[0].port)
        let seen = LockedBox<[ObjectIdentifier]>([])
        let link = AgentLink(events: EventBuffer(), isRunning: { true }, endpoint: { (port.value, nil) })
        await link.setObserver { client in seen.value = seen.value + [ObjectIdentifier(client)] }

        let connected = await link.agent(timeout: .seconds(60))
        let first = try XCTUnwrap(connected)
        await link.observerCall?.value
        XCTAssertEqual(seen.value, [ObjectIdentifier(first)])
        _ = await link.agent(timeout: .seconds(60))
        await link.observerCall?.value
        XCTAssertEqual(seen.value, [ObjectIdentifier(first)])

        await link.drop()
        port.value = agents[1].port
        let reconnected = await link.agent(timeout: .seconds(60))
        let second = try XCTUnwrap(reconnected)
        await link.observerCall?.value
        XCTAssertEqual(seen.value, [ObjectIdentifier(first), ObjectIdentifier(second)])

        await link.setObserver(nil)
        await link.drop()
        port.value = agents[2].port
        let third = await link.agent(timeout: .seconds(60))
        XCTAssertNotNil(third)
        let call = await link.observerCall
        XCTAssertNil(call)
        XCTAssertEqual(seen.value.count, 2)
    }

    func testACancelledFeedStopsAppending() async throws {
        let agent = FakeAgent()
        agent.handler = { m, _ in m["op"]?.stringValue == "ping" ? [agentReply(m, ["pong": true])] : [] }
        let client = try await connectedClient(to: agent)
        let buffer = EventBuffer()
        let feed = buffer.follow(client)
        agent.sendLine(["t": "ev", "name": "a"])
        let first = await eventually { await buffer.since(0).next == 1 }
        XCTAssertTrue(first)
        feed.cancel()
        await feed.value
        agent.sendLine(["t": "ev", "name": "b"])
        _ = try await client.call("ping", [:], timeout: .seconds(20))
        let count = await buffer.since(0).next
        XCTAssertEqual(count, 1)
    }
}
