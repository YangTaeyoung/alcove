import XCTest
import CoreText
import CoreGraphics
import Vision
@testable import AlcoveControl
import AlcoveEngine
import AlcoveQMP
import AlcoveTestSupport

/// Black text on white, drawn with CoreText into a BGRA frame; `rects` are the drawn glyph bounds in top-left pixels.
struct DrawnText {
    let frame: Frame
    let rects: [Frame.Rect]
}

func drawText(_ items: [(String, Int, Int)], width: Int = 1280, height: Int = 800, size: CGFloat = 28) -> DrawnText {
    var data = Data(count: width * height * 4)
    var rects: [Frame.Rect] = []
    data.withUnsafeMutableBytes { buffer in
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateUIFontForLanguage(.system, size, nil)!
        for (text, x, top) in items {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let baselineFromTop = CGFloat(top) + CTFontGetAscent(font)
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(height) - baselineFromTop)
            CTLineDraw(line, ctx)
            let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            rects.append(Frame.Rect(x: x + Int(b.minX), y: Int(baselineFromTop - b.maxY), w: Int(b.width), h: Int(b.height)))
        }
    }
    return DrawnText(frame: Frame(width: width, height: height, pixels: data), rects: rects)
}

private func assertNear(_ rect: Frame.Rect, _ expected: Frame.Rect, tolerance: Int = 12, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(rect.x - expected.x), tolerance, "x \(rect) vs \(expected) \(message)", file: file, line: line)
    XCTAssertLessThanOrEqual(abs(rect.y - expected.y), tolerance, "y \(rect) vs \(expected) \(message)", file: file, line: line)
    XCTAssertLessThanOrEqual(abs(rect.w - expected.w), tolerance, "w \(rect) vs \(expected) \(message)", file: file, line: line)
    XCTAssertLessThanOrEqual(abs(rect.h - expected.h), tolerance, "h \(rect) vs \(expected) \(message)", file: file, line: line)
}

final class ScreenTextTests: XCTestCase {
    func testRecognizesEnglishAndKorean() throws {
        let supported = try VNRecognizeTextRequest(completionHandler: nil).supportedRecognitionLanguages()
        let korean = supported.contains("ko-KR")
        var items: [(String, Int, Int)] = [("Send message", 100, 120)]
        if korean { items.append(("메시지 보내기", 100, 300)) }
        let drawn = drawText(items)
        let lines = try ScreenText.recognize(drawn.frame, languages: korean ? ["ko-KR", "en-US"] : ["en-US"])

        let english = try XCTUnwrap(lines.first { $0.text.lowercased().contains("send message") }, "\(lines)")
        assertNear(english.rect, drawn.rects[0], "english")
        XCTAssertGreaterThan(english.confidence, 0.3)
        guard korean else { throw XCTSkip("ko-KR is not a supported recognition language on this host") }
        let hangul = try XCTUnwrap(lines.first { $0.text.replacingOccurrences(of: " ", with: "").contains("메시지보내기") }, "\(lines)")
        assertNear(hangul.rect, drawn.rects[1], "korean")
    }

    func testLineRectanglesStayInsideTheImage() {
        let left = ScreenText.pixelRect(of: CGRect(x: -0.0004, y: 0.5, width: 0.125, height: 0.125), width: 1280, height: 800, scale: 1)
        XCTAssertEqual(left, Frame.Rect(x: 0, y: 300, w: 160, h: 100))
        let corner = ScreenText.pixelRect(of: CGRect(x: 0.9375, y: -0.0078125, width: 0.078125, height: 0.0625), width: 2560, height: 1600, scale: 2)
        XCTAssertEqual(corner, Frame.Rect(x: 1200, y: 756, w: 80, h: 44))
        let top = ScreenText.pixelRect(of: CGRect(x: 0.25, y: 0.9375, width: 0.5, height: 0.125), width: 400, height: 200, scale: 1)
        XCTAssertEqual(top, Frame.Rect(x: 100, y: 0, w: 200, h: 13))
    }

    func testLinesComeTopToBottomThenLeftToRight() throws {
        let drawn = drawText([("Lower row", 100, 400), ("Upper right", 600, 100), ("Upper left", 100, 104)])
        let lines = try ScreenText.recognize(drawn.frame, languages: ["en-US"])
        let order = lines.map { $0.text.lowercased() }
        XCTAssertEqual(order.count, 3, "\(order)")
        XCTAssertTrue(order[0].contains("upper left"), "\(order)")
        XCTAssertTrue(order[1].contains("upper right"), "\(order)")
        XCTAssertTrue(order[2].contains("lower row"), "\(order)")
    }

