import Foundation
import AlcoveDisplayProtocol

/// Copies guest frames out of the shared framebuffer file named by a surface.
final class FrameSource: @unchecked Sendable {
    private let lock = NSLock()
    private var mapping: SharedFramebuffer?

    /// Copies the current surface into a tightly packed `Frame`; nil when `surface` is nil, invalid or cannot be mapped.
    func frame(for surface: FromQEMU.SurfaceSwitch?) -> Frame? {
        guard let surface, surface.isValid else { return nil }
        lock.lock(); defer { lock.unlock() }
        if mapping?.path != surface.shm || mapping?.size != surface.size {
            mapping = try? SharedFramebuffer(path: surface.shm, size: surface.size)
        }
        guard let mapping else { return nil }
        let rowBytes = surface.w * 4
        var out = Data(count: rowBytes * surface.h)
        let copied: Bool = mapping.withBytes { src in
            guard src.count >= surface.stride * surface.h else { return false }
            out.withUnsafeMutableBytes { dst in
                for row in 0..<surface.h {
                    memcpy(dst.baseAddress! + row * rowBytes, src.baseAddress! + row * surface.stride, rowBytes)
                }
            }
            return true
        }
        guard copied else { return nil }
        return Frame(width: surface.w, height: surface.h, pixels: out)
    }
}
