import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo

/// Writes frames as an H.264 MP4 file in movie fragments of `fragmentInterval`: a copy of the file made while it is
/// written plays up to its last whole fragment. Frames are encoded in display order.
///
/// The output size is fixed by the first frame: rounded down to even numbers and scaled down so the longer side is at most
/// `maxLongSide`. Frames of another size are drawn aspect-fit on black.
///
/// Isolation: the AVFoundation objects and every stored property after `lock` are read and written only while `lock` is held,
/// so the class is safe to call from any thread.
final class VideoRecorder: VideoSink, @unchecked Sendable {
    static let maxLongSide = 1920
    static let timeScale: CMTimeScale = 600
    static let noFrameMessage = "no frame could be recorded for the video"
    static let fragmentInterval = CMTime(value: CMTimeValue(timeScale), timescale: timeScale)

    let url: URL
    let fps: Int

    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var width = 0
    private var height = 0
    private var firstTime = CMTime.invalid
    private var lastTime = CMTime.invalid
    private var finished = false
    private var failure: String?
    private var dropped = 0

    private var renderFailures = 0
    private var pool: CVPixelBufferPool?
    private var beforeEndSession: (@Sendable () -> Void)?

    deinit {
        if let writer, writer.status == .writing { writer.cancelWriting() }
    }

    /// Removes a file already at `url`.
    init(url: URL, fps: Int) {
        self.url = url
        self.fps = fps
        try? FileManager.default.removeItem(at: url)
    }

    /// The size of the video for a first frame of `width` x `height`.
    static func fittedSize(width: Int, height: Int) -> (width: Int, height: Int) {
        var w = Double(width), h = Double(height)
        let longer = max(w, h)
        if longer > Double(maxLongSide) {
            let scale = Double(maxLongSide) / longer
            w = (w * scale).rounded(.down)
            h = (h * scale).rounded(.down)
        }
        return (max(2, Int(w) & ~1), max(2, Int(h) & ~1))
    }

