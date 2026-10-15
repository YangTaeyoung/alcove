import XCTest
@testable import AlcoveControl
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

/// A settable clock for lease expiry.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return instant }
    func advance(_ d: Duration) { lock.lock(); instant = instant + d; lock.unlock() }
}

final class LeaseTests: XCTestCase {
    private func setup() -> (ControlHandler, FakeTarget, TestClock) {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 800, height: 600))
        let clock = TestClock()
        let h = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test", captureDirectory: scratchCaptureDirectory, clock: { clock.now })
        return (h, t, clock)
    }

    private func failure(_ h: ControlHandler, _ op: String, _ params: JSON, file: StaticString = #filePath, line: UInt = #line) async -> String {
        do { _ = try await h.handle(op: op, params: params); XCTFail("expected failure", file: file, line: line); return "" }
        catch { return "\(error)" }
    }

    func testAcquireGrantsAndBlocksOthers() async throws {
        let (h, _, _) = setup()
        let lease = try await h.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "agent-a", "ttl": 60])
        let token = try XCTUnwrap(lease["lease"]?.stringValue)
        XCTAssertNotNil(UUID(uuidString: token))
        XCTAssertEqual(lease["expiresIn"]?.intValue, 60)

        let expected = "VM 'Win' is leased by agent-a for another 60 s; pass its lease token, wait, or ask the owner to release it"
        let second = await failure(h, "vm.lease.acquire", ["name": "Win", "owner": "agent-b"])
        XCTAssertEqual(second, expected)
        let click = await failure(h, "vm.mouse.click", ["name": "Win", "x": 5, "y": 5])
        XCTAssertEqual(click, expected)
        let wrong = await failure(h, "vm.mouse.click", ["name": "Win", "x": 5, "y": 5, "lease": "other"])
        XCTAssertEqual(wrong, expected)

        _ = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5, "lease": .string(token)])
        let shot = try await h.handle(op: "vm.screenshot", params: ["name": "Win"])
        XCTAssertEqual(shot["width"]?.intValue, 800)
        _ = try await h.handle(op: "vm.list", params: [:])
    }

    func testRefusalRoundsRemainingTimeUp() async throws {
        let (h, _, clock) = setup()
        _ = try await h.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "a", "ttl": 60])
        clock.advance(.milliseconds(59_500))
        let text = await failure(h, "vm.mouse.click", ["name": "Win", "x": 1, "y": 1])
        XCTAssertTrue(text.contains("for another 1 s;"), text)
    }

    func testOwnerDefaultsToUnknown() async throws {
        let (h, _, _) = setup()
        _ = try await h.handle(op: "vm.lease.acquire", params: ["name": "Win"])
        let text = await failure(h, "vm.type", ["name": "Win", "text": "a"])
        XCTAssertTrue(text.contains("leased by unknown for another 300 s"), text)
    }

    func testLeaseParamIsIgnoredWithoutLease() async throws {
        let (h, _, _) = setup()
        _ = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5, "lease": "stale"])
    }

    func testRenewWithToken() async throws {
        let (h, _, clock) = setup()
        let first = try await h.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "a", "ttl": 60])
        let token = try XCTUnwrap(first["lease"]?.stringValue)
        clock.advance(.seconds(50))
        let renewed = try await h.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "a", "ttl": 120, "lease": .string(token)])
        XCTAssertEqual(renewed["lease"]?.stringValue, token)
        XCTAssertEqual(renewed["expiresIn"]?.intValue, 120)
        clock.advance(.seconds(100))
        let text = await failure(h, "vm.mouse.click", ["name": "Win", "x": 1, "y": 1])
        XCTAssertTrue(text.contains("for another 20 s;"), text)
    }

    func testReleaseNeedsToken() async throws {
        let (h, _, _) = setup()
        let none = try await h.handle(op: "vm.lease.release", params: ["name": "Win", "lease": "x"])
        XCTAssertEqual(none, [:])
        let lease = try await h.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "a"])
        let token = try XCTUnwrap(lease["lease"]?.stringValue)
        let wrong = await failure(h, "vm.lease.release", ["name": "Win", "lease": "nope"])
        XCTAssertEqual(wrong, "lease token does not match; only the holder can release 'Win'")
        let released = try await h.handle(op: "vm.lease.release", params: ["name": "Win", "lease": .string(token)])
        XCTAssertEqual(released, [:])
        _ = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5])
    }

    func testLeaseExpires() async throws {
        let (h, _, clock) = setup()
        _ = try await h.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "a", "ttl": 30])
        clock.advance(.seconds(31))
        let other = try await h.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "b"])
        XCTAssertNotNil(other["lease"]?.stringValue)
    }

    func testTtlIsCapped() async throws {
        let (h, _, _) = setup()
        let big = try await h.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "a", "ttl": 99_999])
        XCTAssertEqual(big["expiresIn"]?.intValue, 3600)
        _ = try await h.handle(op: "vm.lease.release", params: ["name": "Win", "lease": big["lease"] ?? .null])
        let small = try await h.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "a", "ttl": 0])
        XCTAssertEqual(small["expiresIn"]?.intValue, 1)
        _ = try await h.handle(op: "vm.lease.release", params: ["name": "Win", "lease": small["lease"] ?? .null])
        let def = try await h.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "a"])
        XCTAssertEqual(def["expiresIn"]?.intValue, 300)
    }

    func testStatusShowsLeasedBy() async throws {
        let (h, _, clock) = setup()
        let before = try await h.handle(op: "vm.status", params: ["name": "Win"])
        XCTAssertNil(before["leasedBy"])
        _ = try await h.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "agent-a", "ttl": 10])
        let status = try await h.handle(op: "vm.status", params: ["name": "Win"])
        XCTAssertEqual(status["leasedBy"]?.stringValue, "agent-a")
        let list = try await h.handle(op: "vm.list", params: [:])
        XCTAssertEqual(list["vms"]?[0]?["leasedBy"]?.stringValue, "agent-a")
        clock.advance(.seconds(11))
        let after = try await h.handle(op: "vm.status", params: ["name": "Win"])
        XCTAssertNil(after["leasedBy"])
    }

    func testReadOnlyClassification() async throws {
        let readOnly: Set<String> = [
            "hello", "vm.list", "vm.status", "vm.screenshot", "vm.wait_idle", "vm.clipboard.get", "vm.exec.read",
            "vm.exec.list", "vm.process.list", "vm.fs.list", "vm.fs.read", "vm.pull_file", "vm.snapshot.list",
            "vm.forward.list", "vm.lease.acquire", "vm.lease.release", "vm.doctor", "vm.find_text", "vm.wait_for",
            "vm.record.status", "vm.window.list", "vm.ui.tree", "vm.ui.find", "vm.ui.text", "vm.events", "script.save",
            "vm.event_log", "vm.crash_dumps.list", "vm.crash_dumps.pull", "vm.collect_diagnostics",
            "vm.http.requests", "vm.http.request", "vm.http.rule.list",
        ]
        for op in ControlHandler.knownOps {
            XCTAssertEqual(ControlHandler.isReadOnly(op: op), readOnly.contains(op), op)
        }
        for op in readOnly { XCTAssertTrue(ControlHandler.isReadOnly(op: op), op) }
        XCTAssertFalse(ControlHandler.isReadOnly(op: "vm.set_resolution"))
    }

    func testKnownOpsMatchTheDispatcher() async throws {
        let (h, _, _) = setup()
        XCTAssertEqual(Set(ControlHandler.knownOps).count, ControlHandler.knownOps.count)
        for op in ControlHandler.knownOps {
            do { _ = try await h.handle(op: op, params: [:]) }
            catch ControlHandler.ControlError.unknownOp { XCTFail("dispatcher rejects \(op)") }
            catch {}
        }
        do { _ = try await h.handle(op: "vm.bogus", params: [:]); XCTFail() }
        catch ControlHandler.ControlError.unknownOp {}
    }

    func testSetResolutionReturnsNewSize() async throws {
        let agent = FakeAgent()
        agent.caps = ["clipboard", "files", "exec", "resolution"]
        let (h, t) = try await handlerWithAgent(agent, in: self)
        let swap = Task {
            try await Task.sleep(for: .milliseconds(200))
            await t.setPNG(makePNG(width: 1024, height: 768))
        }
        let r = try await h.handle(op: "vm.set_resolution", params: ["name": "Win", "width": 1024, "height": 768])
        _ = try await swap.value
        XCTAssertEqual(r["width"]?.intValue, 1024); XCTAssertEqual(r["height"]?.intValue, 768)
        let requests = agentRequestsOrEvents(agent, "resolution.set")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?["w"]?.intValue, 1024); XCTAssertEqual(requests.first?["h"]?.intValue, 768)
    }

    func testSetResolutionRefusesGuestToolsThatCannotChangeTheMode() async throws {
        let agent = FakeAgent()
        agent.caps = ["files", "shutdown", "exec", "rpc"]
        let (h, _) = try await handlerWithAgent(agent, in: self)
        let text = await failure(h, "vm.set_resolution", ["name": "Win", "width": 1440, "height": 900])
        XCTAssertEqual(text, "the guest tools in 'Win' cannot change the display mode of this guest; change it in the guest's display settings")
        XCTAssertTrue(agentRequestsOrEvents(agent, "resolution.set").isEmpty)
    }

    func testSetResolutionValidatesAndNeedsTools() async throws {
        let (h, _, _) = setup()
        let message = "width must be 320...7680 and height 200...4320"
        for (w, hh) in [(319, 600), (7681, 600), (800, 199), (800, 4321)] {
            let text = await failure(h, "vm.set_resolution", ["name": "Win", "width": .int(Int64(w)), "height": .int(Int64(hh))])
            XCTAssertEqual(text, message)
        }
        let missing = await failure(h, "vm.set_resolution", ["name": "Win", "width": 800])
        XCTAssertEqual(missing, "missing or invalid parameter 'height'")
        let noTools = await failure(h, "vm.set_resolution", ["name": "Win", "width": 800, "height": 600])
        XCTAssertTrue(noTools.contains("guest tools are not connected"), noTools)
    }

    func testSetResolutionIsLeaseGuarded() async throws {
        let (h, _, _) = setup()
        _ = try await h.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "a"])
        let text = await failure(h, "vm.set_resolution", ["name": "Win", "width": 800, "height": 600])
        XCTAssertTrue(text.contains("is leased by a"), text)
    }
}

/// The messages of type `type` that `agent` received, in arrival order.
private func agentRequestsOrEvents(_ agent: FakeAgent, _ type: String) -> [JSON] {
    agent.received.filter { $0["t"]?.stringValue == type }
}
