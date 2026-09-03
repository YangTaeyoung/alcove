import XCTest
@testable import AlcoveDisplayProtocol

/// A minimal stand-in for the QEMU backend: connects to the socket, sends
/// lines, and reads what the app sends.
private final class FakeBackend {
    let fd: Int32
    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: 104) { dst in _ = path.withCString { strncpy(dst, $0, 103) } }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw NSError(domain: "connect", code: Int(errno)) }
    }
    func send(_ s: String) { _ = s.withCString { write(fd, $0, strlen($0)) } }
    func readLine(timeout: TimeInterval = 5) -> String? {
        var out = [UInt8](); let end = Date().addingTimeInterval(timeout)
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while Date() < end {
            guard poll(&pfd, 1, 100) > 0 else { continue }
            var b: UInt8 = 0
            let n = read(fd, &b, 1)
            if n <= 0 { return nil }
            if b == 10 { return String(decoding: out, as: UTF8.self) }
            out.append(b)
        }
        return nil
    }
    func close() { Darwin.close(fd) }
}

final class DisplayConnectionTests: XCTestCase {
    private func tempSocketPath() -> String { "/tmp/alcove-t-\(UUID().uuidString.prefix(8)).sock" }

    func testReceivesMessagesAndSendsReplies() async throws {
        let path = tempSocketPath()
        let conn = try DisplayConnection(socketPath: path)
        XCTAssertFalse(conn.isConnected)
        let backend = try FakeBackend(path: path)
        backend.send("{\"t\":\"hello\",\"v\":1,\"consoles\":1}\n{\"t\":\"switch\",\"con\":0,\"w\":4,\"h\":2,\"stride\":16,\"fmt\":\"bgra8\",\"shm\":\"/x\",\"size\":4096}\n")

        var it = conn.messages.makeAsyncIterator()
        let first = await it.next()
        XCTAssertEqual(first, .hello(.init(v: 1, consoles: 1)))
        let second = await it.next()
        XCTAssertEqual(second, .switchSurface(.init(con: 0, w: 4, h: 2, stride: 16, fmt: "bgra8", shm: "/x", size: 4096)))
        XCTAssertTrue(conn.isConnected)

        conn.send(.key(mac: 53, q: nil, down: true))
        XCTAssertEqual(backend.readLine(), "{\"t\":\"key\",\"mac\":53,\"down\":true}")

        // a garbage line must not kill the connection
        backend.send("this is not json\n{\"t\":\"bye\"}\n")
        let third = await it.next()
        XCTAssertEqual(third, .bye)

        backend.close()
        let end = await it.next()
        XCTAssertNil(end)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testCloseFinishesStreamAndRemovesSocket() async throws {
        let path = tempSocketPath()
        let ended = expectation(description: "end")
        let box = EndBox()
        let conn = try DisplayConnection(socketPath: path) { reason in box.set(reason); ended.fulfill() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        conn.close()
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertEqual(box.get(), .closed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        var it = conn.messages.makeAsyncIterator()
        let none = await it.next()
        XCTAssertNil(none)
    }

    func testSecondClientIsRefused() async throws {
        let path = tempSocketPath()
        let conn = try DisplayConnection(socketPath: path)
        let a = try FakeBackend(path: path)
        a.send("{\"t\":\"hello\",\"v\":1,\"consoles\":1}\n")
        var it = conn.messages.makeAsyncIterator()
        _ = await it.next()
        // the listening socket is gone once a peer is accepted
        XCTAssertThrowsError(try FakeBackend(path: path))
        a.close()
        conn.close()
    }

    func testLargeBurstIsDeliveredInOrder() async throws {
        let path = tempSocketPath()
        let conn = try DisplayConnection(socketPath: path)
        let backend = try FakeBackend(path: path)
        var payload = ""
        for i in 0..<5000 { payload += "{\"t\":\"update\",\"con\":0,\"x\":\(i),\"y\":0,\"w\":1,\"h\":1}\n" }
        backend.send(payload)
        var it = conn.messages.makeAsyncIterator()
        for i in 0..<5000 {
            let m = await it.next()
            XCTAssertEqual(m, .update(.init(con: 0, x: i, y: 0, w: 1, h: 1)))
        }
        backend.close()
        conn.close()
    }
}

private final class EndBox: @unchecked Sendable {
    private let lock = NSLock(); private var value: DisplayConnection.EndReason?
    func set(_ v: DisplayConnection.EndReason) { lock.lock(); value = v; lock.unlock() }
    func get() -> DisplayConnection.EndReason? { lock.lock(); defer { lock.unlock() }; return value }
}