    /// Whether the file at `url` opens as a movie with a video track.
    static func isPlayable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return false }
        return ((try? await asset.loadTracks(withMediaType: .video))?.count ?? 0) > 0
    }

    /// Frames not appended because the encoder was not ready for them.
    var droppedFrames: Int { lock.withLock { dropped } }

    /// Seconds between the first and the last appended frame; the session starts at the first appended frame.
    var appendedSeconds: Double {
        lock.withLock { firstTime.isValid && lastTime.isValid ? CMTimeGetSeconds(CMTimeSubtract(lastTime, firstTime)) : 0 }
    }

    /// A sentence describing why the video could not be written; nil while it can.
    var errorMessage: String? { lock.withLock { failure } }

    /// Encodes `frame` at `time` after the start of the recording; a frame not later than the previous one is dropped.
    func append(frame: Frame, at time: Duration) {
        append(frame, at: time, countDrop: true)
    }

    /// Encodes the last frame of the recording: waits up to 500 ms for the encoder and does not count it as dropped.
    func appendFinal(frame: Frame, at time: Duration) async {
        _ = await waitUntilReady(timeout: .milliseconds(500))
        append(frame, at: time, countDrop: false)
    }

    /// Waits until the encoder accepts another frame; false when `timeout` passes first.
    func waitUntilReady(timeout: Duration = .seconds(5)) async -> Bool {
        let limit = ContinuousClock.now + timeout
        while ContinuousClock.now < limit {
            if lock.withLock({ input?.isReadyForMoreMediaData ?? true }) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// The next `count` frames fail to render.
    func failNextRenders(_ count: Int) { lock.withLock { renderFailures = count } }

    /// Cancels the underlying writer as if the encoder had stopped.
    func stopWriterForTesting() { lock.withLock { writer?.cancelWriting() } }

    /// Runs `hook` in `finish()` after the lock is released and before the session is ended.
    func setBeforeEndSessionForTesting(_ hook: (@Sendable () -> Void)?) { lock.withLock { beforeEndSession = hook } }

    private func append(_ frame: Frame, at time: Duration, countDrop: Bool) {
        lock.withLock {
            guard !finished, failure == nil else { return }
            let seconds = Double(time.components.seconds) + Double(time.components.attoseconds) / 1e18
            let presentation = CMTime(seconds: max(0, seconds), preferredTimescale: VideoRecorder.timeScale)
            if writer == nil, !open(firstFrame: frame) { return }
            guard let writer, let input, let adaptor else { return }
            if lastTime.isValid, CMTimeCompare(presentation, lastTime) <= 0 { return }
            guard writer.status == .writing else {
                failure = describe(writer.error)
                return
            }
            guard input.isReadyForMoreMediaData else {
                if countDrop { dropped += 1 }
                return
            }
            if renderFailures > 0 {
                renderFailures -= 1
                if countDrop { dropped += 1 }
                return
            }
            guard let buffer = makeBuffer(), render(frame, into: buffer) else {
                if countDrop { dropped += 1 }
                return
            }
            let startsSession = !firstTime.isValid
            if startsSession { writer.startSession(atSourceTime: presentation) }
            if adaptor.append(buffer, withPresentationTime: presentation) {
                if startsSession { firstTime = presentation }
                lastTime = presentation
            } else {
                failure = describe(writer.error)
            }
        }
    }

    /// Completes the file; later calls do nothing, and later frames are ignored. A writer that failed, or a session
    /// without an appended frame, is cancelled and its file removed; without any writer the error is that no frame could be recorded.
    func finish() async {
        let pending: (AVAssetWriter, CMTime)? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            guard let writer else {
                if failure == nil { failure = VideoRecorder.noFrameMessage }
                return nil
            }
            if failure == nil, writer.status != .writing {
                failure = describe(writer.status == .failed ? writer.error : nil)
            }
            if failure == nil, !lastTime.isValid { failure = VideoRecorder.noFrameMessage }
            if failure != nil {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            input?.markAsFinished()
            return (writer, lastTime)
        }
        guard let (writer, last) = pending else { return }
        let hook = lock.withLock { beforeEndSession }
        hook?()
        let writing = lock.withLock {
            guard writer.status == .writing else {
                failure = describe(writer.error)
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                return false
            }
            return true
        }
        guard writing else { return }
        writer.endSession(atSourceTime: last)
        await writer.finishWriting()
        lock.withLock {
            if writer.status == .failed, failure == nil {
                failure = describe(writer.error)
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // Callers hold `lock`.
    private func open(firstFrame frame: Frame) -> Bool {
        let size = VideoRecorder.fittedSize(width: frame.width, height: frame.height)
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            writer.movieTimeScale = VideoRecorder.timeScale
            writer.movieFragmentInterval = VideoRecorder.fragmentInterval
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoExpectedSourceFrameRateKey: fps,
                    AVVideoAverageBitRateKey: max(500_000, size.width * size.height * 2),
                    AVVideoMaxKeyFrameIntervalDurationKey: 2,
                    AVVideoAllowFrameReorderingKey: false,
                ] as [String: Any],
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
            ])
            guard writer.canAdd(input) else {
                failure = "the video encoder does not accept the screen size \(size.width)x\(size.height)"
                return false
            }
            var newPool: CVPixelBufferPool?
            let poolStatus = CVPixelBufferPoolCreate(nil, nil, [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ] as CFDictionary, &newPool)
            guard poolStatus == kCVReturnSuccess, let newPool else {
                failure = "the video could not be written: the pixel buffer pool could not be created"
                return false
            }
            writer.add(input)
            guard writer.startWriting() else {
                failure = describe(writer.error)
                return false
            }
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            pool = newPool
            width = size.width
            height = size.height
            return true
        } catch {
            failure = describe(error)
            return false
        }
    }

    private func describe(_ error: Error?) -> String {
        "the video could not be written: \(error?.localizedDescription ?? "the encoder stopped before the recording ended")"
    }

    /// Buffers come from a pool this recorder owns.
    private func makeBuffer() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    private func render(_ frame: Frame, into buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        if frame.width == width, frame.height == height {
            frame.pixels.withUnsafeBytes { source in
                for row in 0..<height {
                    memcpy(base + row * stride, source.baseAddress! + row * width * 4, width * 4)
                }
            }
            return true
        }
        guard let image = frame.cgImage(),
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return false }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(Double(width) / Double(frame.width), Double(height) / Double(frame.height))
        let w = Double(frame.width) * scale, h = Double(frame.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
        return true
    }
}
