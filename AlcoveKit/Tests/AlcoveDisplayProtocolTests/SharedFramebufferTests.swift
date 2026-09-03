import XCTest
@testable import AlcoveDisplayProtocol

final class SharedFramebufferTests: XCTestCase {
    func testMapsFileAndReadsPixels() throws {
        let path = NSTemporaryDirectory() + "alcove-fb-\(UUID().uuidString).bgra"
        defer { unlink(path) }
        var bytes = [UInt8](repeating: 0, count: 16384)
        bytes[0] = 0xAA; bytes[1] = 0xBB; bytes[2] = 0xCC; bytes[3] = 0xDD
        bytes[16383] = 0x7F
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        let fb = try SharedFramebuffer(path: path, size: 16384)
        XCTAssertEqual(fb.size, 16384)
        fb.withBytes { buf in
            XCTAssertEqual(buf[0], 0xAA); XCTAssertEqual(buf[3], 0xDD); XCTAssertEqual(buf[16383], 0x7F)
        }
        // `baseAddress` is only valid while `fb` is alive, and Swift may release `fb`
        // right after its last use; pin the lifetime explicitly around raw-pointer use.
        withExtendedLifetime(fb) {
            XCTAssertEqual(fb.baseAddress.load(as: UInt8.self), 0xAA)
            XCTAssertEqual(fb.baseAddress.load(fromByteOffset: 16383, as: UInt8.self), 0x7F)
        }
    }

    func testSeesWritesMadeAfterMapping() throws {
        let path = NSTemporaryDirectory() + "alcove-fb-\(UUID().uuidString).bgra"
        defer { unlink(path) }
        try Data(repeating: 0, count: 4096).write(to: URL(fileURLWithPath: path))
        let fb = try SharedFramebuffer(path: path, size: 4096)
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try h.seek(toOffset: 100); try h.write(contentsOf: Data([0x42])); try h.close()
        XCTAssertEqual(fb.withBytes { $0[100] }, 0x42)
    }

    func testRejectsShortFileAndMissingFile() throws {
        let path = NSTemporaryDirectory() + "alcove-fb-\(UUID().uuidString).bgra"
        defer { unlink(path) }
        try Data(repeating: 0, count: 100).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try SharedFramebuffer(path: path, size: 4096))
        XCTAssertThrowsError(try SharedFramebuffer(path: path + ".missing", size: 4096))
    }
}
