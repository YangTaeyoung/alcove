import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// One guest frame: tightly packed BGRA pixels, `width * 4` bytes per row.
public struct Frame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: Data

    public init(width: Int, height: Int, pixels: Data) {
        precondition(width > 0 && height > 0 && pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Decodes PNG (or any ImageIO-readable) data; the alpha byte of every pixel is set to 255.
    public init?(png: Data) {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0,
              let frame = Frame.render(image, width: image.width, height: image.height, quality: .none) else { return nil }
        self = frame
    }

    public struct Rect: Sendable, Equatable {
        public var x: Int, y: Int, w: Int, h: Int
        public init(x: Int, y: Int, w: Int, h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }
    }

    public var bounds: Rect { Rect(x: 0, y: 0, w: width, h: height) }

    /// Intersection with the frame; nil when empty.
    public func clamp(_ r: Rect) -> Rect? {
        let x0 = max(r.x, 0), y0 = max(r.y, 0)
        let x1 = min(r.x + r.w, width), y1 = min(r.y + r.h, height)
        guard x1 > x0, y1 > y0 else { return nil }
        return Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    /// The pixels inside `r`, which must lie inside the frame.
    public func crop(_ r: Rect) -> Frame {
        precondition(r.w > 0 && r.h > 0 && r.x >= 0 && r.y >= 0 && r.x + r.w <= width && r.y + r.h <= height)
        var out = Data(count: r.w * r.h * 4)
        pixels.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                for row in 0..<r.h {
                    let from = ((r.y + row) * width + r.x) * 4
                    memcpy(dst.baseAddress! + row * r.w * 4, src.baseAddress! + from, r.w * 4)
                }
            }
        }
        return Frame(width: r.w, height: r.h, pixels: out)
    }

    /// The frame resampled to `factor` of its size (0 < factor <= 1), at least 1x1.
    public func scaled(by factor: Double) -> Frame {
        if factor >= 1 { return self }
        let w = max(1, Int((Double(width) * factor).rounded()))
        let h = max(1, Int((Double(height) * factor).rounded()))
        guard let image = cgImage(), let out = Frame.render(image, width: w, height: h, quality: .high) else { return self }
        return out
    }

    public enum Format: String, Sendable { case png, jpeg }

    /// PNG or JPEG bytes of the frame; `quality` (0...1) applies to JPEG.
    public func encoded(_ format: Format, quality: Double = 0.8) -> Data {
        guard let image = cgImage() else { return Data() }
        let data = NSMutableData()
        let type = format == .png ? UTType.png : UTType.jpeg
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return Data() }
        let options: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return Data() }
        return data as Data
    }

    private static let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    private func cgImage() -> CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: Frame.bitmapInfo),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func render(_ image: CGImage, width: Int, height: Int, quality: CGInterpolationQuality) -> Frame? {
        var data = Data(count: width * height * 4)
        let ok: Bool = data.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo) else { return false }
            ctx.interpolationQuality = quality
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        for i in stride(from: 3, to: data.count, by: 4) { data[i] = 255 }
        return Frame(width: width, height: height, pixels: data)
    }
}
