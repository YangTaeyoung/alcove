import XCTest
@testable import AlcoveControl
import AlcoveDisplayProtocol

final class FrameTests: XCTestCase {
    /// A frame whose pixel (x, y) is B = x, G = y, R = x ^ y, A = 255.
    private func gradient(_ w: Int, _ h: Int) -> Frame {
        var d = Data(count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let o = (y * w + x) * 4
            d[o] = UInt8(x & 255); d[o + 1] = UInt8(y & 255); d[o + 2] = UInt8((x ^ y) & 255); d[o + 3] = 255
        } }
        return Frame(width: w, height: h, pixels: d)
    }

    private func solid(_ w: Int, _ h: Int, _ v: UInt8) -> Frame {
        var d = Data(repeating: v, count: w * h * 4)
        for i in stride(from: 3, to: d.count, by: 4) { d[i] = 255 }
        return Frame(width: w, height: h, pixels: d)
    }

    /// Adds `delta` to the blue channel of every pixel of one 32x32 tile.
    private func paint(_ f: Frame, tileX: Int, tileY: Int, delta: UInt8) -> Frame {
        var d = f.pixels
        for y in tileY * 32..<(tileY + 1) * 32 { for x in tileX * 32..<(tileX + 1) * 32 {
            let o = (y * f.width + x) * 4
            d[o] = d[o] &+ delta
        } }
        return Frame(width: f.width, height: f.height, pixels: d)
    }

    func testPNGRoundTrip() throws {
        let f = gradient(37, 21)
        let back = try XCTUnwrap(Frame(png: f.encoded(.png)))
        XCTAssertEqual(back, f)
    }

    func testCropClampsAndRefuses() {
        let f = gradient(20, 10)
        XCTAssertEqual(f.clamp(.init(x: 15, y: 5, w: 10, h: 10)), .init(x: 15, y: 5, w: 5, h: 5))
        XCTAssertEqual(f.clamp(.init(x: -3, y: -2, w: 5, h: 4)), .init(x: 0, y: 0, w: 2, h: 2))
        XCTAssertNil(f.clamp(.init(x: 20, y: 0, w: 5, h: 5)))
        XCTAssertNil(f.clamp(.init(x: 0, y: 12, w: 5, h: 5)))
        let c = f.crop(.init(x: 3, y: 2, w: 4, h: 3))
        XCTAssertEqual(c.width, 4); XCTAssertEqual(c.height, 3)
        for y in 0..<3 { for x in 0..<4 {
            let o = (y * 4 + x) * 4
            XCTAssertEqual(c.pixels[o], UInt8(x + 3))
            XCTAssertEqual(c.pixels[o + 1], UInt8(y + 2))
            XCTAssertEqual(c.pixels[o + 2], UInt8((x + 3) ^ (y + 2)))
        } }
    }

    func testScaledSize() {
        let s = gradient(100, 50).scaled(by: 0.5)
        XCTAssertEqual(s.width, 50); XCTAssertEqual(s.height, 25)
        XCTAssertEqual(s.pixels.count, 50 * 25 * 4)
        let tiny = gradient(10, 10).scaled(by: 0.1)
        XCTAssertEqual(tiny.width, 1); XCTAssertEqual(tiny.height, 1)
        XCTAssertEqual(solid(8, 8, 90).scaled(by: 1), solid(8, 8, 90))
    }

    func testScaledKeepsSolidColour() {
        let s = solid(64, 64, 90).scaled(by: 0.25)
        XCTAssertEqual(s.width, 16)
        XCTAssertEqual(Array(s.pixels.prefix(4)), [90, 90, 90, 255])
    }

    func testJPEGEncodes() {
        let data = gradient(32, 32).encoded(.jpeg, quality: 0.5)
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
    }

    func testDiffBoundingBox() {
        let a = solid(160, 128, 50)
        let b = paint(paint(a, tileX: 1, tileY: 1, delta: 100), tileX: 3, tileY: 2, delta: 100)
        let d = FrameDiff.between(a, b)
        XCTAssertEqual(d.changedTiles, 2)
        XCTAssertEqual(d.totalTiles, 5 * 4)
        XCTAssertEqual(d.rect, .init(x: 32, y: 32, w: 3 * 32, h: 2 * 32))
        XCTAssertEqual(d.fraction, 0.1, accuracy: 1e-9)
        XCTAssertEqual(FrameDiff.between(a, a).changedTiles, 0)
        XCTAssertNil(FrameDiff.between(a, a).rect)
    }

    func testDiffIgnoresSmallNoise() {
        let a = solid(64, 64, 50)
        XCTAssertEqual(FrameDiff.between(a, paint(a, tileX: 0, tileY: 0, delta: 10)).changedTiles, 0)
        XCTAssertEqual(FrameDiff.between(a, paint(a, tileX: 0, tileY: 0, delta: 24)).changedTiles, 0)
        XCTAssertEqual(FrameDiff.between(a, paint(a, tileX: 0, tileY: 0, delta: 25)).changedTiles, 1)
    }

    func testDiffPartialEdgeTiles() {
        let a = solid(40, 40, 0)
        var d = a.pixels
        d[(39 * 40 + 39) * 4] = 255
        let diff = FrameDiff.between(a, Frame(width: 40, height: 40, pixels: d))
        XCTAssertEqual(diff.totalTiles, 4)
        XCTAssertEqual(diff.changedTiles, 1)
        XCTAssertEqual(diff.rect, .init(x: 32, y: 32, w: 8, h: 8))
    }

    func testCompareDifferentSizes() {
        let a = solid(64, 64, 1), b = solid(32, 64, 1)
        let d = FrameDiff.between(a, b)
        XCTAssertEqual(d.fraction, 1)
        XCTAssertEqual(d.rect, b.bounds)
    }

    private func sharedFile(_ bytes: [UInt8]) throws -> String {
        let path = NSTemporaryDirectory() + "alcove-frame-\(UUID().uuidString).bgra"
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    func testFrameSourceMapsSharedFile() throws {
        let w = 3, h = 2, stride = 20
        var bytes = [UInt8](repeating: 0xEE, count: 4096)
        for y in 0..<h { for x in 0..<w {
            let o = y * stride + x * 4
            bytes[o] = UInt8(10 * x + y); bytes[o + 1] = UInt8(20 + x); bytes[o + 2] = UInt8(30 + y); bytes[o + 3] = 0
        } }
        let path = try sharedFile(bytes)
        defer { unlink(path) }
        let surface = FromQEMU.SurfaceSwitch(con: 0, w: w, h: h, stride: stride, fmt: "bgra8", shm: path, size: 4096)
        let frame = try XCTUnwrap(FrameSource().frame(for: surface))
        XCTAssertEqual(frame.width, w); XCTAssertEqual(frame.height, h)
        XCTAssertEqual(frame.pixels.count, w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let o = (y * w + x) * 4
            XCTAssertEqual(Array(frame.pixels[o..<o + 4]), [UInt8(10 * x + y), UInt8(20 + x), UInt8(30 + y), 0])
        } }
        XCTAssertNil(FrameSource().frame(for: nil))
        let missing = FromQEMU.SurfaceSwitch(con: 0, w: w, h: h, stride: stride, fmt: "bgra8", shm: "/nonexistent/x", size: 4096)
        XCTAssertNil(FrameSource().frame(for: missing))
    }

    func testFrameAfterSurfaceSwitch() throws {
        let big = try sharedFile([UInt8](repeating: 0x11, count: 8192))
        let small = try sharedFile([UInt8](repeating: 0x22, count: 4096))
        defer { unlink(big); unlink(small) }
        let source = FrameSource()
        let s1 = FromQEMU.SurfaceSwitch(con: 0, w: 32, h: 16, stride: 128, fmt: "bgra8", shm: big, size: 8192)
        let f1 = try XCTUnwrap(source.frame(for: s1))
        XCTAssertEqual(f1.width, 32); XCTAssertEqual(f1.pixels[0], 0x11)
        let s2 = FromQEMU.SurfaceSwitch(con: 0, w: 8, h: 4, stride: 32, fmt: "bgra8", shm: small, size: 4096)
        let f2 = try XCTUnwrap(source.frame(for: s2))
        XCTAssertEqual(f2.width, 8); XCTAssertEqual(f2.height, 4)
        XCTAssertEqual(f2.pixels.count, 8 * 4 * 4); XCTAssertEqual(f2.pixels[0], 0x22)
        let s3 = FromQEMU.SurfaceSwitch(con: 0, w: 16, h: 8, stride: 64, fmt: "bgra8", shm: big, size: 8192)
        XCTAssertEqual(try XCTUnwrap(source.frame(for: s3)).pixels[0], 0x11)
    }
}
