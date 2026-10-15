import XCTest
@testable import AlcoveEngine
import AlcoveDisplayProtocol

final class DisplayDrainTests: XCTestCase {
    private func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: 104) { dst in _ = path.withCString { strncpy(dst, $0, 103) } }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw NSError(domain: "connect", code: Int(errno)) }
        return fd
    }

    private func send(_ fd: Int32, _ text: String) {
        var data = Array(text.utf8)[...]
        while !data.isEmpty {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { data = data.dropFirst(n) } else if n < 0, errno == EAGAIN || errno == EINTR { usleep(1000) } else { return }
        }
    }

    func testDrainConsumesMessagesWhileSurfaceTracksSwitch() async throws {
        let path = "/tmp/alcove-d-\(UUID().uuidString.prefix(8)).sock"
        let conn = try DisplayConnection(socketPath: path)
        let drain = VMController.drain(conn)
        let fd = try connect(to: path)

        let update = "{\"t\":\"update\",\"con\":0,\"x\":0,\"y\":0,\"w\":1,\"h\":1}\n"
        send(fd, String(repeating: update, count: 10_000))
        send(fd, "{\"t\":\"switch\",\"con\":0,\"w\":4,\"h\":2,\"stride\":16,\"fmt\":\"bgra8\",\"shm\":\"/a\",\"size\":4096}\n")
        send(fd, String(repeating: update, count: 10_000))
        // the sentinel: the last message the peer sends
        send(fd, "{\"t\":\"switch\",\"con\":0,\"w\":8,\"h\":2,\"stride\":32,\"fmt\":\"bgra8\",\"shm\":\"/b\",\"size\":4096}\n")

        let sentinel = FromQEMU.SurfaceSwitch(con: 0, w: 8, h: 2, stride: 32, fmt: "bgra8", shm: "/b", size: 4096)
        let deadline = Date().addingTimeInterval(10)
        while conn.currentSurface != sentinel, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(conn.currentSurface, sentinel)

        // The peer hangs up after the sentinel; the drain ends once it has consumed every message up to the end.
        Darwin.close(fd)
        let drained = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await drain.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard drained else {
            drain.cancel()
            conn.close()
            return XCTFail("the drain did not reach the end of the stream")
        }

        // A consumer attaching after the drain ended sees none of the messages.
        let late = Task { () -> Int in
            var n = 0
            for await _ in conn.messages { n += 1 }
            return n
        }
        let received = await late.value
        conn.close()
        XCTAssertEqual(received, 0)
    }
}
