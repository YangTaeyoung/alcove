import AlcoveDisplayProtocol
import Metal
import MetalKit

/// Draws a guest framebuffer (and an optional hardware cursor overlay) into an
/// `MTKView` with Metal.
///
/// The renderer owns one `.bgra8Unorm` texture sized to the current guest
/// surface. Dirty rectangles are copied from the shared framebuffer into that
/// texture with `replace(region:...)`, and the texture is drawn aspect-fit
/// (letterboxed on a dark background) with linear filtering. The cursor is a
/// second, small texture composited with straight-alpha blending at the
/// position the guest last reported through `FromQEMU.MousePosition`.
///
/// The shader is compiled from source at runtime so the app target needs no
/// `.metal` file or extra build phase.
@MainActor
final class MetalRenderer {
    enum RendererError: Error, CustomStringConvertible {
        case noMetalDevice
        case noCommandQueue
        case shaderCompilation(String)
        case missingFunction(String)
        case pipelineCreation(String)

        var description: String {
            switch self {
            case .noMetalDevice: return "No Metal-capable GPU is available"
            case .noCommandQueue: return "Could not create a Metal command queue"
            case .shaderCompilation(let m): return "Display shader failed to compile: \(m)"
            case .missingFunction(let n): return "Display shader is missing function \(n)"
            case .pipelineCreation(let m): return "Could not create the display pipeline: \(m)"
            }
        }
    }

    /// The pixel format every `MTKView` driven by this renderer must use.
    static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm
    /// Background behind the letterboxed guest surface.
    static let clearColor = MTLClearColor(red: 0.078, green: 0.078, blue: 0.086, alpha: 1)

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let opaquePipeline: MTLRenderPipelineState
    private let blendPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    private var surfaceTexture: MTLTexture?
    private var surface: SharedFramebuffer?
    private var geometry: FromQEMU.SurfaceSwitch?
    private var dirtyRect: (x0: Int, y0: Int, x1: Int, y1: Int)?

    private var cursorTexture: MTLTexture?
    private var cursorHotspot = (x: 0, y: 0)
    private var cursorPosition = (x: 0, y: 0)
    private var cursorVisible = false

    /// Size of the current guest surface in pixels, or `.zero` when none.
    var surfaceSize: CGSize {
        guard let geometry else { return .zero }
        return CGSize(width: geometry.w, height: geometry.h)
    }

    /// Whether a guest surface is currently mapped and drawable.
    var hasSurface: Bool { surfaceTexture != nil }