    func testRejectsUnsupportedLanguage() throws {
        let drawn = drawText([("Hello", 100, 100)], width: 400, height: 200)
        XCTAssertThrowsError(try ScreenText.recognize(drawn.frame, languages: ["xx-XX"])) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("language 'xx-XX' is not supported; supported: "), text)
            XCTAssertTrue(text.contains("en-US"), text)
        }
    }

    private func match(_ text: String) -> TextMatch {
        TextMatch(text: text, rect: Frame.Rect(x: 0, y: 0, w: 10, h: 10), confidence: 1)
    }

    func testFilterSubstringIsCaseInsensitive() throws {
        let lines = [match("Send Message"), match("Cancel"), match("MESSAGE list")]
        XCTAssertEqual(try ScreenText.filter(lines, query: "message", regex: false).map(\.text), ["Send Message", "MESSAGE list"])
        XCTAssertEqual(try ScreenText.filter(lines, query: "", regex: false).count, 3)
        XCTAssertTrue(try ScreenText.filter(lines, query: "a.c", regex: false).isEmpty)
    }

    func testFilterRegex() throws {
        let lines = [match("Item 12"), match("item x"), match("Total 7")]
        XCTAssertEqual(try ScreenText.filter(lines, query: "^item \\d+$", regex: true).map(\.text), ["Item 12"])
        XCTAssertEqual(try ScreenText.filter(lines, query: "TOTAL", regex: true).map(\.text), ["Total 7"])
    }

    func testFindTextBadRegex() async throws {
        let (h, _) = textHandler(drawText([("Hello", 100, 100)], width: 400, height: 200).frame)
        do {
            _ = try await h.handle(op: "vm.find_text", params: ["name": "Win", "query": "([", "regex": true, "languages": ["en-US"]])
            XCTFail("expected an error")
        } catch let e as ControlHandler.ControlError {
            XCTAssertEqual(e.description, "'([' is not a valid regular expression")
        }
    }

    func testFindTextNoText() async throws {
        let (h, _) = textHandler(drawText([], width: 640, height: 480).frame)
        let r = try await h.handle(op: "vm.find_text", params: ["name": "Win", "languages": ["en-US"]])
        XCTAssertEqual(r["lines"]?.intValue, 0)
        XCTAssertEqual(r["matches"]?.arrayValue?.count, 0)
    }

    func testFindTextRegionOffsetsRects() async throws {
        let drawn = drawText([("Send message", 600, 400)])
        let (h, _) = textHandler(drawn.frame)
        let r = try await h.handle(op: "vm.find_text", params: [
            "name": "Win", "languages": ["en-US"], "region": ["x": 500, "y": 350, "w": 400, "h": 200],
        ])
        let matches = try XCTUnwrap(r["matches"]?.arrayValue)
        XCTAssertEqual(matches.count, 1)
        let m = matches[0]
        let rect = Frame.Rect(x: try XCTUnwrap(m["x"]?.intValue), y: try XCTUnwrap(m["y"]?.intValue),
                              w: try XCTUnwrap(m["w"]?.intValue), h: try XCTUnwrap(m["h"]?.intValue))
        XCTAssertGreaterThanOrEqual(rect.x, 590)
        assertNear(rect, drawn.rects[0], "region")
    }

    func testFindTextUpscalesNarrowRegionAndMapsBack() async throws {
        let drawn = drawText([("Send", 700, 500)])
        let (h, _) = textHandler(drawn.frame)
        let r = try await h.handle(op: "vm.find_text", params: [
            "name": "Win", "languages": ["en-US"], "region": ["x": 660, "y": 470, "w": 200, "h": 100],
        ])
        let m = try XCTUnwrap(r["matches"]?.arrayValue?.first, "\(r)")
        let rect = Frame.Rect(x: try XCTUnwrap(m["x"]?.intValue), y: try XCTUnwrap(m["y"]?.intValue),
                              w: try XCTUnwrap(m["w"]?.intValue), h: try XCTUnwrap(m["h"]?.intValue))
        assertNear(rect, drawn.rects[0], "upscaled region")
    }

    func testFindTextRegionOutsideFrame() async throws {
        let (h, _) = textHandler(drawText([("Hello", 100, 100)], width: 400, height: 200).frame)
        do {
            _ = try await h.handle(op: "vm.find_text", params: ["name": "Win", "region": ["x": 900, "y": 0, "w": 10, "h": 10]])
            XCTFail("expected an error")
        } catch let e as ControlHandler.ControlError {
            XCTAssertTrue(e.description.contains("region is outside the 400x200 frame"), e.description)
        }
    }

    func testFindTextOpMapsResult() async throws {
        let drawn = drawText([("Send message", 100, 120), ("Cancel", 100, 300)])
        let (h, _) = textHandler(drawn.frame)
        let all = try await h.handle(op: "vm.find_text", params: ["name": "Win", "languages": ["en-US"]])
        XCTAssertEqual(all["lines"]?.intValue, 2)
        XCTAssertEqual(all["matches"]?.arrayValue?.count, 2)

        let r = try await h.handle(op: "vm.find_text", params: ["name": "Win", "query": "SEND", "languages": ["en-US"]])
        XCTAssertEqual(r["lines"]?.intValue, 2)
        let matches = try XCTUnwrap(r["matches"]?.arrayValue)
        XCTAssertEqual(matches.count, 1)
        let m = matches[0]
        XCTAssertTrue(m["text"]?.stringValue?.lowercased().contains("send message") == true, "\(m)")
        let x = try XCTUnwrap(m["x"]?.intValue), y = try XCTUnwrap(m["y"]?.intValue)
        let w = try XCTUnwrap(m["w"]?.intValue), hh = try XCTUnwrap(m["h"]?.intValue)
        XCTAssertEqual(m["cx"]?.intValue, x + w / 2)
        XCTAssertEqual(m["cy"]?.intValue, y + hh / 2)
        assertNear(Frame.Rect(x: x, y: y, w: w, h: hh), drawn.rects[0])
        let confidence = try XCTUnwrap(m["confidence"]?.doubleValue)
        XCTAssertEqual(confidence, (confidence * 100).rounded() / 100, accuracy: 1e-9)
    }

    func testFindTextRetriesOnceAfterARecognitionFailure() async throws {
        let calls = LockedBox(0)
        WaitTiming.recognizer = { _, _ in
            calls.value += 1
            if calls.value == 1 { throw ControlHandler.ControlError.recognitionFailed("transient") }
            return [TextMatch(text: "Send", rect: Frame.Rect(x: 1, y: 2, w: 30, h: 10), confidence: 1)]
        }
        addTeardownBlock { WaitTiming.recognizer = { try ScreenText.recognize($0, languages: $1) } }
        let (h, _) = textHandler(drawText([], width: 200, height: 100).frame)
        let r = try await h.handle(op: "vm.find_text", params: ["name": "Win", "query": "send"])
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(r["matches"]?.arrayValue?.count, 1)
    }

    func testFindTextFailsWithAnInstructionAfterTwoRecognitionFailures() async throws {
        let calls = LockedBox(0)
        WaitTiming.recognizer = { _, _ in
            calls.value += 1
            throw ControlHandler.ControlError.recognitionFailed("transient")
        }
        addTeardownBlock { WaitTiming.recognizer = { try ScreenText.recognize($0, languages: $1) } }
        let (h, _) = textHandler(drawText([], width: 200, height: 100).frame)
        do {
            _ = try await h.handle(op: "vm.find_text", params: ["name": "Win"])
            XCTFail("expected an error")
        } catch let e as ControlHandler.ControlError {
            XCTAssertEqual(e.description, "text recognition failed twice; call vm.find_text again or use vm.screenshot")
        }
        XCTAssertEqual(calls.value, 2)
    }

    func testFindTextReportsAnUnsupportedLanguageAtOnce() async throws {
        let calls = LockedBox(0)
        WaitTiming.recognizer = { _, _ in
            calls.value += 1
            return []
        }
        addTeardownBlock { WaitTiming.recognizer = { try ScreenText.recognize($0, languages: $1) } }
        let (h, _) = textHandler(drawText([], width: 200, height: 100).frame)
        do {
            _ = try await h.handle(op: "vm.find_text", params: ["name": "Win", "languages": ["xx-XX"]])
            XCTFail("expected an error")
        } catch let e as ControlHandler.ControlError {
            XCTAssertTrue(e.description.hasPrefix("language 'xx-XX' is not supported; supported: "), e.description)
        }
        XCTAssertLessThanOrEqual(calls.value, 1)
    }

    func testFindTextNamesTheExpectedTypeOfLanguages() async throws {
        let (h, t) = textHandler(drawText([], width: 200, height: 100).frame)
        for bad: JSON in ["en-US", [], ["en-US", 7], 5] {
            do {
                _ = try await h.handle(op: "vm.find_text", params: ["name": "Win", "languages": bad])
                XCTFail("expected an error for \(bad)")
            } catch let e as ControlHandler.ControlError {
                XCTAssertEqual(e.description, "languages must be an array of language codes such as [\"en-US\",\"ko-KR\"]")
            }
        }
        let frames = await t.frameCalls
        XCTAssertEqual(frames, 0)
    }

    func testFindTextDoesNotRetryAFailureThatIsNotARecognitionFailure() async throws {
        let calls = LockedBox(0)
        WaitTiming.recognizer = { _, _ in
            calls.value += 1
            throw ControlHandler.ControlError.failed("the frame cannot be read for text recognition")
        }
        addTeardownBlock { WaitTiming.recognizer = { try ScreenText.recognize($0, languages: $1) } }
        let (h, _) = textHandler(drawText([], width: 200, height: 100).frame)
        do {
            _ = try await h.handle(op: "vm.find_text", params: ["name": "Win"])
            XCTFail("expected an error")
        } catch let e as ControlHandler.ControlError {
            XCTAssertEqual(e.description, "the frame cannot be read for text recognition")
        }
        XCTAssertEqual(calls.value, 1)
    }

    func testFindTextIsReadOnlyAndConcurrent() {
        XCTAssertTrue(ControlHandler.knownOps.contains("vm.find_text"))
        XCTAssertTrue(ControlHandler.isReadOnly(op: "vm.find_text"))
        XCTAssertTrue(ControlHandler.isConcurrent(op: "vm.find_text"))
    }

    private func textHandler(_ frame: Frame) -> (ControlHandler, FakeTarget) {
        let t = FakeTarget(name: "Win", state: .running, png: frame.encoded(.png))
        return (ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test"), t)
    }
}
