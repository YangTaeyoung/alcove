import XCTest
@testable import AlcoveDisplayProtocol

final class QKeyCodeTests: XCTestCase {
    /// The `QKeyCode` enum of qapi/ui.json at the pinned QEMU tag (v11.1.1), in
    /// declaration order. QEMU's `alcove` backend indexes
    /// `qemu_input_map_qcode_to_linux[q]` directly by this ordinal, so the whole
    /// table (not just a few spot values) must match.
    private static let qapiNames: [String] = [
        "unmapped", "shift", "shift_r", "alt", "alt_r", "ctrl", "ctrl_r", "menu", "esc", "1", "2",
        "3", "4", "5", "6", "7", "8", "9", "0", "minus", "equal", "backspace", "tab", "q", "w", "e",
        "r", "t", "y", "u", "i", "o", "p", "bracket_left", "bracket_right", "ret", "a", "s", "d",
        "f", "g", "h", "j", "k", "l", "semicolon", "apostrophe", "grave_accent", "backslash", "z",
        "x", "c", "v", "b", "n", "m", "comma", "dot", "slash", "asterisk", "spc", "caps_lock", "f1",
        "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "num_lock", "scroll_lock",
        "kp_divide", "kp_multiply", "kp_subtract", "kp_add", "kp_enter", "kp_decimal", "sysrq",
        "kp_0", "kp_1", "kp_2", "kp_3", "kp_4", "kp_5", "kp_6", "kp_7", "kp_8", "kp_9", "less",
        "f11", "f12", "print", "home", "pgup", "pgdn", "end", "left", "up", "down", "right",
        "insert", "delete", "stop", "again", "props", "undo", "front", "copy", "open", "paste",
        "find", "cut", "lf", "help", "meta_l", "meta_r", "compose", "pause", "ro", "hiragana",
        "henkan", "yen", "muhenkan", "katakanahiragana", "kp_comma", "kp_equals", "power", "sleep",
        "wake", "audionext", "audioprev", "audiostop", "audioplay", "audiomute", "volumeup",
        "volumedown", "mediaselect", "mail", "calculator", "computer", "ac_home", "ac_back",
        "ac_forward", "ac_refresh", "ac_bookmarks", "lang1", "lang2", "f13", "f14", "f15", "f16",
        "f17", "f18", "f19", "f20", "f21", "f22", "f23", "f24",
    ]

    func testWholeTableMatchesQapi() {
        XCTAssertEqual(Self.qapiNames.count, 162)
        XCTAssertEqual(QKeyCode.allCases.count, Self.qapiNames.count)
        // Ordinals are dense from 0 and follow declaration order.
        XCTAssertEqual(QKeyCode.allCases.map(\.rawValue), Array(0..<Self.qapiNames.count))
        // Every name at every position: catches insertions, deletions and renames anywhere.
        XCTAssertEqual(QKeyCode.allCases.map(\.qapiName), Self.qapiNames)
        for (i, name) in Self.qapiNames.enumerated() {
            XCTAssertEqual(QKeyCode(rawValue: i)?.qapiName, name, "ordinal \(i)")
        }
    }

    func testOrdinalsMatchQapi() {
        // Spot checks against qapi/ui.json ordering for the pinned QEMU tag.
        XCTAssertEqual(QKeyCode.unmapped.rawValue, 0)
        XCTAssertEqual(QKeyCode.shift.rawValue, 1)
        XCTAssertEqual(QKeyCode.k1.rawValue, 9)
        XCTAssertEqual(QKeyCode.k0.rawValue, 18)
        XCTAssertEqual(QKeyCode.metaL.rawValue, 117)
        XCTAssertEqual(QKeyCode.metaL.qapiName, "meta_l")
        XCTAssertEqual(QKeyCode.f24.rawValue, 161)
        XCTAssertNil(QKeyCode(rawValue: 162))
    }
}
