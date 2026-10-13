import Foundation
import AlcoveQMP

/// How much an action op reports about what the screen did.
enum ObserveLevel: String, CaseIterable, Sendable { case none, summary, diff, image }

/// What the screen did after an action. Rectangles are guest pixels of the full frame.
struct Observation: Sendable, Equatable {
    /// Time between two frame samples.
    static let sampleInterval = Duration.milliseconds(50)
    /// Largest width of a returned image in pixels.
    static let maxImageWidth = 1280
    /// Pixels added on every side of the changed rectangle for a `diff` image.
    static let diffMargin = 16

    /// Whether the screen stopped changing before the settle timeout.
    var settled: Bool
    /// Bounding box of the tiles that differ from the frame before the action; nil when none differ.
    var changed: Frame.Rect?
    /// Share of the frame's tiles that differ from the frame before the action, 0...1.
    var changedFraction: Double
    /// Size of the settled frame.
    var width: Int, height: Int
    /// PNG of `imageRect`.
    var image: Data?
    /// The part of the frame `image` shows.
    var imageRect: Frame.Rect?
    /// Image pixels per guest pixel.
    var imageScale: Double?

    func json() -> JSON {
        var obj: [String: JSON] = ["settled": .bool(settled), "changedFraction": .double(changedFraction),
                                   "width": .int(Int64(width)), "height": .int(Int64(height))]
        if let changed { obj["changed"] = changed.json }
        if let image { obj["png"] = .string(image.base64EncodedString()) }
        if let imageRect { obj["imageRect"] = imageRect.json }
        if let imageScale { obj["imageScale"] = .double(imageScale) }
        return .object(obj)
    }
}

extension Frame.Rect {
    var json: JSON { ["x": .int(Int64(x)), "y": .int(Int64(y)), "w": .int(Int64(w)), "h": .int(Int64(h))] }
}

/// Samples frames until the settle rule holds, compares the settled frame with `before`.
///
/// The screen is settled once no tile differs between consecutive samples for `settleMs`;
/// sampling stops after `settleTimeoutMs` with `settled == false`.
func observe(_ t: VMTarget, before: Frame, level: ObserveLevel, settleMs: Int, settleTimeoutMs: Int) async throws -> Observation {
    let clock = ContinuousClock()
    let deadline = clock.now + .milliseconds(settleTimeoutMs)
    let settle = Duration.milliseconds(settleMs)
    var last = try await t.frame()
    var quietSince = clock.now
    var settled = false
    while true {
        let now = clock.now
        if now - quietSince >= settle { settled = true; break }
        if now >= deadline { break }
        try await Task.sleep(for: min(Observation.sampleInterval, deadline - now))
        let sample = try await t.frame()
        if FrameDiff.between(last, sample).changedTiles != 0 { quietSince = clock.now }
        last = sample
    }

    let diff = FrameDiff.between(before, last)
    var observation = Observation(settled: settled, changed: diff.rect, changedFraction: diff.fraction,
                                  width: last.width, height: last.height)
    var shown: Frame.Rect?
    switch level {
    case .none, .summary:
        break
    case .diff:
        if let r = diff.rect {
            let margin = Observation.diffMargin
            shown = last.clamp(Frame.Rect(x: r.x - margin, y: r.y - margin, w: r.w + 2 * margin, h: r.h + 2 * margin))
        }
    case .image:
        shown = last.bounds
    }
    if let shown {
        let cropped = shown == last.bounds ? last : last.crop(shown)
        let image = cropped.scaled(by: min(1, Double(Observation.maxImageWidth) / Double(cropped.width)))
        observation.image = image.encoded(.png)
        observation.imageRect = shown
        observation.imageScale = Double(image.width) / Double(shown.w)
    }
    return observation
}
