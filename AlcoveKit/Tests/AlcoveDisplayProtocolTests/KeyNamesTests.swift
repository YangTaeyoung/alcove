import XCTest
@testable import AlcoveDisplayProtocol

final class KeyNamesTests: XCTestCase {
    func testNamesAndCharacters() throws {
        XCTAssertEqual(try KeyNames.key(named: "Enter").code, 36)
        XCTAssertEqual(try KeyNames.key(named: "win").code, 55)
        XCTAssertEqual(try KeyNames.key(named: "F5").code, 96)
        XCTAssertEqual(try KeyNames.key(for: "a"), .init(code: 0))
        XCTAssertEqual(try KeyNames.key(for: "A"), .init(code: 0, shift: true))
        XCTAssertEqual(try KeyNames.key(for: "!"), .init(code: 18, shift: true))
        XCTAssertEqual(try KeyNames.key(for: ":"), .init(code: 41, shift: true))
        XCTAssertEqual(try KeyNames.key(for: " "), .init(code: 49))
        XCTAssertThrowsError(try KeyNames.key(for: "é"))
        XCTAssertThrowsError(try KeyNames.key(named: "nosuchkey"))
    }

    func testComboPressSequence() throws {
        let seq = try KeyNames.pressSequence("ctrl+alt+delete")
        XCTAssertEqual(seq.map { "\($0.code):\($0.down)" }, ["59:true", "58:true", "117:true", "117:false", "58:false", "59:false"])
        let winR = try KeyNames.pressSequence("Win+R")
        XCTAssertEqual(winR.map(\.code), [55, 15, 15, 55])
        // shifted main key adds shift automatically
        let bang = try KeyNames.pressSequence("ctrl+!")
        XCTAssertEqual(bang.map(\.code), [59, 56, 18, 18, 56, 59])
        // modifier alone
        let onlyMod = try KeyNames.pressSequence("shift")
        XCTAssertEqual(onlyMod.map { "\($0.code):\($0.down)" }, ["56:true", "56:false"])
        // literal plus
        XCTAssertEqual(try KeyNames.pressSequence("ctrl++").map(\.code), [59, 56, 24, 24, 56, 59])
    }

    func testTypeSequenceGroupsShift() throws {
        let seq = try KeyNames.typeSequence("Hi!")
        XCTAssertEqual(seq.map { "\($0.code):\($0.down)" },
                       ["56:true", "4:true", "4:false", "56:false", "34:true", "34:false", "56:true", "18:true", "18:false", "56:false"])
        XCTAssertEqual(try KeyNames.typeSequence("ab\n").map(\.code), [0, 0, 11, 11, 36, 36])
        XCTAssertThrowsError(try KeyNames.typeSequence("한"))
    }
}
