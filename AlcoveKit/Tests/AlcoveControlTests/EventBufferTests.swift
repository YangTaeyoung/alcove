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
