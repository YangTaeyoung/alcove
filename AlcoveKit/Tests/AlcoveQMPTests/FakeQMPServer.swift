import Foundation
@testable import AlcoveQMP

/// A scripted QMP server on a unix socket for tests. Runs its own thread with
/// blocking I/O. `handler` maps a request to zero or more reply lines.
final class FakeQMPServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ request: JSON, _ server: FakeQMPServer) -> [JSON]

    let path: String
    private let listenFD: Int32
    private var clientFD: Int32 = -1
    private let lock = NSLock()
    private(set) var requests: [JSON] = []
    var handler: Handler
    let greeting: JSON = ["QMP": ["version": ["qemu": ["major": 11, "minor": 1, "micro": 1], "package": "test"], "capabilities": ["oob"]]]

    init(handler: @escaping Handler = FakeQMPServer.defaultHandler) throws {
        self.handler = handler
        path = "/tmp/alcove-qmp-\(UUID().uuidString.prefix(8)).sock"
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: 104) { dst in _ = path.withCString { strncpy(dst, $0, 103) } }
        }
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        Darwin.listen(listenFD, 1)
        let t = Thread { [self] in serve() }
        t.start()
    }

    static let defaultHandler: Handler = { req, _ in
        switch req["execute"]?.stringValue {
        case "qmp_capabilities": return [["return": [:], "id": req["id"] ?? .null]]
        case "query-status": return [["return": ["running": true, "status": "running"], "id": req["id"] ?? .null]]
        default: return [["error": ["class": "CommandNotFound", "desc": "The command \(req["execute"]?.stringValue ?? "?") has not been found"], "id": req["id"] ?? .null]]
        }
    }

    private func serve() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        lock.lock(); clientFD = fd; lock.unlock()
        sendLine(greeting)
        var pending = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            pending.append(contentsOf: buf[0..<n])
            while let nl = pending.firstIndex(of: 10) {
                let line = Data(pending[pending.startIndex..<nl])
                pending.removeSubrange(pending.startIndex...nl)
                guard let req = try? JSON.parse(line) else { continue }
                lock.lock(); requests.append(req); let h = handler; lock.unlock()
                for reply in h(req, self) { sendLine(reply) }
            }
        }
    }

    /// Write one JSON line to the client (usable from any thread, e.g. to inject events).
    func sendLine(_ json: JSON) {
        lock.lock(); defer { lock.unlock() }
        guard clientFD >= 0, var data = try? json.serialized() else { return }
        data.append(10)
        _ = data.withUnsafeBytes { write(clientFD, $0.baseAddress, $0.count) }
    }

    func emitEvent(_ name: String, data: JSON = [:]) {
        sendLine(["event": .string(name), "data": data, "timestamp": ["seconds": 1, "microseconds": 2]])
    }

    /// Close the client socket (simulates QEMU going away).
    func dropClient() {
        lock.lock(); defer { lock.unlock() }
        if clientFD >= 0 { Darwin.close(clientFD); clientFD = -1 }
    }

    func stop() {
        dropClient()
        Darwin.close(listenFD)
        unlink(path)
    }

    static func ok(_ req: JSON, _ ret: JSON = [:]) -> JSON { ["return": ret, "id": req["id"] ?? .null] }
}
