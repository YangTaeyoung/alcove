import XCTest
@testable import AlcoveQMP

final class UnixLineTransportTests: XCTestCase {
    /// Lines are delivered without the CR of QEMU's CRLF framing and in wire order,
    /// and `onEnd` follows the last line.
    func testStripsCRAndPreservesOrder() throws {
        let server = try FakeQMPServer()
        defer { server.stop() }
        let box = LineBox()
        let ended = expectation(description: "ended")
        let t = try UnixLineTransport(path: server.path, onLine: { box.append($0) }, onEnd: { box.end($0); ended.fulfill() })
        defer { t.close() }
        let greeted = expectation(description: "greeted")
        DispatchQueue.global().async { while box.lines.isEmpty { usleep(1000) }; greeted.fulfill() }
        wait(for: [greeted], timeout: 2)
        for i in 0..<200 { server.emitEvent("E\(i)") }
        server.dropClient()
        wait(for: [ended], timeout: 2)
        XCTAssertEqual(box.lines.count, 201)
        for l in box.lines { XCTAssertNotEqual(l.last, 13, "trailing CR must be stripped"); XCTAssertNotEqual(l.last, 10) }
        let names = box.lines.dropFirst().compactMap { try? JSON.parse($0)["event"]?.stringValue }
        XCTAssertEqual(names, (0..<200).map { "E\($0)" })
        XCTAssertEqual(box.endReason, "peer closed")
        XCTAssertEqual(box.endIndex, 201, "onEnd must come after the last line")
    }

    /// The owner may drop its last reference from inside `onEnd`, which runs on
    /// the transport's own queue: `deinit` must not dispatch_sync onto that queue
    /// (that traps in libdispatch). This is the path taken every time QEMU exits.
    func testMayBeReleasedFromItsOwnCallback() throws {
        let server = try FakeQMPServer()
        defer { server.stop() }
        let holder = TransportHolder()
        let ended = expectation(description: "ended")
        let greeted = expectation(description: "greeted")
        try Self.makeTransport(path: server.path, into: holder, onFirstLine: { greeted.fulfill() }, onEnd: {
            holder.release()          // last strong reference goes away on the transport queue
            ended.fulfill()
        })
        wait(for: [greeted], timeout: 2)
        server.dropClient()
        wait(for: [ended], timeout: 2)
        // give the queue a moment to run deinit / the cancel handler; a trap would have killed the process
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertNil(holder.transport)
    }

    /// Creating the transport in a separate frame ensures no local keeps it alive.
    private static func makeTransport(path: String, into holder: TransportHolder,
                                      onFirstLine: @escaping @Sendable () -> Void,
                                      onEnd: @escaping @Sendable () -> Void) throws {
        let once = OnceFlag()
        let t = try UnixLineTransport(path: path, onLine: { _ in if once.trip() { onFirstLine() } }, onEnd: { _ in onEnd() })
        holder.set(t)
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [Data] = []
    private var _endReason: String?
    private var _endIndex = -1
    var lines: [Data] { lock.lock(); defer { lock.unlock() }; return _lines }
    var endReason: String? { lock.lock(); defer { lock.unlock() }; return _endReason }
    var endIndex: Int { lock.lock(); defer { lock.unlock() }; return _endIndex }
    func append(_ d: Data) { lock.lock(); _lines.append(d); lock.unlock() }
    func end(_ r: String) { lock.lock(); _endReason = r; _endIndex = _lines.count; lock.unlock() }
}

private final class TransportHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _t: UnixLineTransport?
    var transport: UnixLineTransport? { lock.lock(); defer { lock.unlock() }; return _t }
    func set(_ t: UnixLineTransport) { lock.lock(); _t = t; lock.unlock() }
    func release() { lock.lock(); let t = _t; _t = nil; lock.unlock(); _ = t }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock(); private var tripped = false
    func trip() -> Bool { lock.lock(); defer { lock.unlock() }; if tripped { return false }; tripped = true; return true }
}
