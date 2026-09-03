// make-icons.swift — every image asset Alcove ships, drawn with CoreGraphics.
//
// The mark is the alcove itself: a recessed arch with a flat floor and a semicircular head,
// carved into a cool indigo face and lit warm from within, with an inner shadow along the
// top-left reveal and a lamp-glow pooling on the floor, so the opening reads as real depth
// rather than paint. A dark slab stands upright in that light like a machine in the nook.
//
//   swift scripts/make-icons.swift            # writes into the repo
//   swift scripts/make-icons.swift <outdir>   # writes elsewhere
//
// Outputs: the app icon set (Alcove/Resources/Assets.xcassets/AppIcon.appiconset) and the
// README artwork (docs/assets/icon.png, logo.png, banner-dark.png, banner-light.png).

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Colour helpers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// 0xRRGGBB in sRGB, with optional alpha.
func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return CGColor(colorSpace: sRGB, components: [r, g, b, alpha])!
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB,
               colors: stops.map { $0.0 } as CFArray,
               locations: stops.map { $0.1 })!
}

// MARK: - Palette

enum Palette {
    // Cool exterior: deep indigo graphite.
    static let shellTop      = srgb(0x363D5D)
    static let shellMid      = srgb(0x212639)
    static let shellBottom   = srgb(0x131622)
    static let shellSheen    = srgb(0x7A85B8)   // faint top-edge sheen on the plate
    static let plateShadow   = srgb(0x000000)

    // Warm interior: amber into cream.
    static let nicheHead     = srgb(0xB85E19)   // dim warm at the arch head
    static let nicheMid      = srgb(0xE8952E)
    static let nicheFloor    = srgb(0xFFE3AE)
    static let lampCore      = srgb(0xFFF6E0)   // hot pool on the recess floor
    static let bloom         = srgb(0xFFC178)   // volumetric haze over the floor
    static let spill         = srgb(0xFF9E45)   // light spilling onto the face around the opening

    // Recess walls.
    static let revealShadow  = srgb(0x210B02)   // directional inner shadow, top-left
    static let seatShadow    = srgb(0x2B0F02)   // ambient inner shadow all round

    // The object standing in the niche.
    static let slabTop       = srgb(0x2C3149)
    static let slabBottom    = srgb(0x141723)
    static let slabAO        = srgb(0x3A1400)
}

// MARK: - Geometry (all in a top-down 1024 x 1024 space)

enum Geo {
    static let canvas: CGFloat = 1024
    static let margin: CGFloat = 100
    static let plate = CGRect(x: margin, y: margin,
                              width: canvas - 2 * margin, height: canvas - 2 * margin)

    /// Bounding box of the recessed arch: semicircular head, straight jambs, flat floor.
    static let arch = CGRect(x: 308, y: 292, width: 408, height: 472)

    /// The slab standing on the recess floor; its top meets the arch's spring line.
    static let slab = CGRect(x: 452, y: 478, width: 120, height: 238)
    static let slabCorner: CGFloat = 26
}

/// Superellipse |x/a|^n + |y/b|^n = 1 — the Big Sur "squircle" family. At n = 5 the corner
/// turn is visually equivalent to a ~22.5% corner radius while the edges stay near-straight.
func squirclePath(in rect: CGRect, exponent n: CGFloat = 5.0, samples: Int = 720) -> CGPath {
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let e = Double(2 / n)
    let path = CGMutablePath()
    for i in 0..<samples {
        let t = 2 * Double.pi * Double(i) / Double(samples)
        let ct = cos(t), st = sin(t)
        let x = cx + a * CGFloat(pow(abs(ct), e) * (ct < 0 ? -1 : 1))
        let y = cy + b * CGFloat(pow(abs(st), e) * (st < 0 ? -1 : 1))
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// Arch opening: flat bottom, straight sides, semicircular top. Top-down coordinates, so the
/// half-turn from pi to 2pi (increasing angle) sweeps *above* the spring line on screen.
func archPath(in rect: CGRect) -> CGPath {
    let r = rect.width / 2
    let spring = rect.minY + r
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: spring))
    path.addArc(center: CGPoint(x: rect.midX, y: spring), radius: r,
                startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.closeSubpath()
    return path
}

/// A path covering everything outside `hole`, for inner-shadow casting (filled even-odd).
func inverse(of hole: CGPath) -> CGPath {
    let path = CGMutablePath()
    path.addRect(CGRect(x: -Geo.canvas, y: -Geo.canvas, width: 3 * Geo.canvas, height: 3 * Geo.canvas))
    path.addPath(hole)
    return path
}

// MARK: - Icon elements

/// The icon's own soft drop shadow, living in the 100px margin under the plate.
func drawPlateShadow(_ ctx: CGContext, plate: CGPath) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 34, color: srgb(0x000000, 0.38))
    ctx.setFillColor(Palette.shellBottom)
    ctx.addPath(plate)
    ctx.fillPath()
    ctx.restoreGState()
}

