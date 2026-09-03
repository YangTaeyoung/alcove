import XCTest
@testable import AlcoveDisplayProtocol

final class DisplayMessageTests: XCTestCase {
    private func decode(_ s: String) throws -> FromQEMU { try FromQEMU.decode(Data(s.utf8)) }

    func testDecodesEveryInboundMessage() throws {
        XCTAssertEqual(try decode(#"{"t":"hello","v":1,"consoles":1,"abs":true}"#),
                       .hello(.init(v: 1, consoles: 1, abs: true)))
        XCTAssertEqual(try decode(#"{"t":"switch","con":0,"w":800,"h":600,"stride":3200,"fmt":"bgra8","shm":"/tmp/fb0-1.bgra","size":1921024}"#),
                       .switchSurface(.init(con: 0, w: 800, h: 600, stride: 3200, fmt: "bgra8", shm: "/tmp/fb0-1.bgra", size: 1921024)))
        XCTAssertEqual(try decode(#"{"t":"update","con":0,"x":1,"y":2,"w":3,"h":4}"#),
                       .update(.init(con: 0, x: 1, y: 2, w: 3, h: 4)))
        XCTAssertEqual(try decode(#"{"t":"cursor","con":0,"w":32,"h":32,"hx":1,"hy":2,"shm":"/tmp/c","size":4096}"#),
                       .cursor(.init(con: 0, w: 32, h: 32, hx: 1, hy: 2, shm: "/tmp/c", size: 4096)))
        XCTAssertEqual(try decode(#"{"t":"mouse","con":0,"x":10,"y":20,"on":false}"#),
                       .mouse(.init(con: 0, x: 10, y: 20, on: false)))
        XCTAssertEqual(try decode(#"{"t":"bye"}"#), .bye)
    }

    func testUnknownTypeIsTolerated() throws {
        XCTAssertEqual(try decode(#"{"t":"future","x":1}"#), .unknown(type: "future"))
    }

    func testHelloWithoutAbsField() throws {
        XCTAssertEqual(try decode(#"{"t":"hello","v":1,"consoles":2}"#), .hello(.init(v: 1, consoles: 2)))
    }

    func testMalformedInput() {
        XCTAssertThrowsError(try decode("not json"))
        XCTAssertThrowsError(try decode(#"{"x":1}"#)) { XCTAssertEqual($0 as? DisplayProtocolError, .missingType) }
        XCTAssertThrowsError(try decode(#"{"t":"update","con":"zero"}"#))
    }

    func testSwitchValidation() {
        var s = FromQEMU.SurfaceSwitch(con: 0, w: 640, h: 480, stride: 2560, fmt: "bgra8", shm: "/x", size: 1228800)
        XCTAssertTrue(s.isValid)
        s.size = 100; XCTAssertFalse(s.isValid)
        s.size = 1228800; s.fmt = "rgb565"; XCTAssertFalse(s.isValid)
        s.fmt = "bgra8"; s.stride = 2000; XCTAssertFalse(s.isValid)
    }

    func testEncodesEveryOutboundMessage() {
        XCTAssertEqual(ToQEMU.key(mac: 0, q: nil, down: true).encodedLine, "{\"t\":\"key\",\"mac\":0,\"down\":true}\n")
        XCTAssertEqual(ToQEMU.key(mac: nil, q: .metaL, down: false).encodedLine, "{\"t\":\"key\",\"q\":117,\"down\":false}\n")
        XCTAssertEqual(ToQEMU.abs(con: 0, x: 100, y: 200).encodedLine, "{\"t\":\"abs\",\"con\":0,\"x\":100,\"y\":200}\n")
        XCTAssertEqual(ToQEMU.rel(con: 1, dx: -3, dy: 2).encodedLine, "{\"t\":\"rel\",\"con\":1,\"dx\":-3,\"dy\":2}\n")
        XCTAssertEqual(ToQEMU.btn(con: 0, button: .wheelDown, down: true).encodedLine, "{\"t\":\"btn\",\"con\":0,\"b\":4,\"down\":true}\n")
        XCTAssertEqual(ToQEMU.sync.encodedLine, "{\"t\":\"sync\"}\n")
        XCTAssertEqual(ToQEMU.lift.encodedLine, "{\"t\":\"lift\"}\n")
        XCTAssertEqual(ToQEMU.ui(con: 0, w: 1920, h: 1080).encodedLine, "{\"t\":\"ui\",\"con\":0,\"w\":1920,\"h\":1080}\n")
        XCTAssertEqual(ToQEMU.refresh(con: 0).encodedLine, "{\"t\":\"refresh\",\"con\":0}\n")
    }

    func testAbsoluteCoordinatesAreClamped() {
        XCTAssertEqual(ToQEMU.abs(con: 0, x: -5, y: 99999).encodedLine, "{\"t\":\"abs\",\"con\":0,\"x\":0,\"y\":32767}\n")
    }

    func testEncodedLinesAreValidJSONWithOneTrailingNewline() throws {
        let all: [ToQEMU] = [.key(mac: 1, q: .a, down: true), .abs(con: 0, x: 1, y: 1), .rel(con: 0, dx: 1, dy: 1),
                             .btn(con: 0, button: .left, down: false), .sync, .lift, .ui(con: 0, w: 1, h: 1), .refresh(con: 0)]
        for m in all {
            let line = m.encodedLine
            XCTAssertTrue(line.hasSuffix("\n")); XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            XCTAssertNotNil(obj?["t"] as? String)
        }
    }

    func testInputButtonOrdinalsMatchQapi() {
        XCTAssertEqual(InputButton.left.rawValue, 0)
        XCTAssertEqual(InputButton.right.rawValue, 2)
        XCTAssertEqual(InputButton.wheelUp.rawValue, 3)
        XCTAssertEqual(InputButton.wheelRight.rawValue, 8)
        XCTAssertEqual(InputButton.touch.rawValue, 9)
    }
}
