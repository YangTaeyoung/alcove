import XCTest
import AVFoundation
@testable import AlcoveControl
import AlcoveQMP

final class VideoRecorderTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("alcove-video-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    private func frame(_ width: Int, _ height: Int, step: Int) -> Frame { movingFrame(width, height, step: step) }

    private func inspect(_ url: URL) async throws -> (tracks: Int, size: CGSize, seconds: Double) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)
        let size = try await tracks.first?.load(.naturalSize) ?? .zero
        return (tracks.count, size, CMTimeGetSeconds(duration))
    }

    func testWritesPlayableFile() async throws {
        let url = base.appendingPathComponent("a.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        for i in 0..<15 { recorder.append(frame: frame(320, 240, step: i), at: .milliseconds(i * 200)); _ = await recorder.waitUntilReady() }
        await recorder.finish()
        XCTAssertNil(recorder.errorMessage)
        let info = try await inspect(url)
        XCTAssertEqual(info.tracks, 1)
        XCTAssertEqual(info.size, CGSize(width: 320, height: 240))
        XCTAssertEqual(info.seconds, 2.8, accuracy: 0.3)
        XCTAssertEqual(recorder.appendedSeconds, 2.8, accuracy: 0.01)
        XCTAssertEqual(recorder.droppedFrames, 0)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0)
    }

    func testCopyMadeWhileTheFileIsWrittenPlays() async throws {
        let url = base.appendingPathComponent("growing.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        for i in 0..<25 { recorder.append(frame: frame(320, 240, step: i), at: .milliseconds(i * 200)); _ = await recorder.waitUntilReady() }
        let copy = base.appendingPathComponent("copy.mp4")
        let plays = await eventually(timeout: .seconds(10)) {
            try? FileManager.default.removeItem(at: copy)
            guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return false }
            return await VideoRecorder.isPlayable(copy)
        }
        XCTAssertTrue(plays)
        let partial = try await inspect(copy)
        XCTAssertEqual(partial.tracks, 1)
        XCTAssertEqual(partial.size, CGSize(width: 320, height: 240))
        XCTAssertGreaterThanOrEqual(partial.seconds, 1)
        XCTAssertLessThanOrEqual(partial.seconds, 4.8)

        recorder.append(frame: frame(320, 240, step: 25), at: .milliseconds(5000)); _ = await recorder.waitUntilReady()
        await recorder.finish()
        XCTAssertNil(recorder.errorMessage)
        let whole = try await inspect(url)
        XCTAssertEqual(whole.tracks, 1)
        XCTAssertEqual(whole.seconds, 5.0, accuracy: 0.3)
    }

    func testCopyCutInsideItsLastFragmentPlays() async throws {
        let url = base.appendingPathComponent("torn.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        for i in 0..<26 { recorder.append(frame: frame(320, 240, step: i), at: .milliseconds(i * 200)); _ = await recorder.waitUntilReady() }
        let fragments = await eventually(timeout: .seconds(10)) {
            guard let data = try? Data(contentsOf: url) else { return false }
            return Self.boxCount("moof", in: data) >= 3
        }
        XCTAssertTrue(fragments)
        let data = try Data(contentsOf: url)
        let lastFragment = min(try XCTUnwrap(Self.lastBoxStart("moof", in: data)), try XCTUnwrap(Self.lastBoxStart("mdat", in: data)))
        let cuts = [data.count - 1, data.count - 17, lastFragment + (data.count - lastFragment) / 2, lastFragment + 8, lastFragment + 1]
        for cut in Set(cuts) where cut > lastFragment && cut < data.count {
            let copy = base.appendingPathComponent("torn-\(cut).mp4")
            try data.prefix(cut).write(to: copy)
            let plays = await VideoRecorder.isPlayable(copy)
            XCTAssertTrue(plays, "a copy of the first \(cut) of \(data.count) bytes does not play")
        }
        await recorder.finish()
    }

    /// The number of top-level boxes of type `type` in the MP4 bytes `data`.
    private static func boxCount(_ type: String, in data: Data) -> Int { boxStarts(type, in: data).count }

    /// The offset of the last top-level box of type `type` in `data`.
    private static func lastBoxStart(_ type: String, in data: Data) -> Int? { boxStarts(type, in: data).last }

    /// The offsets of the top-level boxes of type `type` in `data`; a box size of 1 is followed by a 64-bit size.
    private static func boxStarts(_ type: String, in data: Data) -> [Int] {
        var starts: [Int] = []
        var offset = 0
        let bytes = [UInt8](data)
        func number(_ at: Int, _ count: Int) -> Int { bytes[at..<(at + count)].reduce(0) { $0 << 8 | Int($1) } }
        while offset + 8 <= bytes.count {
            var size = number(offset, 4)
            if size == 1, offset + 16 <= bytes.count { size = number(offset + 8, 8) }
            if String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self) == type { starts.append(offset) }
            guard size >= 8 else { break }
            offset += size
        }
        return starts
    }

    func testFileThatIsNoMovieIsNotPlayable() async throws {
        let url = base.appendingPathComponent("text.mp4")
        try Data("not a movie".utf8).write(to: url)
        let plays = await VideoRecorder.isPlayable(url)
        XCTAssertFalse(plays)
        let missing = await VideoRecorder.isPlayable(base.appendingPathComponent("missing.mp4"))
        XCTAssertFalse(missing)
    }

    func testFramesWithUnevenTimesAreWrittenWithoutAWriterError() async throws {
        let url = base.appendingPathComponent("uneven.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        var seconds = 0.0
        for i in 0..<100 {
            let tick = Int64(seconds * Double(VideoRecorder.timeScale))
            seconds += 0.2
            recorder.append(frame: noisyFrame(1280, 800, step: i), at: .nanoseconds(tick * 1_000_000_000 / Int64(VideoRecorder.timeScale) + 500_000))
            _ = await recorder.waitUntilReady()
        }
        await recorder.finish()
        XCTAssertNil(recorder.errorMessage)
        XCTAssertEqual(recorder.droppedFrames, 0)
        let info = try await inspect(url)
        XCTAssertEqual(info.size, CGSize(width: 1280, height: 800))
        XCTAssertEqual(info.seconds, 19.8, accuracy: 0.3)
    }

    func testFramesOfDifferentSizeAreFitted() async throws {
        let url = base.appendingPathComponent("fit.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        recorder.append(frame: frame(320, 240, step: 0), at: .milliseconds(0)); _ = await recorder.waitUntilReady()
        recorder.append(frame: frame(640, 360, step: 1), at: .milliseconds(200)); _ = await recorder.waitUntilReady()
        recorder.append(frame: frame(100, 400, step: 2), at: .milliseconds(400)); _ = await recorder.waitUntilReady()
        recorder.append(frame: frame(320, 240, step: 3), at: .milliseconds(600)); _ = await recorder.waitUntilReady()
        await recorder.finish()
        XCTAssertNil(recorder.errorMessage)
        let info = try await inspect(url)
        XCTAssertEqual(info.tracks, 1)
        XCTAssertEqual(info.size, CGSize(width: 320, height: 240))
        XCTAssertEqual(recorder.appendedSeconds, 0.6, accuracy: 0.01)
    }

    func testOddDimensionsAreRoundedDown() async throws {
        let url = base.appendingPathComponent("odd.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        for i in 0..<5 { recorder.append(frame: frame(321, 241, step: i), at: .milliseconds(i * 200)) }
        await recorder.finish()
        XCTAssertNil(recorder.errorMessage)
        let info = try await inspect(url)
        XCTAssertEqual(info.size, CGSize(width: 320, height: 240))
    }

    func testFittedSizeCapsTheLongerSide() {
        XCTAssertEqual(VideoRecorder.fittedSize(width: 3840, height: 2160).width, 1920)
        XCTAssertEqual(VideoRecorder.fittedSize(width: 3840, height: 2160).height, 1080)
        XCTAssertEqual(VideoRecorder.fittedSize(width: 1080, height: 2400).height, 1920)
        XCTAssertEqual(VideoRecorder.fittedSize(width: 1920, height: 1080).width, 1920)
        XCTAssertEqual(VideoRecorder.fittedSize(width: 1, height: 1).width, 2)
        let odd = VideoRecorder.fittedSize(width: 2561, height: 1441)
        XCTAssertEqual(odd.width % 2, 0)
        XCTAssertEqual(odd.height % 2, 0)
        XCTAssertLessThanOrEqual(odd.width, 1920)
    }

    func testLargeFirstFrameIsScaledDown() async throws {
        let url = base.appendingPathComponent("large.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        for i in 0..<3 { recorder.append(frame: frame(2560, 1440, step: i), at: .milliseconds(i * 200)) }
        await recorder.finish()
        XCTAssertNil(recorder.errorMessage)
        let info = try await inspect(url)
        XCTAssertEqual(info.size, CGSize(width: 1920, height: 1080))
    }

    func testStopFinalizesFile() async throws {
        let url = base.appendingPathComponent("stop.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        for i in 0..<5 { recorder.append(frame: frame(320, 240, step: i), at: .milliseconds(i * 200)); _ = await recorder.waitUntilReady() }
        await recorder.finish()
        let seconds = recorder.appendedSeconds
        await recorder.finish()
        recorder.append(frame: frame(320, 240, step: 9), at: .seconds(10))
        XCTAssertEqual(recorder.appendedSeconds, seconds)
        let info = try await inspect(url)
        XCTAssertEqual(info.tracks, 1)
        XCTAssertEqual(info.seconds, 0.8, accuracy: 0.3)
    }

    func testFramesNotLaterThanThePreviousAreDropped() async throws {
        let url = base.appendingPathComponent("order.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        recorder.append(frame: frame(320, 240, step: 0), at: .milliseconds(0)); _ = await recorder.waitUntilReady()
        recorder.append(frame: frame(320, 240, step: 1), at: .milliseconds(400)); _ = await recorder.waitUntilReady()
        recorder.append(frame: frame(320, 240, step: 2), at: .milliseconds(400)); _ = await recorder.waitUntilReady()
        recorder.append(frame: frame(320, 240, step: 3), at: .milliseconds(200)); _ = await recorder.waitUntilReady()
        await recorder.finish()
        XCTAssertEqual(recorder.appendedSeconds, 0.4, accuracy: 0.01)
        XCTAssertNil(recorder.errorMessage)
    }

    func testExistingFileIsLeftAsItIsAndTheVideoFails() async throws {
        let url = base.appendingPathComponent("existing.mp4")
        try Data("old".utf8).write(to: url)
        let recorder = VideoRecorder(url: url, fps: 5)
        XCTAssertEqual(try Data(contentsOf: url), Data("old".utf8))
        for i in 0..<3 { recorder.append(frame: frame(320, 240, step: i), at: .milliseconds(i * 200)); _ = await recorder.waitUntilReady() }
        await recorder.finish()
        XCTAssertNotNil(recorder.errorMessage)
        XCTAssertEqual(try Data(contentsOf: url), Data("old".utf8))
    }

    func testFinishWithoutAWriterLeavesAFileItDidNotWrite() async throws {
        let url = base.appendingPathComponent("other.mp4")
        try Data("another recorder's video".utf8).write(to: url)
        let recorder = VideoRecorder(url: url, fps: 5)
        await recorder.finish()
        XCTAssertEqual(recorder.errorMessage, "no frame could be recorded for the video")
        XCTAssertEqual(try Data(contentsOf: url), Data("another recorder's video".utf8))
    }

    func testRecorderReleasedWhileWritingKeepsTheFramesItWrote() async throws {
        let url = base.appendingPathComponent("released.mp4")
        do {
            let recorder = VideoRecorder(url: url, fps: 5)
            for i in 0..<15 { recorder.append(frame: frame(320, 240, step: i), at: .milliseconds(i * 200)); _ = await recorder.waitUntilReady() }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRecorderReleasedBeforeItsFirstFrameWasAppendedLeavesNoFile() async throws {
        let url = base.appendingPathComponent("released-empty.mp4")
        do {
            let recorder = VideoRecorder(url: url, fps: 5)
            recorder.failNextRenders(1)
            recorder.append(frame: frame(320, 240, step: 0), at: .milliseconds(0))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testVideoFileIsReadableByItsOwnerOnly() async throws {
        let url = base.appendingPathComponent("mode.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        for i in 0..<3 { recorder.append(frame: frame(320, 240, step: i), at: .milliseconds(i * 200)); _ = await recorder.waitUntilReady() }
        let during = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(during, 0o600)
        await recorder.finish()
        XCTAssertNil(recorder.errorMessage)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(after, 0o600)
    }

    func testFinishWithoutFramesWritesNoFile() async {
        let url = base.appendingPathComponent("none.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        await recorder.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(recorder.errorMessage, "no frame could be recorded for the video")
    }

    func testUnwritableLocationIsReported() async {
        let url = base.appendingPathComponent("missing-dir/x.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        recorder.append(frame: frame(320, 240, step: 0), at: .milliseconds(0)); _ = await recorder.waitUntilReady()
        await recorder.finish()
        XCTAssertNotNil(recorder.errorMessage)
    }

    func testWriterThatStoppedIsReportedAndLeavesNoFile() async throws {
        let dir = base.appendingPathComponent("gone")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("video.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        for i in 0..<3 { recorder.append(frame: frame(320, 240, step: i), at: .milliseconds(i * 200)); _ = await recorder.waitUntilReady() }
        recorder.stopWriterForTesting()
        await recorder.finish()
        let message = try XCTUnwrap(recorder.errorMessage)
        XCTAssertTrue(message.hasPrefix("the video could not be written: "), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testWriterFailedAfterItsFragmentsKeepsAFileThatPlays() async throws {
        let url = base.appendingPathComponent("failed-kept.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        for i in 0..<4 { recorder.append(frame: frame(320, 240, step: i), at: .milliseconds(i * 1200)); _ = await recorder.waitUntilReady() }
        recorder.failWriterForTesting("the video could not be written: test")
        await recorder.finish()
        XCTAssertEqual(recorder.errorMessage, "the video could not be written: test")
        let plays = await VideoRecorder.isPlayable(url)
        XCTAssertTrue(plays)
    }

    func testFailedWriterLeavesNoFileThatDoesNotPlay() async throws {
        let url = base.appendingPathComponent("failed-removed.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        for i in 0..<3 { recorder.append(frame: frame(320, 240, step: i), at: .milliseconds(i * 200)); _ = await recorder.waitUntilReady() }
        recorder.stopWriterForTesting()
        try Data("not a movie".utf8).write(to: url)
        await recorder.finish()
        XCTAssertNotNil(recorder.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testErrorMessageIsVisibleBeforeTheRecorderFinishes() async throws {
        let recorder = VideoRecorder(url: base.appendingPathComponent("live.mp4"), fps: 5)
        recorder.append(frame: frame(320, 240, step: 0), at: .milliseconds(0))
        XCTAssertNil(recorder.errorMessage)
        recorder.failWriterForTesting("the video could not be written: test")
        XCTAssertEqual(recorder.errorMessage, "the video could not be written: test")
        await recorder.finish()
    }

    func testFirstFrameThatCannotBeRenderedLeavesNoFile() async {
        let url = base.appendingPathComponent("unrendered.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        recorder.failNextRenders(1)
        recorder.append(frame: frame(320, 240, step: 0), at: .milliseconds(0))
        await recorder.finish()
        XCTAssertEqual(recorder.errorMessage, "no frame could be recorded for the video")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFinalFrameIsNotCountedAsDropped() async {
        let url = base.appendingPathComponent("final.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        for i in 0..<12 { recorder.append(frame: frame(1280, 800, step: i), at: .milliseconds(i * 10)) }
        let dropped = recorder.droppedFrames
        let before = recorder.appendedSeconds
        await recorder.appendFinal(frame: frame(1280, 800, step: 99), at: .seconds(5))
        XCTAssertEqual(recorder.droppedFrames, dropped)
        let after = recorder.appendedSeconds
        XCTAssertTrue(after == before || (4.8...5.0).contains(after), "appendedSeconds \(before) -> \(after)")
        await recorder.finish()
    }

    func testTheFrameReadAtTheEndIsShownForOneFrameInterval() async throws {
        let url = base.appendingPathComponent("last.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        for i in 0..<5 { recorder.append(frame: Frame(width: 320, height: 240, pixels: Data(repeating: 0x20, count: 320 * 240 * 4)), at: .milliseconds(i * 200)); _ = await recorder.waitUntilReady() }
        await recorder.appendFinal(frame: Frame(width: 320, height: 240, pixels: Data(repeating: 0xFF, count: 320 * 240 * 4)), at: .milliseconds(1000))
        await recorder.finish()
        XCTAssertNil(recorder.errorMessage)
        XCTAssertEqual(recorder.appendedSeconds, 1.0, accuracy: 0.01)
        let info = try await inspect(url)
        XCTAssertEqual(info.seconds, 1.2, accuracy: 0.01)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, shown) = try await generator.image(at: CMTime(value: 660, timescale: 600))
        XCTAssertEqual(CMTimeGetSeconds(shown), 1.0, accuracy: 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(averageGray(image)), 200)
    }

    /// The mean of the gray values of `image` drawn into 16 x 16 pixels.
    private func averageGray(_ image: CGImage) -> Double? {
        var pixels = [UInt8](repeating: 0, count: 16 * 16)
        let drawn: Bool = pixels.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let context = CGContext(data: raw.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            return true
        }
        guard drawn else { return nil }
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)
    }

    func testDurationStartsAtTheFirstAppendedFrame() async {
        let url = base.appendingPathComponent("late-start.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        recorder.failNextRenders(1)
        recorder.append(frame: frame(320, 240, step: 0), at: .milliseconds(0))
        XCTAssertEqual(recorder.appendedSeconds, 0)
        recorder.append(frame: frame(320, 240, step: 1), at: .milliseconds(1000)); _ = await recorder.waitUntilReady()
        recorder.append(frame: frame(320, 240, step: 2), at: .milliseconds(1200)); _ = await recorder.waitUntilReady()
        await recorder.finish()
        XCTAssertNil(recorder.errorMessage)
        XCTAssertEqual(recorder.appendedSeconds, 0.2, accuracy: 0.01)
    }

    func testWriterThatStopsBeforeTheSessionEndsIsReportedAndLeavesNoFile() async throws {
        let dir = base.appendingPathComponent("late-stop")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("video.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        for i in 0..<3 { recorder.append(frame: frame(320, 240, step: i), at: .milliseconds(i * 200)); _ = await recorder.waitUntilReady() }
        recorder.setBeforeEndSessionForTesting { recorder.stopWriterForTesting() }
        await recorder.finish()
        let message = try XCTUnwrap(recorder.errorMessage)
        XCTAssertTrue(message.hasPrefix("the video could not be written: "), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRecordingWithoutAReadableFrameReportsItAsAWriteError() async throws {
        let dir = base.appendingPathComponent("unreadable")
        let recording = Recording(vm: "Win", directory: dir, fps: 10, video: true, maxSeconds: 60, frames: { nil },
                                  sink: VideoRecorder(url: dir.appendingPathComponent("video.mp4"), fps: 10))
        try await recording.start()
        let summary = await recording.stop()
        XCTAssertNil(summary.video)
        XCTAssertEqual(summary.writeErrors, 1)
        XCTAssertEqual(summary.lastWriteError, "no frame could be recorded for the video")
    }

    func testFramesAppendedRightAfterTheFirstOneAreEncodedWithoutCrashing() async throws {
        for n in 0..<40 {
            let url = base.appendingPathComponent("burst-\(n).mp4")
            let recorder = VideoRecorder(url: url, fps: 5)
            for i in 0..<12 { recorder.append(frame: frame(320, 240, step: i), at: .milliseconds(i * 10)) }
            await recorder.finish()
            XCTAssertTrue(recorder.errorMessage == nil || !FileManager.default.fileExists(atPath: url.path))
            XCTAssertGreaterThanOrEqual(recorder.appendedSeconds, 0)
        }
    }

    func testRecorderDroppedWithoutFinishLeavesItsDirectoryRemovable() throws {
        let dir = base.appendingPathComponent("dropped")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let recorder = VideoRecorder(url: dir.appendingPathComponent("video.mp4"), fps: 5)
            for i in 0..<3 { recorder.append(frame: frame(320, 240, step: i), at: .milliseconds(i * 200)) }
        }
        try FileManager.default.removeItem(at: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testVideoFileTheRecordingDidNotWriteIsNeitherReportedNorRemoved() async throws {
        let dir = base.appendingPathComponent("stale")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("video.mp4")
        try Data("old video".utf8).write(to: url)
        let recording = Recording(vm: "Win", directory: dir, fps: 10, video: true, maxSeconds: 60, frames: { nil },
                                  sink: VideoRecorder(url: url, fps: 10))
        try await recording.start()
        let summary = await recording.stop()
        XCTAssertNil(summary.video)
        XCTAssertNil(summary.json["video"])
        XCTAssertEqual(try Data(contentsOf: url), Data("old video".utf8))
    }

    func testBrokenVideoIsNotReportedAsTheRecording() async throws {
        let dir = base.appendingPathComponent("broken-video")
        let url = dir.appendingPathComponent("video.mp4")
        let recorder = VideoRecorder(url: url, fps: 10)
        let counter = Counter()
        let recording = Recording(vm: "Win", directory: dir, fps: 10, video: true, maxSeconds: 60,
                                  frames: { movingFrame(320, 240, step: await counter.next()) }, sink: recorder)
        try await recording.start()
        try await Task.sleep(for: .milliseconds(400))
        recorder.stopWriterForTesting()
        let summary = await recording.stop()
        XCTAssertNil(summary.video)
        XCTAssertEqual(summary.writeErrors, 1)
        XCTAssertTrue(try XCTUnwrap(summary.lastWriteError).hasPrefix("the video could not be written: "))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNextTickKeepsTheScheduleAndSkipsMissedTicks() {
        let start = ContinuousClock.now
        let period = Duration.milliseconds(100)
        XCTAssertEqual(Recording.nextTick(after: start, now: start + .milliseconds(30), interval: period), start + .milliseconds(100))
        XCTAssertEqual(Recording.nextTick(after: start, now: start + .milliseconds(99), interval: period), start + .milliseconds(100))
        XCTAssertEqual(Recording.nextTick(after: start, now: start + .milliseconds(100), interval: period), start + .milliseconds(200))
        XCTAssertEqual(Recording.nextTick(after: start, now: start + .milliseconds(250), interval: period), start + .milliseconds(300))
        XCTAssertEqual(Recording.nextTick(after: start, now: start + .milliseconds(1040), interval: period), start + .milliseconds(1100))
    }

    func testSamplerFollowsAFixedSchedule() async throws {
        let dir = base.appendingPathComponent("schedule")
        let calls = Counter()
        let recording = Recording(vm: "Win", directory: dir, fps: 10, video: true, maxSeconds: 60, frames: {
            _ = await calls.next()
            try? await Task.sleep(for: .milliseconds(40))
            return nil
        }, sink: ProbeSink())
        try await recording.start()
        let began = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(1050))
        let window = began.duration(to: .now)
        let count = await calls.next() - 1
        _ = await recording.stop()
        let seconds = Double(window.components.seconds) + Double(window.components.attoseconds) / 1e18
        XCTAssertGreaterThanOrEqual(count, 5)
        XCTAssertLessThanOrEqual(count, Int(seconds * 10) + 2)
    }

    // MARK: through Recording

    func testRecordingProducesVideo() async throws {
        let dir = base.appendingPathComponent("rec")
        let counter = Counter()
        let recording = Recording(vm: "Win", directory: dir, fps: 10, video: true, maxSeconds: 60,
                                  frames: { movingFrame(320, 240, step: await counter.next()) },
                                  sink: VideoRecorder(url: dir.appendingPathComponent("video.mp4"), fps: 10))
        try await recording.start()
        try await Task.sleep(for: .milliseconds(1500))
        let summary = await recording.stop()
        let path = try XCTUnwrap(summary.video)
        XCTAssertEqual(path, dir.appendingPathComponent("video.mp4").path)
        let info = try await inspect(URL(fileURLWithPath: path))
        XCTAssertEqual(info.tracks, 1)
        XCTAssertEqual(info.size, CGSize(width: 320, height: 240))
        XCTAssertEqual(info.seconds, 1.5, accuracy: 0.5)
        let videoSeconds = try XCTUnwrap(summary.videoSeconds)
        XCTAssertEqual(videoSeconds, (info.seconds * 10).rounded() / 10)
        XCTAssertNotNil(summary.droppedFrames)
        XCTAssertEqual(summary.writeErrors, 0)
        XCTAssertEqual(summary.json["video"]?.stringValue, path)
        XCTAssertNotNil(summary.json["videoSeconds"]?.doubleValue)
        XCTAssertNotNil(summary.json["droppedFrames"]?.intValue)
    }

    func testRecordingWithoutVideoWritesNone() async throws {
        let dir = base.appendingPathComponent("novideo")
        let sink = ProbeSink()
        let recording = Recording(vm: "Win", directory: dir, fps: 10, video: false, maxSeconds: 60,
                                  frames: { movingFrame(64, 64, step: 0) }, sink: sink)
        try await recording.start()
        try await Task.sleep(for: .milliseconds(300))
        let summary = await recording.stop()
        XCTAssertEqual(sink.times.count, 0)
        XCTAssertNil(summary.video)
        XCTAssertNil(summary.videoSeconds)
        XCTAssertNil(summary.json["video"])
    }

    func testIdenticalFramesAreEncodedAtMostEveryTwoSeconds() async throws {
        let dir = base.appendingPathComponent("still")
        let sink = ProbeSink()
        let still = frame(64, 64, step: 0)
        let recording = Recording(vm: "Win", directory: dir, fps: 10, video: true, maxSeconds: 60, frames: { still }, sink: sink)
        try await recording.start()
        try await Task.sleep(for: .milliseconds(2600))
        _ = await recording.stop()
        let times = sink.times
        XCTAssertGreaterThanOrEqual(times.count, 3)
        XCTAssertLessThanOrEqual(times.count, 4)
        XCTAssertEqual(times, times.sorted())
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(times.last), 2.4)
    }

    func testChangingFramesAreAllEncoded() async throws {
        let dir = base.appendingPathComponent("moving")
        let sink = ProbeSink()
        let counter = Counter()
        let recording = Recording(vm: "Win", directory: dir, fps: 10, video: true, maxSeconds: 60,
                                  frames: { movingFrame(64, 64, step: await counter.next()) }, sink: sink)
        try await recording.start()
        try await Task.sleep(for: .milliseconds(1000))
        _ = await recording.stop()
        XCTAssertGreaterThanOrEqual(sink.times.count, 8)
    }

    func testUnreadableFramesAreSkipped() async throws {
        let dir = base.appendingPathComponent("skip")
        let sink = ProbeSink()
        let counter = Counter()
        let recording = Recording(vm: "Win", directory: dir, fps: 10, video: true, maxSeconds: 60,
                                  frames: {
                                      let n = await counter.next()
                                      return n % 2 == 0 ? nil : movingFrame(64, 64, step: n)
                                  }, sink: sink)
        try await recording.start()
        try await Task.sleep(for: .milliseconds(800))
        let summary = await recording.stop()
        XCTAssertGreaterThanOrEqual(sink.times.count, 2)
        XCTAssertEqual(summary.writeErrors, 0)
    }

    func testNothingIsAppendedAfterStop() async throws {
        let dir = base.appendingPathComponent("after")
        let sink = ProbeSink()
        let counter = Counter()
        let recording = Recording(vm: "Win", directory: dir, fps: 30, video: true, maxSeconds: 60,
                                  frames: { movingFrame(64, 64, step: await counter.next()) }, sink: sink)
        try await recording.start()
        try await Task.sleep(for: .milliseconds(300))
        _ = await recording.stop()
        XCTAssertTrue(sink.finishedLast)
        let count = sink.times.count
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(sink.times.count, count)
    }

    func testStopEndsWhileTheFrameSourceDoesNotAnswer() async throws {
        let dir = base.appendingPathComponent("stuck")
        let gate = Latch()
        let sink = ProbeSink()
        let wait = Recording.finalFrameWait
        Recording.finalFrameWait = .milliseconds(100)
        defer { Recording.finalFrameWait = wait }
        let recording = Recording(vm: "Win", directory: dir, fps: 10, video: true, maxSeconds: 60, frames: {
            await gate.pass()
            return nil
        }, sink: sink)
        try await recording.start()
        let asked = await eventually("the sampler asked for a frame") { await gate.arrivals >= 1 }
        XCTAssertTrue(asked)
        let stopped = await finishes("stop with a frame source that does not answer", within: .seconds(10)) { _ = await recording.stop() }
        XCTAssertTrue(stopped)
        XCTAssertTrue(sink.finishedLast)
        await gate.open()
    }

    func testVideoErrorIsReportedAsWriteError() async throws {
        let dir = base.appendingPathComponent("broken")
        let sink = ProbeSink()
        sink.message = "the video could not be written (disk full); the trace is unaffected"
        let recording = Recording(vm: "Win", directory: dir, fps: 10, video: true, maxSeconds: 60, frames: { nil }, sink: sink)
        try await recording.start()
        let summary = await recording.stop()
        XCTAssertEqual(summary.writeErrors, 1)
        XCTAssertEqual(summary.lastWriteError, sink.message)
    }
}

private actor Counter {
    private var value = 0
    func next() -> Int { value += 1; return value }
}

private final class ProbeSink: VideoSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []
    private var finishedAfterLastAppend = true
    var message: String?
    var times: [Double] { lock.withLock { recorded } }
    var finishedLast: Bool { lock.withLock { finishedAfterLastAppend } }
    var errorMessage: String? { message }
    func append(frame: Frame, at time: Duration) {
        lock.withLock {
            recorded.append(Double(time.components.seconds) + Double(time.components.attoseconds) / 1e18)
            finishedAfterLastAppend = false
        }
    }
    func finish() async { lock.withLock { finishedAfterLastAppend = true } }
}

/// A gray frame with a white square of 200 pixels that moves right as `step` grows and a band of pixel noise that differs for every `step`.
private func noisyFrame(_ width: Int, _ height: Int, step: Int) -> Frame {
    var pixels = Data(repeating: 0x40, count: width * height * 4)
    let blockX = (step * 12) % max(1, width - 200)
    var seed = UInt32(truncatingIfNeeded: step &* 2_654_435_761)
    pixels.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
        for y in height / 4..<min(height, height / 4 + 200) {
            for x in blockX * 4..<min(width, blockX + 200) * 4 { raw[y * width * 4 + x] = 255 }
        }
        for y in height * 5 / 8..<min(height, height * 5 / 8 + 200) {
            for x in 0..<min(width, 400) * 4 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                raw[y * width * 4 + x] = UInt8(truncatingIfNeeded: seed >> 24)
            }
        }
    }
    return Frame(width: width, height: height, pixels: pixels)
}

/// A gray frame with a white block that moves right as `step` grows.
private func movingFrame(_ width: Int, _ height: Int, step: Int) -> Frame {
    var pixels = Data(repeating: 0x40, count: width * height * 4)
    let blockX = (step * 12) % max(1, width - 40)
    pixels.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
        for y in height / 3..<min(height, height / 3 + 40) {
            for x in blockX..<min(width, blockX + 40) {
                let offset = (y * width + x) * 4
                raw[offset] = 255; raw[offset + 1] = 255; raw[offset + 2] = 255; raw[offset + 3] = 255
            }
        }
    }
    return Frame(width: width, height: height, pixels: pixels)
}
