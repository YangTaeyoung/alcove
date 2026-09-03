import XCTest
@testable import AlcoveDisplayProtocol

final class DisplayGeometryTests: XCTestCase {
    private let wide = CGSize(width: 1920, height: 1080)   // 16:9
    private let classic = CGSize(width: 800, height: 600)  // 4:3

    // MARK: aspectFitRect

    func testLetterboxWhenSurfaceIsWiderThanView() {
        let r = DisplayGeometry.aspectFitRect(surface: wide, in: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(r.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(r.width, 1000, accuracy: 1e-9)
        XCTAssertEqual(r.height, 562.5, accuracy: 1e-9)
        XCTAssertEqual(r.minY, 218.75, accuracy: 1e-9)
        XCTAssertEqual(r.midX, 500, accuracy: 1e-9)
        XCTAssertEqual(r.midY, 500, accuracy: 1e-9)
    }

    func testPillarboxWhenSurfaceIsTallerThanView() {
        let r = DisplayGeometry.aspectFitRect(surface: classic, in: CGSize(width: 1000, height: 500))
        XCTAssertEqual(r.minY, 0, accuracy: 1e-9)
        XCTAssertEqual(r.height, 500, accuracy: 1e-9)
        XCTAssertEqual(r.width, 2000.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(r.minX, 500.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(r.midX, 500, accuracy: 1e-9)
    }

    func testExactFitFillsTheView() {
        let r = DisplayGeometry.aspectFitRect(surface: wide, in: CGSize(width: 960, height: 540))
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 960, height: 540))
    }

    func testDegenerateSizesYieldZeroRect() {
        XCTAssertEqual(DisplayGeometry.aspectFitRect(surface: .zero, in: CGSize(width: 100, height: 100)), .zero)
        XCTAssertEqual(DisplayGeometry.aspectFitRect(surface: wide, in: .zero), .zero)
        XCTAssertEqual(DisplayGeometry.aspectFitRect(surface: CGSize(width: -1, height: 10), in: CGSize(width: 100, height: 100)), .zero)
    }

    // MARK: guestPoint

    func testCornersMapToExtremesInFlippedView() {
        let view = CGSize(width: 1000, height: 1000)
        let r = DisplayGeometry.aspectFitRect(surface: wide, in: view)
        let tl = DisplayGeometry.guestPoint(from: CGPoint(x: r.minX, y: r.minY), viewSize: view, surface: wide, flippedY: true)
        let br = DisplayGeometry.guestPoint(from: CGPoint(x: r.maxX, y: r.maxY), viewSize: view, surface: wide, flippedY: true)
        let tr = DisplayGeometry.guestPoint(from: CGPoint(x: r.maxX, y: r.minY), viewSize: view, surface: wide, flippedY: true)
        XCTAssertEqual(tl?.x, 0); XCTAssertEqual(tl?.y, 0)
        XCTAssertEqual(br?.x, 32767); XCTAssertEqual(br?.y, 32767)
        XCTAssertEqual(tr?.x, 32767); XCTAssertEqual(tr?.y, 0)
    }

    func testCornersMapToExtremesInUnflippedView() {
        // AppKit default: origin bottom-left, so the *lowest* y is the guest's bottom row.
        let view = CGSize(width: 1000, height: 500)
        let r = DisplayGeometry.aspectFitRect(surface: classic, in: view)
        let bottomLeft = DisplayGeometry.guestPoint(from: CGPoint(x: r.minX, y: r.minY), viewSize: view, surface: classic, flippedY: false)
        let topRight = DisplayGeometry.guestPoint(from: CGPoint(x: r.maxX, y: r.maxY), viewSize: view, surface: classic, flippedY: false)
        XCTAssertEqual(bottomLeft?.x, 0); XCTAssertEqual(bottomLeft?.y, 32767)
        XCTAssertEqual(topRight?.x, 32767); XCTAssertEqual(topRight?.y, 0)
    }

    func testCenterMapsToMidpoint() {
        let view = CGSize(width: 1000, height: 1000)
        let p = DisplayGeometry.guestPoint(from: CGPoint(x: 500, y: 500), viewSize: view, surface: wide, flippedY: true)
        XCTAssertEqual(p?.x, 16384)  // 32767 / 2 rounded
        XCTAssertEqual(p?.y, 16384)
    }

    func testOutsideFittedRectReturnsNil() {
        let view = CGSize(width: 1000, height: 1000)
        // Letterbox bars above and below the 16:9 surface.
        XCTAssertNil(DisplayGeometry.guestPoint(from: CGPoint(x: 500, y: 10), viewSize: view, surface: wide, flippedY: true))
        XCTAssertNil(DisplayGeometry.guestPoint(from: CGPoint(x: 500, y: 990), viewSize: view, surface: wide, flippedY: true))
        // Beyond the view entirely.
        XCTAssertNil(DisplayGeometry.guestPoint(from: CGPoint(x: -5, y: 500), viewSize: view, surface: wide, flippedY: true))
        XCTAssertNil(DisplayGeometry.guestPoint(from: CGPoint(x: 1200, y: 500), viewSize: view, surface: wide, flippedY: true))
    }

    func testOutsideIsClampedWhenRequested() {
        let view = CGSize(width: 1000, height: 1000)
        let above = DisplayGeometry.guestPoint(from: CGPoint(x: 500, y: 10), viewSize: view, surface: wide, flippedY: true, clampToSurface: true)
        XCTAssertEqual(above?.x, 16384); XCTAssertEqual(above?.y, 0)
        let farRight = DisplayGeometry.guestPoint(from: CGPoint(x: 5000, y: 5000), viewSize: view, surface: wide, flippedY: true, clampToSurface: true)
        XCTAssertEqual(farRight?.x, 32767); XCTAssertEqual(farRight?.y, 32767)
        let farLeft = DisplayGeometry.guestPoint(from: CGPoint(x: -100, y: -100), viewSize: view, surface: wide, flippedY: true, clampToSurface: true)
        XCTAssertEqual(farLeft?.x, 0); XCTAssertEqual(farLeft?.y, 0)
    }

    func testDegenerateGeometryReturnsNilEvenWhenClamping() {
        XCTAssertNil(DisplayGeometry.guestPoint(from: CGPoint(x: 1, y: 1), viewSize: .zero, surface: wide, flippedY: true, clampToSurface: true))
        XCTAssertNil(DisplayGeometry.guestPoint(from: CGPoint(x: 1, y: 1), viewSize: CGSize(width: 10, height: 10), surface: .zero, flippedY: true, clampToSurface: true))
    }

    func testResultsAreIndependentOfBackingScale() {
        // The same physical location expressed in points (1x) and in pixels (2x)
        // must map to the same guest coordinate, and a surface reported at
        // twice the pixel count with the same aspect fits the same rectangle.
        let view1x = CGSize(width: 1000, height: 700), view2x = CGSize(width: 2000, height: 1400)
        let p1x = CGPoint(x: 333, y: 222), p2x = CGPoint(x: 666, y: 444)
        let a = DisplayGeometry.guestPoint(from: p1x, viewSize: view1x, surface: wide, flippedY: true)
        let b = DisplayGeometry.guestPoint(from: p2x, viewSize: view2x, surface: wide, flippedY: true)
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.x, b?.x); XCTAssertEqual(a?.y, b?.y)

        let hiDPISurface = CGSize(width: 3840, height: 2160)
        let c = DisplayGeometry.guestPoint(from: p1x, viewSize: view1x, surface: hiDPISurface, flippedY: true)
        XCTAssertEqual(a?.x, c?.x); XCTAssertEqual(a?.y, c?.y)
        XCTAssertEqual(DisplayGeometry.aspectFitRect(surface: wide, in: view1x),
                       DisplayGeometry.aspectFitRect(surface: hiDPISurface, in: view1x))

        let r1 = DisplayGeometry.aspectFitRect(surface: wide, in: view1x)
        let r2 = DisplayGeometry.aspectFitRect(surface: wide, in: view2x)
        XCTAssertEqual(r2.minX, r1.minX * 2, accuracy: 1e-9)
        XCTAssertEqual(r2.minY, r1.minY * 2, accuracy: 1e-9)
        XCTAssertEqual(r2.width, r1.width * 2, accuracy: 1e-9)
        XCTAssertEqual(r2.height, r1.height * 2, accuracy: 1e-9)
    }

    func testMonotonicAcrossTheSurface() {
        let view = CGSize(width: 1000, height: 1000)
        let r = DisplayGeometry.aspectFitRect(surface: wide, in: view)
        var last = -1
        for i in 0...100 {
            let x = r.minX + r.width * CGFloat(i) / 100
            guard let p = DisplayGeometry.guestPoint(from: CGPoint(x: x, y: r.midY), viewSize: view, surface: wide, flippedY: true) else {
                return XCTFail("point \(i) unexpectedly outside")
            }
            XCTAssertGreaterThanOrEqual(p.x, last)
            XCTAssertTrue((0...32767).contains(p.x))
            last = p.x
        }
        XCTAssertEqual(last, 32767)
    }
}
