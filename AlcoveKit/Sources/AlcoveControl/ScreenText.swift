import Foundation
import CoreGraphics
import Vision

/// One recognized line of text with its rectangle in guest pixels.
struct TextMatch: Sendable, Equatable {
    let text: String
    let rect: Frame.Rect
    let confidence: Double
}

/// Text recognition on guest frames with the Vision framework.
enum ScreenText {
    static let defaultLanguages = ["ko-KR", "en-US"]

    /// Frames narrower than this are enlarged before recognition.
    static let upscaleBelowWidth = 400
    static let upscaleFactor = 2

    /// Recognized lines in reading order with rectangles in the coordinates of `frame` (top-left origin).
    static func recognize(_ frame: Frame, languages: [String]) throws -> [TextMatch] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let supported = try request.supportedRecognitionLanguages()
        for language in languages where !supported.contains(language) {
            throw ControlHandler.ControlError.failed("language '\(language)' is not supported; supported: \(supported.joined(separator: ", "))")
        }
        request.recognitionLanguages = languages

        guard var image = frame.cgImage() else { throw ControlHandler.ControlError.failed("the frame cannot be read for text recognition") }
        var factor = 1
        if frame.width < upscaleBelowWidth {
            factor = upscaleFactor
            guard let enlarged = enlarge(image, by: factor) else { throw ControlHandler.ControlError.failed("the frame cannot be enlarged for text recognition") }
            image = enlarged
        }
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
        catch { throw ControlHandler.ControlError.failed("text recognition failed: \(error.localizedDescription)") }

        let width = Double(image.width), height = Double(image.height), scale = Double(factor)
        var lines: [TextMatch] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let box = observation.boundingBox
            let left = (box.minX * width / scale).rounded(.down)
            let right = (box.maxX * width / scale).rounded(.up)
            let top = ((1 - box.maxY) * height / scale).rounded(.down)
            let bottom = ((1 - box.minY) * height / scale).rounded(.up)
            let rect = Frame.Rect(x: Int(left), y: Int(top), w: max(1, Int(right - left)), h: max(1, Int(bottom - top)))
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
