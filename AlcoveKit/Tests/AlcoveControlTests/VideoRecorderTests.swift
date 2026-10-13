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

    /// Gives the encoder the pause a live sampler leaves between frames.
    private func paced() async { try? await Task.sleep(for: .milliseconds(30)) }

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
        for i in 0..<15 { recorder.append(frame: frame(320, 240, step: i), at: .milliseconds(i * 200)); await paced() }
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

    func testFramesOfDifferentSizeAreFitted() async throws {
        let url = base.appendingPathComponent("fit.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        recorder.append(frame: frame(320, 240, step: 0), at: .milliseconds(0)); await paced()
        recorder.append(frame: frame(640, 360, step: 1), at: .milliseconds(200)); await paced()
        recorder.append(frame: frame(100, 400, step: 2), at: .milliseconds(400)); await paced()
        recorder.append(frame: frame(320, 240, step: 3), at: .milliseconds(600)); await paced()
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
        for i in 0..<5 { recorder.append(frame: frame(320, 240, step: i), at: .milliseconds(i * 200)); await paced() }
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
        recorder.append(frame: frame(320, 240, step: 0), at: .milliseconds(0)); await paced()
        recorder.append(frame: frame(320, 240, step: 1), at: .milliseconds(400)); await paced()
        recorder.append(frame: frame(320, 240, step: 2), at: .milliseconds(400)); await paced()
        recorder.append(frame: frame(320, 240, step: 3), at: .milliseconds(200)); await paced()
        await recorder.finish()
        XCTAssertEqual(recorder.appendedSeconds, 0.4, accuracy: 0.01)
        XCTAssertNil(recorder.errorMessage)
    }

    func testExistingFileIsReplaced() async throws {
        let url = base.appendingPathComponent("replace.mp4")
        try Data("old".utf8).write(to: url)
        let recorder = VideoRecorder(url: url, fps: 5)
        for i in 0..<3 { recorder.append(frame: frame(320, 240, step: i), at: .milliseconds(i * 200)) }
        await recorder.finish()
        let info = try await inspect(url)
        XCTAssertEqual(info.tracks, 1)
    }

    func testFinishWithoutFramesWritesNoFile() async {
        let url = base.appendingPathComponent("none.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        await recorder.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(recorder.errorMessage)
    }

    func testUnwritableLocationIsReported() async {
        let url = base.appendingPathComponent("missing-dir/x.mp4")
        let recorder = VideoRecorder(url: url, fps: 5)
        recorder.append(frame: frame(320, 240, step: 0), at: .milliseconds(0)); await paced()
        await recorder.finish()
        XCTAssertNotNil(recorder.errorMessage)
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
        XCTAssertEqual(videoSeconds, 1.5, accuracy: 0.5)
        XCTAssertEqual(summary.droppedFrames, 0)
        XCTAssertEqual(summary.writeErrors, 0)
        XCTAssertEqual(summary.json["video"]?.stringValue, path)
        XCTAssertNotNil(summary.json["videoSeconds"]?.doubleValue)
        XCTAssertEqual(summary.json["droppedFrames"]?.intValue, 0)
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

/// A gray frame with a white block that moves right as `step` grows.
private func movingFrame(_ width: Int, _ height: Int, step: Int) -> Frame {
    var pixels = Data(repeating: 0x40, count: width * height * 4)
    let blockX = (step * 12) % max(1, width - 40)
    pixels.withUnsafeMutableBytes { raw in
        for y in height / 3..<min(height, height / 3 + 40) {
            for x in blockX..<min(width, blockX + 40) {
                let offset = (y * width + x) * 4
                raw[offset] = 255; raw[offset + 1] = 255; raw[offset + 2] = 255; raw[offset + 3] = 255
            }
        }
    }
    return Frame(width: width, height: height, pixels: pixels)
}
