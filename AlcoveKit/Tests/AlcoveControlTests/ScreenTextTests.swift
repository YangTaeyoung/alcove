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

private func line(_ text: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int, confidence: Double = 1) -> TextMatch {
    TextMatch(text: text, rect: Frame.Rect(x: x, y: y, w: w, h: h), confidence: confidence)
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

    func testABoxWithoutWidthOrHeightAtTheRightOrBottomEdgeStaysInside() {
        let right = ScreenText.pixelRect(of: CGRect(x: 1, y: 0.5, width: 0, height: 0.125), width: 1280, height: 800, scale: 1)
        XCTAssertEqual(right, Frame.Rect(x: 1279, y: 300, w: 1, h: 100))
        let bottom = ScreenText.pixelRect(of: CGRect(x: 0.25, y: 0, width: 0.5, height: 0), width: 400, height: 200, scale: 1)
        XCTAssertEqual(bottom, Frame.Rect(x: 100, y: 199, w: 200, h: 1))
        let corner = ScreenText.pixelRect(of: CGRect(x: 1, y: 0, width: 0, height: 0), width: 2560, height: 1600, scale: 2)
        XCTAssertEqual(corner, Frame.Rect(x: 1279, y: 799, w: 1, h: 1))
    }

    func testFindTextAddsTheRegionOriginToLineRectangles() async throws {
        WaitTiming.recognizer = { frame, _ in
            [TextMatch(text: "Edge", rect: Frame.Rect(x: frame.width - 1, y: frame.height - 1, w: 1, h: 1), confidence: 1),
             TextMatch(text: "Send", rect: Frame.Rect(x: 10, y: 20, w: 30, h: 12), confidence: 1)]
        }
        addTeardownBlock { WaitTiming.recognizer = { try ScreenText.recognize($0, languages: $1) } }
        let (h, _) = textHandler(drawText([], width: 1280, height: 800).frame)
        let r = try await h.handle(op: "vm.find_text", params: [
            "name": "Win", "languages": ["en-US"], "region": ["x": 500, "y": 350, "w": 400, "h": 200],
        ])
        let rows = try XCTUnwrap(r["matches"]?.arrayValue)
        XCTAssertEqual(rows.count, 2)
        let send = try XCTUnwrap(rows.first { $0["text"]?.stringValue == "Send" })
        XCTAssertEqual([send["x"]?.intValue, send["y"]?.intValue, send["w"]?.intValue, send["h"]?.intValue], [510, 370, 30, 12])
        XCTAssertEqual([send["cx"]?.intValue, send["cy"]?.intValue], [525, 376])
        let edge = try XCTUnwrap(rows.first { $0["text"]?.stringValue == "Edge" })
        XCTAssertEqual([edge["x"]?.intValue, edge["y"]?.intValue, edge["w"]?.intValue, edge["h"]?.intValue], [899, 549, 1, 1])
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
        let r = try await h.handle(op: "vm.find_text", params: ["name": "Win", "query": "send", "languages": ["en-US"]])
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(r["matches"]?.arrayValue?.count, 1)
    }

    // MARK: - the reading without `languages`

    func testMergeTakesTheLatinReadingOfALineWithoutHangul() {
        let standard = [line("Enron 0x80070005: access denied", 11, 467, 253, 17)]
        let latin = [line("Error 0x80070005: access denied", 12, 466, 251, 18, confidence: 0.5)]
        XCTAssertEqual(ScreenText.merged(standard, latin: latin), latin)
    }

    func testMergeKeepsTheStandardReadingOfALineWithHangul() {
        let hangul = line("결제 금액: 128,450원 (부가세 포함)", 11, 333, 265, 23)
        let mixed = line("파일 report-2026.xlsx 저장", 11, 371, 220, 19)
        let jamo = line("ㅇㅋ OK", 11, 409, 60, 19)
        let latin = [line("2M 2O1: 128,450 (4714 TE)", 11, 334, 262, 21), line("Ite report-2026.xlsx MA", 12, 372, 218, 18), line("OK OK", 11, 410, 58, 17)]
        XCTAssertEqual(ScreenText.merged([hangul, mixed, jamo], latin: latin), [hangul, mixed, jamo])
    }

    func testMergeKeepsAStandardLineWithoutAPartnerAndDropsALatinLineWithoutOne() {
        let alone = line("Plain text", 307, 733, 58, 14)
        let above = line("Voun tnial ends", 11, 100, 205, 11)
        let beside = line("Apply", 500, 733, 61, 15)
        XCTAssertEqual(ScreenText.merged([alone], latin: [above, beside]), [alone])
        XCTAssertEqual(ScreenText.merged([], latin: [above, beside]), [])
        XCTAssertEqual(ScreenText.merged([alone], latin: []), [alone])
    }

    func testMergePairsLinesThatOverlapByHalfTheHeightOfTheLessTallOne() {
        let standard = [line("Youn trial", 10, 100, 200, 20)]
        let half = line("Your trial", 10, 110, 200, 20)
        XCTAssertEqual(ScreenText.merged(standard, latin: [half]), [half])
        let less = line("Your trial", 10, 111, 200, 20)
        XCTAssertEqual(ScreenText.merged(standard, latin: [less]), standard)
        let short = line("Your trial", 10, 116, 200, 8)
        XCTAssertEqual(ScreenText.merged(standard, latin: [short]), [short])
        let touching = line("Your trial", 210, 100, 200, 20)
        XCTAssertEqual(ScreenText.merged(standard, latin: [touching]), standard)
    }

    func testMergeReplacesOneStandardLineByEveryLatinLineThatLiesOnItAlone() {
        let wide = line("Yes No Cance| App-y", 13, 657, 201, 17)
        let parts = [line("Yes", 13, 657, 27, 15), line("No Cancel", 57, 657, 95, 15), line("Apply", 153, 657, 61, 17)]
        XCTAssertEqual(ScreenText.merged([wide], latin: parts), parts)
    }

    func testMergeLeavesOutALatinLineThatLiesOnTwoStandardLinesAndKeepsBoth() {
        let pieces = [line("Ln 37,", 19, 733, 50, 15), line("Col1", 75, 733, 30, 15)]
        let whole = line("Ln 37, Col 1", 19, 733, 86, 15)
        XCTAssertEqual(ScreenText.merged(pieces, latin: [whole]), pieces)

        let retry = line("다시 시도", 10, 100, 100, 18)
        let ok = line("OK", 130, 100, 20, 18)
        XCTAssertEqual(ScreenText.merged([retry, ok], latin: [line("#|1 OK", 12, 100, 138, 18)]), [retry, ok])

        let hangul = line("취소", 10, 100, 40, 18)
        let plain = line("App-y", 60, 100, 50, 18)
        XCTAssertEqual(ScreenText.merged([hangul, plain], latin: [line("#1 Apply", 12, 100, 98, 18)]), [hangul, plain])
    }

    func testMergeKeepsAStandardLineWhenOneOfTheLatinLinesOnItAlsoLiesOnAnother() {
        let wide = line("Yes No Cance| App-y", 13, 657, 201, 17)
        let next = line("0K", 250, 657, 30, 17)
        let alone = line("Yes", 13, 657, 27, 15)
        let across = line("No Cancel Apply OK", 57, 657, 223, 17)
        XCTAssertEqual(ScreenText.merged([wide, next], latin: [alone, across]), [wide, next])
    }

    func testMergeReturnsReadingOrderAndOnlyRectanglesOfItsInputs() {
        let standard = [line("Lowen row", 100, 400, 120, 20), line("위 오른쪽", 600, 100, 120, 20), line("Uppen left", 100, 104, 120, 20)]
        let latin = [line("Upper left", 101, 103, 119, 21), line("9| 2E", 600, 101, 118, 19), line("Lower row", 100, 401, 121, 19)]
        let merged = ScreenText.merged(standard, latin: latin)
        XCTAssertEqual(merged.map(\.text), ["Upper left", "위 오른쪽", "Lower row"])
        XCTAssertEqual(merged.map(\.rect), [latin[0].rect, standard[1].rect, latin[2].rect])
    }

    func testAReadingWithoutLanguagesRecognizesWithTheDefaultListThenTheLatinOneAndMerges() throws {
        let seen = LockedBox<[[String]]>([])
        let lines = try ScreenText.read(drawText([], width: 64, height: 64).frame, languages: nil) { _, languages in
            seen.value.append(languages)
            return languages == ["en-US"] ? [line("Alcove OCR check", 45, 117, 130, 15)] : [line("Alcove OR check", 45, 117, 128, 15), line("한글 인식 확인", 45, 136, 110, 21)]
        }
        XCTAssertEqual(seen.value, [["ko-KR", "en-US"], ["en-US"]])
        XCTAssertEqual(lines.map(\.text), ["Alcove OCR check", "한글 인식 확인"])
    }

    func testAReadingWithLanguagesRecognizesOnceWithThatList() throws {
        for languages in [["en-US"], ["ko-KR", "en-US"], ["ko-KR"]] {
            let seen = LockedBox<[[String]]>([])
            let lines = try ScreenText.read(drawText([], width: 64, height: 64).frame, languages: languages) { _, languages in
                seen.value.append(languages)
                return [line("Alcove OR check", 45, 117, 128, 15)]
            }
            XCTAssertEqual(seen.value, [languages])
            XCTAssertEqual(lines.map(\.text), ["Alcove OR check"])
        }
    }

    func testAReadingWithoutLanguagesFindsSmallLatinTextAndHangul() throws {
        guard try ScreenText.supportedLanguages.get().contains("ko-KR") else { throw XCTSkip("ko-KR is not a supported recognition language on this host") }
        let drawn = drawText([("Send message", 100, 120), ("메시지 보내기", 100, 300), ("저장 report.xlsx", 100, 480)])
        let lines = try ScreenText.read(drawn.frame, languages: nil) { try ScreenText.recognize($0, languages: $1) }
        XCTAssertEqual(lines.count, 3, "\(lines)")
        XCTAssertTrue(lines[0].text.lowercased().contains("send message"), "\(lines)")
        XCTAssertTrue(lines[1].text.replacingOccurrences(of: " ", with: "").contains("메시지보내기"), "\(lines)")
        XCTAssertTrue(lines[2].text.contains("저장"), "\(lines)")
        assertNear(lines[0].rect, drawn.rects[0], "latin")
        assertNear(lines[1].rect, drawn.rects[1], "hangul")
    }

    func testFindTextWithoutLanguagesUsesTheMergedReading() async throws {
        let seen = LockedBox<[[String]]>([])
        WaitTiming.recognizer = { _, languages in
            seen.value.append(languages)
            return languages == ["en-US"] ? [line("batch works", 45, 117, 90, 15)] : [line("batch wonks!", 45, 117, 92, 15), line("한글 인식 확인", 45, 136, 110, 21)]
        }
        addTeardownBlock { WaitTiming.recognizer = { try ScreenText.recognize($0, languages: $1) } }
        let (h, _) = textHandler(drawText([], width: 1280, height: 800).frame)
        let all = try await h.handle(op: "vm.find_text", params: ["name": "Win"])
        XCTAssertEqual(all["lines"]?.intValue, 2)
        XCTAssertEqual(all["matches"]?.arrayValue?.compactMap { $0["text"]?.stringValue }, ["batch works", "한글 인식 확인"])
        XCTAssertEqual(seen.value, [["ko-KR", "en-US"], ["en-US"]])

        seen.value = []
        let chosen = try await h.handle(op: "vm.find_text", params: ["name": "Win", "languages": ["ko-KR", "en-US"]])
        XCTAssertEqual(chosen["matches"]?.arrayValue?.compactMap { $0["text"]?.stringValue }, ["batch wonks!", "한글 인식 확인"])
        XCTAssertEqual(seen.value, [["ko-KR", "en-US"]])
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
