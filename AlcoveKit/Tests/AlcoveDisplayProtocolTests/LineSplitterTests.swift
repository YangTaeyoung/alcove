import XCTest
@testable import AlcoveDisplayProtocol

final class LineSplitterTests: XCTestCase {
    func testLineSplitAcrossChunks() throws {
        var s = LineSplitter()
        XCTAssertEqual(try s.feed(Data("{\"t\":\"he".utf8)), [])
        XCTAssertEqual(s.pendingCount, 8)
        XCTAssertEqual(try s.feed(Data("llo\"}\n{\"t\":".utf8)), [Data("{\"t\":\"hello\"}".utf8)])
        XCTAssertEqual(try s.feed(Data("\"bye\"}\n".utf8)), [Data("{\"t\":\"bye\"}".utf8)])
        XCTAssertEqual(s.pendingCount, 0)
    }

    func testMultipleLinesInOneChunkAndEmptyLinesDropped() throws {
        var s = LineSplitter()
        let lines = try s.feed(Data("a\n\nb\n\n\nc\n".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["a", "b", "c"])
    }

    func testTooLongLineThrowsAndResets() {
        var s = LineSplitter(maxLineLength: 8)
        XCTAssertThrowsError(try s.feed(Data(repeating: 0x41, count: 9)))
        XCTAssertEqual(s.pendingCount, 0)
        XCTAssertNoThrow(try s.feed(Data("ok\n".utf8)))
    }
}
