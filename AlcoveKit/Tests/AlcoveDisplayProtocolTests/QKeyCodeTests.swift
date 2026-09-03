import XCTest
@testable import AlcoveDisplayProtocol

final class QKeyCodeTests: XCTestCase {
    func testOrdinalsMatchQapi() {
        // Spot checks against qapi/ui.json ordering for the pinned QEMU tag.
        XCTAssertEqual(QKeyCode.unmapped.rawValue, 0)
        XCTAssertEqual(QKeyCode.shift.rawValue, 1)
        XCTAssertEqual(QKeyCode.k1.rawValue, 9)
        XCTAssertEqual(QKeyCode.k0.rawValue, 18)
        XCTAssertEqual(QKeyCode.metaL.qapiName, "meta_l")
    }
}
