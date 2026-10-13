import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// One guest frame: tightly packed BGRA pixels, `width * 4` bytes per row.
public struct Frame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: Data

    /// Largest width or height accepted when decoding an image.
    public static let maxDimension = 16384

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
              (1...Frame.maxDimension).contains(image.width), (1...Frame.maxDimension).contains(image.height),
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

    /// A numbered rectangle to draw over the frame.
    public struct Mark: Sendable, Equatable {
        public var number: Int
        public var rect: Rect
        public init(number: Int, rect: Rect) { self.number = number; self.rect = rect }
    }

    /// The outline colours of marks; mark `n` uses entry `(n - 1) % count`.
    static let markColors: [(red: UInt8, green: UInt8, blue: UInt8)] = [
        (230, 0, 92), (0, 122, 255), (0, 153, 68), (255, 128, 0), (153, 51, 204), (0, 163, 163),
    ]

    /// The widths in pixels a mark's outline can have.
    static let markLineWidth = 1.0...8.0
    /// The sizes in pixels the text of a mark's tag can have.
    static let markTextSize = 9.0...32.0

    /// The frame with each mark drawn as an outlined rectangle and its number in a filled tag: above the
    /// rectangle's top-left corner, or inside that corner when the tag does not fit above, and moved sideways
    /// into the frame when it would reach past an edge. A rectangle too thin for an outline is filled; one without
    /// an area is not drawn. `scale` multiplies the outline width (2 pixels) and the tag's text size (13 pixels); the
    /// outline stays between 1 and 8 pixels wide and the text between 9 and 32 pixels high, whatever `scale` is.
    /// Parts of a rectangle outside the frame are cut off.
    public func drawingMarks(_ marks: [Mark], scale: Double = 1) -> Frame {
        guard !marks.isEmpty else { return self }
        let factor = scale.isFinite ? scale : 1
        let line = min(max((2 * factor).rounded(), Frame.markLineWidth.lowerBound), Frame.markLineWidth.upperBound)
        let size = min(max(13 * factor, Frame.markTextSize.lowerBound), Frame.markTextSize.upperBound)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(size), nil)
        let padding = CGFloat(line)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let white = CGColor(colorSpace: space, components: [1, 1, 1, 1]) else { return self }
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: white]
        var data = pixels
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: Frame.bitmapInfo) else { return false }
            for mark in marks where mark.rect.w > 0 && mark.rect.h > 0 {
                let rgb = Frame.markColors[((mark.number - 1) % Frame.markColors.count + Frame.markColors.count) % Frame.markColors.count]
                guard let color = CGColor(colorSpace: space, components: [CGFloat(rgb.red) / 255, CGFloat(rgb.green) / 255, CGFloat(rgb.blue) / 255, 1]) else { continue }
                let box = CGRect(x: CGFloat(mark.rect.x), y: CGFloat(height - mark.rect.y - mark.rect.h),
                                 width: CGFloat(mark.rect.w), height: CGFloat(mark.rect.h))
                ctx.setShouldAntialias(false)
                ctx.setFillColor(color)
                if box.width <= 2 * CGFloat(line) || box.height <= 2 * CGFloat(line) {
                    ctx.fill(box)
                } else {
                    ctx.setStrokeColor(color)
                    ctx.setLineWidth(CGFloat(line))
                    ctx.stroke(box.insetBy(dx: CGFloat(line) / 2, dy: CGFloat(line) / 2))
                }

                guard let text = CFAttributedStringCreate(nil, "\(mark.number)" as CFString, attributes as CFDictionary) else { continue }
                let label = CTLineCreateWithAttributedString(text)
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                let textWidth = CGFloat(CTLineGetTypographicBounds(label, &ascent, &descent, &leading))
                let tagWidth = (textWidth + 2 * padding).rounded(.up), tagHeight = (ascent + descent + 2 * padding).rounded(.up)
                var tag = CGRect(x: box.minX, y: box.maxY, width: tagWidth, height: tagHeight)
                if tag.maxY > CGFloat(height) {
                    tag.origin = CGPoint(x: box.minX + CGFloat(line), y: box.maxY - CGFloat(line) - tagHeight)
                }
                tag.origin.x = max(0, min(tag.origin.x, CGFloat(width) - tagWidth))
                tag.origin.y = max(0, min(tag.origin.y, CGFloat(height) - tagHeight))
                ctx.fill(tag)
                ctx.setShouldAntialias(true)
                ctx.textPosition = CGPoint(x: tag.minX + padding, y: tag.minY + padding + descent)
                CTLineDraw(label, ctx)
            }
            for i in stride(from: 3, to: buffer.count, by: 4) { buffer[i] = 255 }
            return true
        }
        guard drawn else { return self }
        return Frame(width: width, height: height, pixels: data)
    }

    private static let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    func cgImage() -> CGImage? {
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
