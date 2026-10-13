import Foundation

/// Which 32x32 tiles of a frame differ from another frame.
public struct FrameDiff: Sendable, Equatable {
    public static let tile = 32
    /// Largest per-channel difference that still counts as unchanged.
    public static let channelThreshold = 24

    public let changedTiles: Int
    public let totalTiles: Int
    /// Bounding box of the changed tiles in guest pixels; nil when nothing changed.
    public let rect: Frame.Rect?

    public var fraction: Double { totalTiles == 0 ? 0 : Double(changedTiles) / Double(totalTiles) }

    /// Frames of different size count as fully changed.
    public static func between(_ a: Frame, _ b: Frame) -> FrameDiff {
        let cols = (b.width + tile - 1) / tile, rows = (b.height + tile - 1) / tile
        guard a.width == b.width, a.height == b.height else {
            return FrameDiff(changedTiles: cols * rows, totalTiles: cols * rows, rect: b.bounds)
        }
        var changed = 0
        var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
        a.pixels.withUnsafeBytes { pa in
            b.pixels.withUnsafeBytes { pb in
                let pa = pa.bindMemory(to: UInt8.self), pb = pb.bindMemory(to: UInt8.self)
                for ty in 0..<rows { for tx in 0..<cols {
                    let x0 = tx * tile, y0 = ty * tile
                    let x1 = min(x0 + tile, b.width), y1 = min(y0 + tile, b.height)
                    guard tileChanged(pa, pb, width: b.width, x0: x0, x1: x1, y0: y0, y1: y1) else { continue }
                    changed += 1
                    minX = min(minX, x0); minY = min(minY, y0)
                    maxX = max(maxX, x1); maxY = max(maxY, y1)
                } }
            }
        }
        let rect = changed == 0 ? nil : Frame.Rect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
        return FrameDiff(changedTiles: changed, totalTiles: cols * rows, rect: rect)
    }

    private static func tileChanged(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>,
                                    width: Int, x0: Int, x1: Int, y0: Int, y1: Int) -> Bool {
        for y in y0..<y1 {
            var o = (y * width + x0) * 4
            for _ in x0..<x1 {
                if abs(Int(a[o]) - Int(b[o])) > channelThreshold
                    || abs(Int(a[o + 1]) - Int(b[o + 1])) > channelThreshold
                    || abs(Int(a[o + 2]) - Int(b[o + 2])) > channelThreshold { return true }
                o += 4
            }
        }
        return false
    }
}
