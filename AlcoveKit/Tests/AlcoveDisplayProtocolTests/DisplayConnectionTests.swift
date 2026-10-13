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
        guard rc == 0 else { let e = errno; Darwin.close(fd); throw NSError(domain: "connect", code: Int(e)) }
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
    private let hello = "{\"t\":\"hello\",\"v\":1,\"consoles\":1}\n"

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

    func testCurrentSurfaceTracksSwitch() async throws {
        let path = tempSocketPath()
        let conn = try DisplayConnection(socketPath: path)
        XCTAssertNil(conn.currentSurface)
        let backend = try FakeBackend(path: path)
        var it = conn.messages.makeAsyncIterator()

        backend.send("{\"t\":\"switch\",\"con\":0,\"w\":4,\"h\":2,\"stride\":16,\"fmt\":\"bgra8\",\"shm\":\"/a\",\"size\":4096}\n")
        _ = await it.next()
        let first = FromQEMU.SurfaceSwitch(con: 0, w: 4, h: 2, stride: 16, fmt: "bgra8", shm: "/a", size: 4096)
        XCTAssertEqual(conn.currentSurface, first)

        backend.send("{\"t\":\"switch\",\"con\":0,\"w\":4,\"h\":2,\"stride\":16,\"fmt\":\"rgb565\",\"shm\":\"/b\",\"size\":4096}\n")
        _ = await it.next()
        XCTAssertEqual(conn.currentSurface, first)

        backend.send("{\"t\":\"switch\",\"con\":1,\"w\":4,\"h\":2,\"stride\":16,\"fmt\":\"bgra8\",\"shm\":\"/c\",\"size\":4096}\n")
        _ = await it.next()
        XCTAssertEqual(conn.currentSurface, first)

        backend.close()
        _ = await it.next()
        XCTAssertNil(conn.currentSurface)
    }

    func testSurfaceValidityHasCapsAndNoOverflow() {
        func surface(w: Int, h: Int, stride: Int, size: Int) -> FromQEMU.SurfaceSwitch {
            .init(con: 0, w: w, h: h, stride: stride, fmt: "bgra8", shm: "/x", size: size)
        }
        XCTAssertTrue(surface(w: 4, h: 2, stride: 16, size: 32).isValid)
        XCTAssertFalse(surface(w: 4, h: 2, stride: 16, size: 31).isValid)
        XCTAssertFalse(surface(w: Int.max, h: 2, stride: 16, size: 32).isValid)
        XCTAssertFalse(surface(w: 4, h: Int.max, stride: 16, size: Int.max).isValid)
        XCTAssertFalse(surface(w: 4, h: 2, stride: Int.max, size: Int.max).isValid)
        XCTAssertFalse(surface(w: 4, h: 2, stride: 16, size: Int.max).isValid)
        XCTAssertFalse(surface(w: -4, h: 2, stride: 16, size: 32).isValid)
        XCTAssertFalse(surface(w: 4, h: -2, stride: 16, size: 32).isValid)
        XCTAssertFalse(surface(w: 4, h: 2, stride: -16, size: 32).isValid)
        XCTAssertFalse(surface(w: 4, h: 2, stride: 16, size: -1).isValid)
        XCTAssertFalse(surface(w: 16385, h: 1, stride: 65540, size: 65540).isValid)
        XCTAssertFalse(surface(w: 1, h: 16385, stride: 4, size: 65540).isValid)
        XCTAssertFalse(surface(w: 4, h: 1, stride: 262_145, size: 262_145).isValid)
        XCTAssertFalse(surface(w: 4, h: 4, stride: 262_144, size: (1 << 30) + 1).isValid)
        XCTAssertTrue(surface(w: 16384, h: 16384, stride: 65536, size: 1 << 30).isValid)
        XCTAssertTrue(surface(w: 1, h: 4096, stride: 262_144, size: 1 << 30).isValid)
        XCTAssertFalse(surface(w: 1, h: 4096, stride: 262_144, size: (1 << 30) - 1).isValid)
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
        // idempotent
        conn.close()
    }

    func testSecondClientIsRefused() async throws {
        let path = tempSocketPath()
        let conn = try DisplayConnection(socketPath: path)
        let a = try FakeBackend(path: path)
        a.send(hello)
        var it = conn.messages.makeAsyncIterator()
        _ = await it.next()
        // the listening socket (and its path) is gone once a peer is accepted
        XCTAssertThrowsError(try FakeBackend(path: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
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

    /// `send()` queues a block on the connection's private serial queue. If that
    /// block were the last owner of the connection, `deinit` would run on the
    /// queue itself; a `deinit` that then hopped onto the queue synchronously
    /// would abort the process (libdispatch: "dispatch_sync called on queue
    /// already owned by current thread"). `VMController.teardown` releases the
    /// connection while views may still be sending input, so this must be safe.
    func testReleasingLastReferenceRightAfterSendDoesNotCrash() async throws {
        for _ in 0..<25 {
            let path = tempSocketPath()
            var conn: DisplayConnection? = try DisplayConnection(socketPath: path)
            let backend = try FakeBackend(path: path)
            backend.send(hello)
            var it = conn!.messages.makeAsyncIterator()
            _ = await it.next()
            // Inbound traffic keeps the read handler busy on the queue while we drop
            // our reference, so either a queued send block or a source handler may
            // end up being the last owner.
            backend.send("{\"t\":\"update\",\"con\":0,\"x\":0,\"y\":0,\"w\":1,\"h\":1}\n")
            for _ in 0..<8 { conn?.send(.lift) }
            conn = nil
            // The stream finishes once the connection has been torn down.
            while await it.next() != nil {}
            backend.close()
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    /// `onEnd` must not run on the connection's serial queue: a handler that
    /// calls back into the connection (`isConnected`, `close`, `send`) would
    /// otherwise re-enter the queue synchronously and abort.
    func testOnEndMayCallBackIntoTheConnection() async throws {
        let path = tempSocketPath()
        let ended = expectation(description: "end")
        let holder = ConnectionHolder()
        let observed = EndBox()
        let conn = try DisplayConnection(socketPath: path) { reason in
            if let c = holder.get() {
                _ = c.isConnected
                c.send(.lift)
                c.close()
            }
            observed.set(reason)
            ended.fulfill()
        }
        holder.set(conn)
        let backend = try FakeBackend(path: path)
        backend.send(hello)
        var it = conn.messages.makeAsyncIterator()
        _ = await it.next()
        backend.close()
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertEqual(observed.get(), .peerClosed)
        XCTAssertFalse(conn.isConnected)
        holder.set(nil)
    }

    /// Once a peer has been accepted the instance no longer owns the socket
    /// path, so finishing it later must not remove a newer listener bound to
    /// the same path.
    func testFinishingOldConnectionKeepsNewerSocketAtSamePath() async throws {
        let path = tempSocketPath()
        let old = try DisplayConnection(socketPath: path)
        let oldPeer = try FakeBackend(path: path)
        oldPeer.send(hello)
        var oldIt = old.messages.makeAsyncIterator()
        _ = await oldIt.next()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))

        let new = try DisplayConnection(socketPath: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        old.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "old connection removed the new listener's socket")

        let newPeer = try FakeBackend(path: path)
        newPeer.send(hello)
        var newIt = new.messages.makeAsyncIterator()
        let m = await newIt.next()
        XCTAssertEqual(m, .hello(.init(v: 1, consoles: 1)))
        XCTAssertTrue(new.isConnected)
        oldPeer.close(); newPeer.close()
        new.close()
    }
}

private final class EndBox: @unchecked Sendable {
    private let lock = NSLock(); private var value: DisplayConnection.EndReason?
    func set(_ v: DisplayConnection.EndReason) { lock.lock(); value = v; lock.unlock() }
    func get() -> DisplayConnection.EndReason? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class ConnectionHolder: @unchecked Sendable {
    private let lock = NSLock(); private var value: DisplayConnection?
    func set(_ v: DisplayConnection?) { lock.lock(); value = v; lock.unlock() }
    func get() -> DisplayConnection? { lock.lock(); defer { lock.unlock() }; return value }
}
