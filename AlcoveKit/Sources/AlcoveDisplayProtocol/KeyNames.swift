import Foundation

/// Maps key names and US-layout characters to macOS virtual keycodes so that
/// automation can type text and press combos ("ctrl+alt+delete") through the
/// display protocol. QEMU translates the macOS keycodes for the guest.
public enum KeyNames {
    /// A key to send: the macOS virtual keycode and whether Shift is needed.
    public struct Key: Equatable, Sendable {
        public let code: Int
        public let shift: Bool
        public init(code: Int, shift: Bool = false) { self.code = code; self.shift = shift }
    }

    public enum KeyError: Error, Equatable, Sendable {
        case unknownKey(String)
        case untypableCharacter(Character)
    }

    // kVK_* values from Carbon HIToolbox/Events.h
    private static let named: [String: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "enter": 36, "return": 36, "tab": 48, "space": 49, "backspace": 51, "delete": 117, "forwarddelete": 117,
        "esc": 53, "escape": 53, "cmd": 55, "command": 55, "win": 55, "meta": 55, "super": 55,
        "shift": 56, "capslock": 57, "alt": 58, "option": 58, "ctrl": 59, "control": 59,
        "rshift": 60, "ralt": 61, "rctrl": 62, "rcmd": 54, "fn": 63,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "printscreen": 105, "scrolllock": 107, "pause": 113,
        "home": 115, "pageup": 116, "end": 119, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
        "insert": 114, "help": 114,
        "numpad0": 82, "numpad1": 83, "numpad2": 84, "numpad3": 85, "numpad4": 86, "numpad5": 87, "numpad6": 88,
        "numpad7": 89, "numpad8": 91, "numpad9": 92, "numpadenter": 76, "numpad+": 69, "numpad-": 78,
        "numpad*": 67, "numpad/": 75, "numpad.": 65, "numpad=": 81, "numlock": 71, "clear": 71,
    ]

    /// Shifted US-layout characters → base key name.
    private static let shifted: [Character: String] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    public static let modifiers: Set<String> = ["cmd", "command", "win", "meta", "super", "shift", "alt", "option", "ctrl", "control", "rshift", "ralt", "rctrl", "rcmd", "fn"]

    /// Keycode for a key name (case-insensitive). Single characters are typed as themselves.
    public static func key(named raw: String) throws -> Key {
        let name = raw.lowercased()
        if let code = named[name] { return Key(code: code) }
        if name.count == 1, let ch = name.first { return try key(for: ch) }
        throw KeyError.unknownKey(raw)
    }

    /// Keycode and shift state for a character in the US layout.
    public static func key(for ch: Character) throws -> Key {
        if ch == " " { return Key(code: 49) }
        if ch == "\n" || ch == "\r" { return Key(code: 36) }
        if ch == "\t" { return Key(code: 48) }
        if ch.isUppercase, let lower = ch.lowercased().first, let code = named[String(lower)] { return Key(code: code, shift: true) }
        if let base = shifted[ch], let code = named[base] { return Key(code: code, shift: true) }
        if let code = named[String(ch)] { return Key(code: code) }
        throw KeyError.untypableCharacter(ch)
    }

    /// Parse a combo like "ctrl+alt+delete" or "win+r" into modifiers and the final key.
    public static func combo(_ spec: String) throws -> (modifiers: [Key], key: Key?) {
        let parts = spec.split(separator: "+", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        var mods: [Key] = []
        var main: Key?
        var literalPlus = false
        for (i, part) in parts.enumerated() {
            if part.isEmpty {
                // "ctrl++" means the plus key
                if i == parts.count - 1 || (i > 0 && parts[i - 1].isEmpty) { literalPlus = true }
                continue
            }
            if modifiers.contains(part.lowercased()) { mods.append(try key(named: part)) } else { main = try key(named: part) }
        }
        if literalPlus { main = try key(for: "+") }
        return (mods, main)
    }

    /// The events (down/up in order) for pressing a combo.
    public static func pressSequence(_ spec: String) throws -> [(code: Int, down: Bool)] {
        let (mods, main) = try combo(spec)
        var seq: [(Int, Bool)] = []
        var allMods = mods
        if let main, main.shift, !mods.contains(where: { $0.code == 56 || $0.code == 60 }) { allMods.append(Key(code: 56)) }
        for m in allMods { seq.append((m.code, true)) }
        if let main { seq.append((main.code, true)); seq.append((main.code, false)) }
        for m in allMods.reversed() { seq.append((m.code, false)) }
        return seq
    }

    /// The events for typing text in the US layout. Throws on the first untypable character.
    public static func typeSequence(_ text: String) throws -> [(code: Int, down: Bool)] {
        var seq: [(Int, Bool)] = []
        var shiftHeld = false
        for ch in text {
            let k = try key(for: ch)
            if k.shift != shiftHeld { seq.append((56, k.shift)); shiftHeld = k.shift }
            seq.append((k.code, true)); seq.append((k.code, false))
        }
        if shiftHeld { seq.append((56, false)) }
        return seq
    }
}
