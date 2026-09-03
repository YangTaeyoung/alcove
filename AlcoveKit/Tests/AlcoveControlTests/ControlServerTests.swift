import XCTest
@testable import AlcoveControl
import AlcoveEngine
import AlcoveQMP

final class ControlServerTests: XCTestCase {
    func testRequestsOverTheSocket() async throws {
        let path = "/tmp/alcove-ctl-\(UUID().uuidString.prefix(8)).sock"
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 320, height: 200))
        let server = ControlServer(handler: ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test"), socketPath: path)
        try server.start()
        defer { server.stop() }
        XCTAssertTrue(ControlServer.isAlive(at: path))

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in p.withMemoryRebound(to: CChar.self, capacity: 104) { dst in _ = path.withCString { strncpy(dst, $0, 103) } } }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(rc, 0)
        defer { close(fd) }

        func call(_ line: String) -> JSON {
            _ = line.withCString { write(fd, $0, strlen($0)) }
            var out = [UInt8](); var b: UInt8 = 0
            while read(fd, &b, 1) == 1 { if b == 10 { break }; out.append(b) }
            return try! JSON.parse(Data(out))
        }
        let hello = call("{\"id\":1,\"op\":\"hello\"}\n")
        XCTAssertEqual(hello["ok"]?.boolValue, true); XCTAssertEqual(hello["id"]?.intValue, 1); XCTAssertEqual(hello["version"]?.intValue, 1)
        // two requests in one write are answered in order
        _ = "{\"id\":2,\"op\":\"vm.status\",\"name\":\"Win\"}\n{\"id\":3,\"op\":\"vm.list\"}\n".withCString { write(fd, $0, strlen($0)) }
        func readReply() -> JSON { var out = [UInt8](); var b: UInt8 = 0; while read(fd, &b, 1) == 1 { if b == 10 { break }; out.append(b) }; return try! JSON.parse(Data(out)) }
        let r2 = readReply(), r3 = readReply()
        XCTAssertEqual(r2["id"]?.intValue, 2); XCTAssertEqual(r2["width"]?.intValue, 320)
        XCTAssertEqual(r3["id"]?.intValue, 3); XCTAssertEqual(r3["vms"]?[0]?["name"]?.stringValue, "Win")
        let bad = call("{\"id\":4,\"op\":\"vm.status\",\"name\":\"X\"}\n")
        XCTAssertEqual(bad["ok"]?.boolValue, false); XCTAssertTrue(bad["error"]!.stringValue!.contains("no VM named"))
        let garbage = call("not json\n")
        XCTAssertEqual(garbage["ok"]?.boolValue, false)
        let shot = call("{\"id\":5,\"op\":\"vm.screenshot\",\"name\":\"Win\"}\n")
        XCTAssertEqual(shot["sentWidth"]?.intValue, 320)
        XCTAssertGreaterThan(shot["png"]!.stringValue!.count, 100)
    }
}
