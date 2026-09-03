import Foundation

/// A read-only memory mapping of a shared framebuffer (or cursor) file
/// created by the QEMU `alcove` backend. Unmapped when deallocated.
public final class SharedFramebuffer: @unchecked Sendable {
    public enum MapError: Error, Equatable {
        case open(path: String, errno: Int32)
        case fileTooSmall(path: String, expected: Int, actual: Int)
        case mmap(errno: Int32)
    }

    public let path: String
    public let size: Int
    private let base: UnsafeMutableRawPointer

    /// Map `size` bytes of `path`. Fails if the file is shorter than `size`.
    public init(path: String, size: Int) throws {
        precondition(size > 0)
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw MapError.open(path: path, errno: errno) }
        defer { close(fd) }
        var st = stat()
        if fstat(fd, &st) == 0, Int(st.st_size) < size {
            throw MapError.fileTooSmall(path: path, expected: size, actual: Int(st.st_size))
        }
        guard let p = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), p != MAP_FAILED else {
            throw MapError.mmap(errno: errno)
        }
        self.path = path
        self.size = size
        self.base = p
    }

    deinit {
        munmap(base, size)
    }

    /// The mapped bytes. The pointer is valid only inside `body`.
    public func withBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        try body(UnsafeRawBufferPointer(start: base, count: size))
    }

    /// Raw pointer to the mapping; valid for the lifetime of this object.
    public var baseAddress: UnsafeRawPointer { UnsafeRawPointer(base) }
}
