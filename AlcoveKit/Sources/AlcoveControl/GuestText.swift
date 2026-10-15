import Foundation

/// Decodes text files read from a guest.
enum GuestText {
    /// UTF-16LE when `utf16` is set or `data` starts with `FF FE` but not `FF FE 00 00` (a leading `FF FE` is dropped);
    /// UTF-32LE without its leading `FF FE 00 00` when `utf16` is not set and `data` starts with those bytes; UTF-8 with
    /// a leading BOM stripped, otherwise UTF-8. Invalid sequences become U+FFFD.
    static func decode(_ data: Data, utf16: Bool = false) -> String {
        let bytes = [UInt8](data)
        if !utf16, bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            let body = bytes.dropFirst(4)
            var scalars = String.UnicodeScalarView()
            var index = body.startIndex
            while index + 3 < body.endIndex {
                let value = UInt32(body[index]) | UInt32(body[index + 1]) << 8 | UInt32(body[index + 2]) << 16 | UInt32(body[index + 3]) << 24
                scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
                index += 4
            }
            if index < body.endIndex { scalars.append("\u{FFFD}") }
            return String(scalars)
        }
        let marked = bytes.starts(with: [0xFF, 0xFE])
        if utf16 || marked {
            let body = marked ? bytes.dropFirst(2) : bytes[...]
            var units: [UInt16] = []
            units.reserveCapacity(body.count / 2 + 1)
            var index = body.startIndex
            while index + 1 < body.endIndex {
                units.append(UInt16(body[index]) | UInt16(body[index + 1]) << 8)
                index += 2
            }
            if index < body.endIndex { units.append(0xFFFD) }
            return String(decoding: units, as: UTF16.self)
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: bytes.dropFirst(3), as: UTF8.self)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
