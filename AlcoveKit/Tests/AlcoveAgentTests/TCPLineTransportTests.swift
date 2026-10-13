import XCTest
import os
@testable import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

final class TCPLineTransportTests: XCTestCase {
    func testDroppingTheOnlyReferenceWithASendQueued() async throws {
        let ended = OSAllocatedUnfairLock(initialState: 0)
        for _ in 0..<200 {
            let agent = FakeAgent().start()
            defer { agent.stop() }
            var transport: TCPLineTransport? = try TCPLineTransport(host: "127.0.0.1", port: agent.port, onLine: { _ in }, onEnd: { _ in
                ended.withLock { $0 += 1 }
            })
            transport?.send(Data("{\"t\":\"ping\"}\n".utf8))
            transport = nil
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while ended.withLock({ $0 }) < 200, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(ended.withLock { $0 }, 200)
    }

    func testCloseThenReleaseEndsOnce() throws {
        let agent = FakeAgent().start()
        defer { agent.stop() }
        let reasons = LockedBox<[String]>([])
        var transport: TCPLineTransport? = try TCPLineTransport(host: "127.0.0.1", port: agent.port, onLine: { _ in }, onEnd: { reason in
            reasons.value += [reason]
        })
        transport?.close()
        transport = nil
        XCTAssertEqual(reasons.value, ["closed"])
    }
}