    /// Whether the guest has defined a hardware cursor image.
    var hasCursorImage: Bool { cursorTexture != nil }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RendererError.noMetalDevice }
        guard let queue = device.makeCommandQueue() else { throw RendererError.noCommandQueue }
        self.device = device
        self.commandQueue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: MetalRenderer.shaderSource, options: nil)
        } catch {
            throw RendererError.shaderCompilation(error.localizedDescription)
        }
        guard let vertexFunction = library.makeFunction(name: "alcove_vertex") else {
            throw RendererError.missingFunction("alcove_vertex")
        }
        guard let opaqueFragment = library.makeFunction(name: "alcove_fragment_opaque") else {
            throw RendererError.missingFunction("alcove_fragment_opaque")
        }
        guard let blendFragment = library.makeFunction(name: "alcove_fragment_blend") else {
            throw RendererError.missingFunction("alcove_fragment_blend")
        }

        func makePipeline(fragment: MTLFunction, blending: Bool, label: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = label
            d.vertexFunction = vertexFunction
            d.fragmentFunction = fragment
            guard let attachment = d.colorAttachments[0] else { throw RendererError.pipelineCreation("no color attachment") }
            attachment.pixelFormat = MetalRenderer.colorPixelFormat
            if blending {
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            do {
                return try device.makeRenderPipelineState(descriptor: d)
            } catch {
                throw RendererError.pipelineCreation(error.localizedDescription)
            }
        }
        opaquePipeline = try makePipeline(fragment: opaqueFragment, blending: false, label: "alcove.surface")
        blendPipeline = try makePipeline(fragment: blendFragment, blending: true, label: "alcove.cursor")

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw RendererError.pipelineCreation("sampler state")
        }
        self.sampler = sampler
    }

    // MARK: - Surface

    /// Adopt a new guest surface: allocate a texture matching `geometry` and
    /// copy the whole framebuffer into it. `geometry.isValid` must hold.
    func apply(surface: SharedFramebuffer, geometry: FromQEMU.SurfaceSwitch) {
        guard geometry.isValid, surface.size >= geometry.stride * geometry.h else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalRenderer.colorPixelFormat, width: geometry.w, height: geometry.h, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }
        texture.label = "alcove.surface \(geometry.w)x\(geometry.h)"
        self.surface = surface
        self.geometry = geometry
        self.surfaceTexture = texture
        self.dirtyRect = nil
        update(rect: FromQEMU.Update(con: geometry.con, x: 0, y: 0, w: geometry.w, h: geometry.h))
    }

    /// Record `rect` (surface pixel coordinates) as dirty so the next draw
    /// copies the union of pending updates from shared memory into the texture.
    /// Rectangles are clipped to the surface; empty results are ignored.
    func update(rect: FromQEMU.Update) {
        guard surfaceTexture != nil, let surface, let geometry else { return }
        let x0 = max(rect.x, 0), y0 = max(rect.y, 0)
        let x1 = min(rect.x + rect.w, geometry.w), y1 = min(rect.y + rect.h, geometry.h)
        guard x1 > x0, y1 > y0 else { return }
        let width = x1 - x0, height = y1 - y0
        let offset = y0 * geometry.stride + x0 * 4
        // The last row read ends at offset + (height-1)*stride + width*4 <= stride*h <= size.
        guard offset + (height - 1) * geometry.stride + width * 4 <= surface.size else { return }
        if let existing = dirtyRect {
            dirtyRect = (min(existing.x0, x0), min(existing.y0, y0), max(existing.x1, x1), max(existing.y1, y1))
        } else {
            dirtyRect = (x0, y0, x1, y1)
        }
    }

    /// Upload the coalesced dirty region to `surfaceTexture` right before drawing.
    private func flushDirtyRect() {
        guard let dirty = dirtyRect, let texture = surfaceTexture, let surface, let geometry else { return }
        dirtyRect = nil
        let width = dirty.x1 - dirty.x0, height = dirty.y1 - dirty.y0
        let offset = dirty.y0 * geometry.stride + dirty.x0 * 4
        guard offset + (height - 1) * geometry.stride + width * 4 <= surface.size else { return }
        let region = MTLRegionMake2D(dirty.x0, dirty.y0, width, height)
        texture.replace(region: region, mipmapLevel: 0,
                        withBytes: surface.baseAddress.advanced(by: offset),
                        bytesPerRow: geometry.stride)
    }

    /// Drop the surface and cursor (the guest display went away).
    func clear() {
        surfaceTexture = nil
        surface = nil
        geometry = nil
        dirtyRect = nil
        clearCursor()
    }

    // MARK: - Cursor overlay

    /// Adopt a new hardware cursor image (ARGB32 words, i.e. B,G,R,A bytes,
    /// straight alpha, `w * 4` bytes per row) from a shared file.
    func setCursor(image: SharedFramebuffer, define: FromQEMU.CursorDefine) {
        guard define.w > 0, define.h > 0, define.w <= 1024, define.h <= 1024,
              image.size >= define.w * define.h * 4 else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalRenderer.colorPixelFormat, width: define.w, height: define.h, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }
        texture.label = "alcove.cursor \(define.w)x\(define.h)"
        texture.replace(region: MTLRegionMake2D(0, 0, define.w, define.h), mipmapLevel: 0,
                        withBytes: image.baseAddress, bytesPerRow: define.w * 4)
        cursorTexture = texture
        cursorHotspot = (define.hx, define.hy)
    }

    /// Update the guest-reported cursor position (surface pixels) and visibility.
    /// Returns true when the cursor overlay changed and needs a redraw.
    @discardableResult
    func setMouse(_ mouse: FromQEMU.MousePosition) -> Bool {
        let changed = cursorPosition.x != mouse.x || cursorPosition.y != mouse.y || cursorVisible != mouse.on
        cursorPosition = (mouse.x, mouse.y)
        cursorVisible = mouse.on
        return changed && cursorTexture != nil
    }

    /// Forget the cursor image and hide the overlay.
    func clearCursor() {
        cursorTexture = nil
        cursorVisible = false
    }

    // MARK: - Drawing

    /// Render the current frame into `view`'s drawable. Safe to call when no
    /// surface is mapped (draws only the background).
    func draw(in view: MTKView) {
        let drawableSize = view.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        flushDirtyRect()
        commandBuffer.label = "alcove.frame"
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MetalRenderer.clearColor
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            commandBuffer.commit()
            return
        }
        encoder.label = "alcove.display"

        if let texture = surfaceTexture, let geometry {
            let surfacePixels = CGSize(width: geometry.w, height: geometry.h)
            let fit = DisplayGeometry.aspectFitRect(surface: surfacePixels, in: drawableSize).integral
            encodeQuad(encoder, pipeline: opaquePipeline, texture: texture, rect: fit, drawableSize: drawableSize)

            if cursorVisible, let cursor = cursorTexture, fit.width > 0, fit.height > 0 {
                let scale = fit.width / surfacePixels.width
                let origin = CGPoint(x: fit.minX + CGFloat(cursorPosition.x - cursorHotspot.x) * scale,
                                     y: fit.minY + CGFloat(cursorPosition.y - cursorHotspot.y) * scale)
                let size = CGSize(width: CGFloat(cursor.width) * scale, height: CGFloat(cursor.height) * scale)
                let cursorRect = CGRect(origin: origin, size: size)
                if cursorRect.intersects(CGRect(origin: .zero, size: drawableSize)) {
                    encodeQuad(encoder, pipeline: blendPipeline, texture: cursor, rect: cursorRect, drawableSize: drawableSize)
                }
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// One textured quad. `rect` is in drawable pixels with a top-left origin.
    private func encodeQuad(_ encoder: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState,
                            texture: MTLTexture, rect: CGRect, drawableSize: CGSize) {
        // Pixel rect (y down) -> normalized device coordinates (y up).
        let left = Float(rect.minX / drawableSize.width * 2 - 1)
        let right = Float(rect.maxX / drawableSize.width * 2 - 1)
        let top = Float(1 - rect.minY / drawableSize.height * 2)
        let bottom = Float(1 - rect.maxY / drawableSize.height * 2)
        // Texture coordinates: (0,0) is the first byte row (top-left of the guest surface).
        let vertices: [Float] = [
            left, top, 0, 0,
            left, bottom, 0, 1,
            right, top, 1, 0,
            right, top, 1, 0,
            left, bottom, 0, 1,
            right, bottom, 1, 1,
        ]
        encoder.setRenderPipelineState(pipeline)
        vertices.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress {
                encoder.setVertexBytes(base, length: buffer.count, index: 0)
            }
        }
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    // MARK: - Shader

    /// Vertex and fragment functions, compiled at runtime.
    ///
    /// The framebuffer's alpha byte is undefined (QEMU uses `x8r8g8b8`), so the
    /// opaque variant forces alpha to 1. The cursor variant passes the straight
    /// alpha through for the blend stage.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float2 position;
        float2 texCoord;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    vertex VertexOut alcove_vertex(uint vid [[vertex_id]],
                                   constant VertexIn *vertices [[buffer(0)]]) {
        VertexOut out;
        out.position = float4(vertices[vid].position, 0.0, 1.0);
        out.texCoord = vertices[vid].texCoord;
        return out;
    }

    fragment float4 alcove_fragment_opaque(VertexOut in [[stage_in]],
                                           texture2d<float> tex [[texture(0)]],
                                           sampler s [[sampler(0)]]) {
        float4 c = tex.sample(s, in.texCoord);
        return float4(c.rgb, 1.0);
    }

    fragment float4 alcove_fragment_blend(VertexOut in [[stage_in]],
                                          texture2d<float> tex [[texture(0)]],
                                          sampler s [[sampler(0)]]) {
        return tex.sample(s, in.texCoord);
    }
    """
}
