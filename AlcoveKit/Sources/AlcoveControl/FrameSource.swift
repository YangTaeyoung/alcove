import Foundation
import AlcoveDisplayProtocol

/// Copies guest frames out of the shared framebuffer file named by a surface.
final class FrameSource: @unchecked Sendable {
    /// Which file a path names at one moment.
    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t

        /// The identity of the file at `path`; nil when there is none.
        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
        }
    }

    private let lock = NSLock()
    private var mapping: SharedFramebuffer?
    /// The file `mapping` was made from.
    private var mapped: FileIdentity?

    /// Copies the current surface into a tightly packed `Frame`; nil when `surface` is nil, invalid or cannot be mapped.
    /// The file is mapped again when the surface names another path or size, and when another file is at its path.
    func frame(for surface: FromQEMU.SurfaceSwitch?) -> Frame? {
        guard let surface, surface.isValid else { return nil }
        lock.lock(); defer { lock.unlock() }
        let current = FileIdentity(path: surface.shm)
        if mapping?.path != surface.shm || mapping?.size != surface.size || mapped != current {
            mapping = current == nil ? nil : try? SharedFramebuffer(path: surface.shm, size: surface.size)
            mapped = current
        }
        guard let mapping else { return nil }
        let rowBytes = surface.w * 4
        let totalBytes = rowBytes * surface.h
        var out = Data(count: totalBytes)
        let copied: Bool = mapping.withBytes { src in
            guard src.count >= surface.stride * surface.h else { return false }
            out.withUnsafeMutableBytes { dst in
                if surface.stride == rowBytes {
                    memcpy(dst.baseAddress!, src.baseAddress!, totalBytes)
                } else {
                    for row in 0..<surface.h {
                        memcpy(dst.baseAddress! + row * rowBytes, src.baseAddress! + row * surface.stride, rowBytes)
                    }
                }
            }
            return true
        }
        guard copied else { return nil }
        return Frame(width: surface.w, height: surface.h, pixels: out)
    }
}