/// Cool top-to-bottom body gradient of the icon face.
func drawShell(_ ctx: CGContext) {
    let g = gradient([(Palette.shellTop, 0), (Palette.shellMid, 0.55), (Palette.shellBottom, 1)])
    ctx.drawLinearGradient(g,
                           start: CGPoint(x: 0, y: Geo.plate.minY),
                           end: CGPoint(x: 0, y: Geo.plate.maxY),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// Faint sheen along the plate's top edge so the face reads as a solid slab, not flat paint.
func drawTopSheen(_ ctx: CGContext) {
    let g = gradient([(Palette.shellSheen.copy(alpha: 0.32)!, 0), (Palette.shellSheen.copy(alpha: 0)!, 1)])
    ctx.drawLinearGradient(g,
                           start: CGPoint(x: 0, y: Geo.plate.minY),
                           end: CGPoint(x: 0, y: Geo.plate.minY + 150),
                           options: [])
}

/// Warm light escaping the niche and washing the face around the opening.
func drawLightSpill(_ ctx: CGContext, plate: CGPath, arch: CGPath) {
    ctx.saveGState()
    let outside = CGMutablePath()
    outside.addPath(plate)
    outside.addPath(arch)
    ctx.addPath(outside)
    ctx.clip(using: .evenOdd)
    let g = gradient([(Palette.spill.copy(alpha: 0.14)!, 0),
                      (Palette.spill.copy(alpha: 0.13)!, 0.30),
                      (Palette.spill.copy(alpha: 0.05)!, 0.58),
                      (Palette.spill.copy(alpha: 0)!, 1)])
    let c = CGPoint(x: Geo.arch.midX, y: Geo.arch.maxY - 60)
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: 430, options: [])
    ctx.restoreGState()
}

/// The lit interior: warm vertical gradient plus a lamp pooling on the floor of the recess.
func drawNicheInterior(_ ctx: CGContext, arch: CGPath) {
    ctx.saveGState()
    ctx.addPath(arch)
    ctx.clip()

    let body = gradient([(Palette.nicheHead, 0), (Palette.nicheMid, 0.52), (Palette.nicheFloor, 1)])
    ctx.drawLinearGradient(body,
                           start: CGPoint(x: 0, y: Geo.arch.minY),
                           end: CGPoint(x: 0, y: Geo.arch.maxY),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    let pool = gradient([(Palette.lampCore.copy(alpha: 0.95)!, 0),
                         (Palette.nicheFloor.copy(alpha: 0.55)!, 0.45),
                         (Palette.nicheFloor.copy(alpha: 0)!, 1)])
    let c = CGPoint(x: Geo.arch.midX, y: Geo.arch.maxY - 2)
    ctx.drawRadialGradient(pool, startCenter: c, startRadius: 0, endCenter: c, endRadius: 285, options: [])
    ctx.restoreGState()
}

/// Depth: a directional inner shadow cast by the reveal along the top-left, plus an ambient
/// contact shadow seating the opening all the way round.
func drawInnerShadow(_ ctx: CGContext, arch: CGPath) {
    ctx.saveGState()
    ctx.addPath(arch)
    ctx.clip()
    let outside = inverse(of: arch)
    ctx.setFillColor(srgb(0x000000))

    ctx.setShadow(offset: CGSize(width: 28, height: 32), blur: 44, color: Palette.revealShadow.copy(alpha: 0.85)!)
    ctx.addPath(outside)
    ctx.fillPath(using: .evenOdd)

    ctx.setShadow(offset: .zero, blur: 20, color: Palette.seatShadow.copy(alpha: 0.6)!)
    ctx.addPath(outside)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
}

/// The object standing in the niche: an upright slab, silhouetted against the light.
func drawSlab(_ ctx: CGContext, arch: CGPath) {
    ctx.saveGState()
    ctx.addPath(arch)
    ctx.clip()

    let slab = CGPath(roundedRect: Geo.slab,
                      cornerWidth: Geo.slabCorner, cornerHeight: Geo.slabCorner, transform: nil)
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 26, color: Palette.slabAO.copy(alpha: 0.55)!)
    ctx.setFillColor(Palette.slabBottom)
    ctx.addPath(slab)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    ctx.addPath(slab)
    ctx.clip()
    let g = gradient([(Palette.slabTop, 0), (Palette.slabBottom, 1)])
    ctx.drawLinearGradient(g,
                           start: CGPoint(x: 0, y: Geo.slab.minY),
                           end: CGPoint(x: 0, y: Geo.slab.maxY),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

/// Haze in front of the lamp so the light feels like it fills the recess.
func drawBloom(_ ctx: CGContext, arch: CGPath) {
    ctx.saveGState()
    ctx.addPath(arch)
    ctx.clip()
    let g = gradient([(Palette.lampCore.copy(alpha: 0.22)!, 0),
                      (Palette.bloom.copy(alpha: 0.08)!, 0.5),
                      (Palette.bloom.copy(alpha: 0)!, 1)])
    let c = CGPoint(x: Geo.arch.midX, y: Geo.arch.maxY - 16)
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: 260, options: [])
    ctx.restoreGState()
}

/// A crisp bright rim just inside the opening. Without it the warm interior bleeds into the
/// face at 32 px and the arch loses its outline.
func drawArchRim(_ ctx: CGContext, arch: CGPath) {
    ctx.saveGState()
    ctx.addPath(arch)
    ctx.clip()
    ctx.setStrokeColor(Palette.nicheFloor.copy(alpha: 0.55)!)
    ctx.setLineWidth(14)
    ctx.addPath(arch)
    ctx.strokePath()
    ctx.restoreGState()
}

func drawIcon(in ctx: CGContext) {
    let plate = squirclePath(in: Geo.plate)
    let arch = archPath(in: Geo.arch)

    drawPlateShadow(ctx, plate: plate)

    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    drawShell(ctx)
    drawTopSheen(ctx)
    drawLightSpill(ctx, plate: plate, arch: arch)
    drawNicheInterior(ctx, arch: arch)
    drawInnerShadow(ctx, arch: arch)
    drawArchRim(ctx, arch: arch)
    drawSlab(ctx, arch: arch)
    drawBloom(ctx, arch: arch)
    ctx.restoreGState()
}

// MARK: - Rendering

func makeContext(width: Int, height: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                  | CGBitmapInfo.byteOrder32Big.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

/// Renders the icon at `px`, supersampled and box-filtered down so small sizes stay clean.
func renderIcon(px: Int) -> CGImage {
    let scale = px >= 512 ? 2 : 4
    let side = px * scale
    let ctx = makeContext(width: side, height: side)
    ctx.translateBy(x: 0, y: CGFloat(side))                       // flip to top-down user space
    ctx.scaleBy(x: CGFloat(side) / Geo.canvas, y: -CGFloat(side) / Geo.canvas)
    drawIcon(in: ctx)
    let big = ctx.makeImage()!

    let out = makeContext(width: px, height: px)
    out.draw(big, in: CGRect(x: 0, y: 0, width: px, height: px))
    return out.makeImage()!
}

/// Contact sheet: 1024 on the left, then 256/128/64/32/16 in a row at true pixel size.
func renderContactSheet(_ images: [(px: Int, image: CGImage)]) -> CGImage {
    let pad = 60, gutter = 80, gap = 48
    let hero = images.first { $0.px == 1024 }!
    let row = images.filter { $0.px < 1024 }.sorted { $0.px > $1.px }
    let rowWidth = row.reduce(0) { $0 + $1.px } + gap * (row.count - 1)
    let width = pad + 1024 + gutter + rowWidth + pad
    let height = pad + 1024 + pad

    let ctx = makeContext(width: width, height: height)
    ctx.setFillColor(srgb(0x1C1C1E))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // y-up device space: `top` is converted per placement, nothing is ever scaled up.
    ctx.draw(hero.image, in: CGRect(x: pad, y: height - pad - 1024, width: 1024, height: 1024))

    var x = pad + 1024 + gutter
    for item in row {
        let y = (height - item.px) / 2
        ctx.draw(item.image, in: CGRect(x: x, y: y, width: item.px, height: item.px))
        x += item.px + gap
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("cannot create PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

// MARK: - The mark on its own, and the README banner

/// The arch mark with no plate, on transparency: used as the README logo.
func drawMark(in ctx: CGContext) {
    let arch = archPath(in: Geo.arch)
    ctx.saveGState()

    // A soft warm halo so the mark survives on both light and dark backgrounds.
    ctx.setShadow(offset: .zero, blur: 46, color: Palette.spill.copy(alpha: 0.45)!)
    ctx.setFillColor(Palette.nicheMid)
    ctx.addPath(arch)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    drawNicheInterior(ctx, arch: arch)
    drawInnerShadow(ctx, arch: arch)
    drawArchRim(ctx, arch: arch)
    drawSlab(ctx, arch: arch)
    drawBloom(ctx, arch: arch)

    // A thin cool jamb around the opening, standing in for the icon's face.
    ctx.setStrokeColor(Palette.shellTop.copy(alpha: 0.9)!)
    ctx.setLineWidth(26)
    ctx.addPath(arch)
    ctx.strokePath()
    ctx.restoreGState()
}

/// Renders `text` centred on `origin`'s baseline in the system font.
func draw(text: String, size: CGFloat, weight: CGFloat, color: CGColor, at origin: CGPoint,
          tracking: CGFloat = 0, in ctx: CGContext) {
    let descriptor = CTFontDescriptorCreateWithAttributes([
        kCTFontFamilyNameAttribute: "SF Pro Display",
        kCTFontTraitsAttribute: [kCTFontWeightTrait: weight],
    ] as CFDictionary)
    let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
    let attributed = NSAttributedString(string: text, attributes: [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key: color,
        kCTKernAttributeName as NSAttributedString.Key: tracking,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    ctx.textPosition = origin
    CTLineDraw(line, ctx)
}

/// Width of a rendered string, so the banner can lay itself out.
func width(of text: String, size: CGFloat, weight: CGFloat, tracking: CGFloat = 0) -> CGFloat {
    let descriptor = CTFontDescriptorCreateWithAttributes([
        kCTFontFamilyNameAttribute: "SF Pro Display",
        kCTFontTraitsAttribute: [kCTFontWeightTrait: weight],
    ] as CFDictionary)
    let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
    let attributed = NSAttributedString(string: text, attributes: [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTKernAttributeName as NSAttributedString.Key: tracking,
    ])
    return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil))
}

/// Wordmark banner for the README: the mark, "Alcove", and the one-line description.
func renderBanner(dark: Bool, width bannerWidth: Int = 1280, height bannerHeight: Int = 360) -> CGImage {
    let scale = 2
    let ctx = makeContext(width: bannerWidth * scale, height: bannerHeight * scale)
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

    let background = dark ? srgb(0x0D1017) : srgb(0xF6F7FB)
    let title = dark ? srgb(0xF2F4FA) : srgb(0x14161C)
    let subtitle = dark ? srgb(0x9AA3B8) : srgb(0x5A6274)

    ctx.setFillColor(background)
    ctx.fill(CGRect(x: 0, y: 0, width: bannerWidth, height: bannerHeight))

    // A wide warm glow behind the mark, as if the alcove lights the banner.
    let glow = gradient([(Palette.spill.copy(alpha: dark ? 0.20 : 0.14)!, 0),
                         (Palette.spill.copy(alpha: 0)!, 1)])
    let glowCentre = CGPoint(x: 226, y: CGFloat(bannerHeight) / 2)
    ctx.drawRadialGradient(glow, startCenter: glowCentre, startRadius: 0,
                           endCenter: glowCentre, endRadius: 260, options: [])

    // The mark, drawn in its own 1024 space and scaled into place.
    let markSide: CGFloat = 212
    ctx.saveGState()
    ctx.translateBy(x: 120, y: (CGFloat(bannerHeight) + markSide) / 2)
    ctx.scaleBy(x: markSide / Geo.canvas, y: -markSide / Geo.canvas)
    drawMark(in: ctx)
    ctx.restoreGState()

    // Wordmark and tagline. CoreText draws baseline-up, which is this context's
    // own orientation, so no flip here — only the mark above is drawn top-down.
    let textX: CGFloat = 356
    let centre = CGFloat(bannerHeight) / 2
    draw(text: "Alcove", size: 96, weight: 0.4, color: title,
         at: CGPoint(x: textX, y: centre + 10), tracking: -2, in: ctx)
    draw(text: "Windows and Linux on Apple silicon, built from the metal up.",
         size: 29, weight: 0, color: subtitle,
         at: CGPoint(x: textX + 4, y: centre - 44), in: ctx)

    return ctx.makeImage()!
}

/// The transparent mark at `px`, for the README logo.
func renderMark(px: Int) -> CGImage {
    let scale = 4
    let side = px * scale
    let ctx = makeContext(width: side, height: side)
    ctx.translateBy(x: 0, y: CGFloat(side))
    ctx.scaleBy(x: CGFloat(side) / Geo.canvas, y: -CGFloat(side) / Geo.canvas)
    drawMark(in: ctx)
    let big = ctx.makeImage()!
    let out = makeContext(width: px, height: px)
    out.draw(big, in: CGRect(x: 0, y: 0, width: px, height: px))
    return out.makeImage()!
}

// MARK: - Main

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".",
               isDirectory: true)
let iconSet = root.appendingPathComponent("Alcove/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let assets = root.appendingPathComponent("docs/assets", isDirectory: true)
for dir in [iconSet, assets] {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}

/// (file size in points, scale) pairs macOS asks for.
let appIconEntries: [(size: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

var images: [Int: CGImage] = [:]
func icon(_ px: Int) -> CGImage {
    if let image = images[px] { return image }
    let image = renderIcon(px: px)
    images[px] = image
    return image
}

var manifest: [[String: String]] = []
for entry in appIconEntries {
    let px = entry.size * entry.scale
    let name = "icon_\(entry.size)x\(entry.size)\(entry.scale == 2 ? "@2x" : "").png"
    writePNG(icon(px), to: iconSet.appendingPathComponent(name))
    manifest.append(["size": "\(entry.size)x\(entry.size)", "idempotent-scale": "\(entry.scale)x",
                     "filename": name, "idiom": "mac"])
}

// Contents.json for the asset catalogue.
let contents: [String: Any] = [
    "images": manifest.map { entry in
        ["size": entry["size"]!, "idiom": entry["idiom"]!, "filename": entry["filename"]!,
         "scale": entry["idempotent-scale"]!]
    },
    "info": ["version": 1, "author": "scripts/make-icons.swift"],
]
let contentsData = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! contentsData.write(to: iconSet.appendingPathComponent("Contents.json"))
print("wrote \(iconSet.path) (\(appIconEntries.count) images + Contents.json)")

writePNG(icon(1024), to: assets.appendingPathComponent("icon.png"))
writePNG(renderMark(px: 512), to: assets.appendingPathComponent("logo.png"))
writePNG(renderBanner(dark: true), to: assets.appendingPathComponent("banner-dark.png"))
writePNG(renderBanner(dark: false), to: assets.appendingPathComponent("banner-light.png"))
print("wrote \(assets.path)/{icon,logo,banner-dark,banner-light}.png")
