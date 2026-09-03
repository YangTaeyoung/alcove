import XCTest
@testable import AlcoveQMP

final class JSONTests: XCTestCase {
    func testRoundTripAndTypes() throws {
        let v: JSON = ["a": 1, "b": true, "c": "s", "d": [1, 2.5, nil], "e": ["x": -3]]
        let data = try v.serialized()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"a":1,"b":true,"c":"s","d":[1,2.5,null],"e":{"x":-3}}"#)
        let back = try JSON.parse(data)
        XCTAssertEqual(back, v)
        XCTAssertEqual(back["a"]?.intValue, 1)
        XCTAssertEqual(back["b"]?.boolValue, true)
        XCTAssertEqual(back["d"]?[1]?.doubleValue, 2.5)
        XCTAssertEqual(back["d"]?[2]?.isNull, true)
        XCTAssertNil(back["d"]?[3])
        XCTAssertNil(back["a"]?.stringValue)
        XCTAssertEqual(back["e"]?["x"]?.intValue, -3)
    }

    func testBoolIsNotInt() throws {
        let v = try JSON.parse(Data(#"{"t":true,"n":1}"#.utf8))
        XCTAssertEqual(v["t"], .bool(true))
        XCTAssertEqual(v["n"], .int(1))
        XCTAssertNil(v["t"]?.intValue)
    }

    func testLargeIntegersSurvive() throws {
        let v = try JSON.parse(Data(#"{"n":9007199254740993}"#.utf8))
        XCTAssertEqual(v["n"], .int(9007199254740993))
    }
}
