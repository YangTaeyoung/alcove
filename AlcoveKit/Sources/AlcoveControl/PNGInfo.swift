import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Small PNG helpers: header parsing and downscaling for token-friendly screenshots.
enum PNGInfo {
    /// Width and height from the IHDR chunk.
    static func size(of png: Data) -> (width: Int, height: Int)? {
        guard png.count >= 24, png[0] == 0x89, png[1] == 0x50 else { return nil }
        let w = png[16..<20].reduce(0) { ($0 << 8) | Int($1) }
        let h = png[20..<24].reduce(0) { ($0 << 8) | Int($1) }
        return (w, h)
    }

    /// A coarse fingerprint: the frame rendered at 160 px wide, RGBA bytes.
    static func thumbnail(_ png: Data, width: Int = 160) -> [UInt8]? {
        guard let (w, h) = size(of: png), w > 0, h > 0,
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let nh = max(1, Int((Double(h) * Double(width) / Double(w)).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: nh, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: nh))
        guard let base = ctx.data else { return nil }
        return Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: width * nh * 4))
    }

    /// Fraction of thumbnail pixels whose colour differs noticeably between two frames.
    static func changedFraction(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, a.count >= 4 else { return 1 }
        var changed = 0
        let pixels = a.count / 4
        for i in stride(from: 0, to: a.count, by: 4) {
            if abs(Int(a[i]) - Int(b[i])) > 24 || abs(Int(a[i + 1]) - Int(b[i + 1])) > 24 || abs(Int(a[i + 2]) - Int(b[i + 2])) > 24 {
                changed += 1
            }
        }
        return Double(changed) / Double(pixels)
    }

    /// Re-encode `png` so its width is at most `maxWidth` (aspect preserved).
    static func downscale(_ png: Data, maxWidth: Int) -> Data {
        guard let (w, h) = size(of: png), w > maxWidth, maxWidth > 0,
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return png }
        let scale = Double(maxWidth) / Double(w)
        let nw = maxWidth, nh = max(1, Int((Double(h) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return png }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let out = ctx.makeImage() else { return png }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return png }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { return png }
        return data as Data
    }
}
