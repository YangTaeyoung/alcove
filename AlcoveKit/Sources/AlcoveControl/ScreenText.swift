import Foundation
import CoreGraphics
import CoreText
import Synchronization
import Vision

/// One recognized line of text with its rectangle in guest pixels.
struct TextMatch: Sendable, Equatable {
    let text: String
    let rect: Frame.Rect
    let confidence: Double
}

/// Text recognition on guest frames with the Vision framework.
enum ScreenText {
    /// The languages of the first recognition of a reading without `languages`.
    static let defaultLanguages = ["ko-KR", "en-US"]
    /// The languages of its second recognition.
    static let latinLanguages = ["en-US"]

    /// The lines of `frame` in reading order. With `languages`, what one recognition with that list returns.
    /// Without, `merged` of a recognition with `defaultLanguages` and one with `latinLanguages`.
    static func read(_ frame: Frame, languages: [String]?,
                     with recognizer: @Sendable (Frame, [String]) throws -> [TextMatch]) throws -> [TextMatch] {
        if let languages { return try recognizer(frame, languages) }
        let standard = try recognizer(frame, defaultLanguages)
        return merged(standard, latin: try recognizer(frame, latinLanguages))
    }

    static let warmUpText = "Alcove 한글"

    /// A white frame of 400x64 pixels with `warmUpText` in black.
    static func warmUpFrame() -> Frame {
        let width = 400, height = 64
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return }
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let font = CTFontCreateUIFontForLanguage(.system, 24, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)] as CFDictionary
            if let text = CFAttributedStringCreate(nil, warmUpText as CFString, attributes) {
                ctx.textPosition = CGPoint(x: 16, y: 22)
                CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
            }
            for i in stride(from: 3, to: buffer.count, by: 4) { buffer[i] = 255 }
        }
        return Frame(width: width, height: height, pixels: data)
    }

    /// One reading of an area from two recognitions of it, in reading order. Two lines are partners when their
    /// rectangles intersect horizontally and overlap vertically by at least half the height of the less tall one.
    /// A line of `standard` that holds Hangul or has no partner in `latin` stays; one without Hangul gives way to
    /// its partners. A line of `latin` stays when one of its partners holds no Hangul.
    static func merged(_ standard: [TextMatch], latin: [TextMatch]) -> [TextMatch] {
        var replaced = Set<Int>()
        var taken: [TextMatch] = []
        for line in latin {
            let plain = standard.indices.filter { arePartners(standard[$0].rect, line.rect) && !holdsHangul(standard[$0].text) }
            guard !plain.isEmpty else { continue }
            replaced.formUnion(plain)
            taken.append(line)
        }
        return readingOrder(standard.indices.filter { !replaced.contains($0) }.map { standard[$0] } + taken)
    }

    private static func arePartners(_ a: Frame.Rect, _ b: Frame.Rect) -> Bool {
        let vertical = min(a.y + a.h, b.y + b.h) - max(a.y, b.y)
        let horizontal = min(a.x + a.w, b.x + b.w) - max(a.x, b.x)
        return horizontal > 0 && vertical * 2 >= min(a.h, b.h)
    }

    /// Whether `text` has a Hangul syllable or a Hangul letter (jamo).
    private static func holdsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0xAC00...0xD7A3).contains(scalar.value) || (0x1100...0x11FF).contains(scalar.value) || (0x3130...0x318F).contains(scalar.value)
        }
    }

    /// Frames narrower than this are enlarged before recognition.
    static let upscaleBelowWidth = 400
    static let upscaleFactor = 2

    /// The pixel rectangle (top-left origin) of a Vision bounding box in an image of `width` x `height` pixels
    /// that shows the area enlarged by `scale`, cut to the area: at least one pixel wide and high, and inside it.
    static func pixelRect(of box: CGRect, width: Double, height: Double, scale: Double) -> Frame.Rect {
        let areaWidth = width / scale, areaHeight = height / scale
        let left = min(max(0, (box.minX * areaWidth).rounded(.down)), areaWidth - 1)
        let right = min(areaWidth, (box.maxX * areaWidth).rounded(.up))
        let top = min(max(0, ((1 - box.maxY) * areaHeight).rounded(.down)), areaHeight - 1)
        let bottom = min(areaHeight, ((1 - box.minY) * areaHeight).rounded(.up))
        return Frame.Rect(x: Int(left), y: Int(top), w: max(1, Int(right - left)), h: max(1, Int(bottom - top)))
    }

    /// A list of language codes that is read until one read succeeds and kept from then on.
    final class LanguageList: Sendable {
        private let known = Mutex<[String]?>(nil)
        private let read: @Sendable () throws -> [String]

        init(read: @escaping @Sendable () throws -> [String]) { self.read = read }

        func get() throws -> [String] {
            if let known = known.withLock({ $0 }) { return known }
            let fresh = try read()
            known.withLock { $0 = fresh }
            return fresh
        }
    }

    /// The languages Vision recognizes at the accurate level.
    static let supportedLanguages = LanguageList {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return try request.supportedRecognitionLanguages()
    }

    /// Throws when Vision does not support one of `languages`.
    static func validate(languages: [String]) throws {
        let supported = try WaitTiming.supportedLanguages()
        for language in languages where !supported.contains(language) {
            throw ControlHandler.ControlError.failed("language '\(language)' is not supported; supported: \(supported.joined(separator: ", "))")
        }
    }

    /// Recognized lines in reading order with rectangles in the coordinates of `frame` (top-left origin).
    static func recognize(_ frame: Frame, languages: [String]) throws -> [TextMatch] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try validate(languages: languages)
        request.recognitionLanguages = languages

        guard var image = frame.cgImage() else { throw ControlHandler.ControlError.failed("the frame cannot be read for text recognition") }
        var factor = 1
        if frame.width < upscaleBelowWidth {
            factor = upscaleFactor
            guard let enlarged = enlarge(image, by: factor) else { throw ControlHandler.ControlError.failed("the frame cannot be enlarged for text recognition") }
            image = enlarged
        }
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
        catch { throw ControlHandler.ControlError.recognitionFailed(error.localizedDescription) }

        let width = Double(image.width), height = Double(image.height), scale = Double(factor)
        var lines: [TextMatch] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let rect = pixelRect(of: observation.boundingBox, width: width, height: height, scale: scale)
            lines.append(TextMatch(text: candidate.string, rect: rect, confidence: Double(candidate.confidence)))
        }
        return readingOrder(lines)
    }

    /// Lines that contain `query` (case-insensitive) or match it as a regular expression; every line for an empty query.
    static func filter(_ lines: [TextMatch], query: String, regex: Bool) throws -> [TextMatch] {
        if regex {
            let expression: NSRegularExpression
            do { expression = try NSRegularExpression(pattern: query, options: [.caseInsensitive]) }
            catch { throw ControlHandler.ControlError.failed("'\(query)' is not a valid regular expression") }
            return lines.filter { expression.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil }
        }
        if query.isEmpty { return lines }
        return lines.filter { $0.text.range(of: query, options: .caseInsensitive) != nil }
    }

    /// Top to bottom, then left to right; lines whose vertical centres lie within half a line height share a row.
    private static func readingOrder(_ lines: [TextMatch]) -> [TextMatch] {
        var rows: [[TextMatch]] = []
        for line in lines.sorted(by: { ($0.rect.y, $0.rect.x) < ($1.rect.y, $1.rect.x) }) {
            if let first = rows.last?.first {
                let distance = abs(centerY(line) - centerY(first))
                if distance * 2 <= Double(max(line.rect.h, first.rect.h)) {
                    rows[rows.count - 1].append(line)
                    continue
                }
            }
            rows.append([line])
        }
        return rows.flatMap { $0.sorted { $0.rect.x < $1.rect.x } }
    }

    private static func centerY(_ line: TextMatch) -> Double { Double(line.rect.y) + Double(line.rect.h) / 2 }

    private static func enlarge(_ image: CGImage, by factor: Int) -> CGImage? {
        let width = image.width * factor, height = image.height * factor
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
