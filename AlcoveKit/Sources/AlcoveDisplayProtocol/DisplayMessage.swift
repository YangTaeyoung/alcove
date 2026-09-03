import Foundation

/// Messages sent by the QEMU `alcove` display backend to the app.
/// Wire format: one JSON object per line, discriminated by `t`.
/// See docs/display-protocol.md.
public enum FromQEMU: Sendable, Equatable {
    case hello(Hello)
    case switchSurface(SurfaceSwitch)
    case update(Update)
    case cursor(CursorDefine)
    case mouse(MousePosition)
    case bye
    /// A message type this build does not know; carried for diagnostics.
    case unknown(type: String)

    /// Sent once after QEMU connects.
    public struct Hello: Codable, Sendable, Equatable {
        /// Protocol version. This library implements version 1.
        public var v: Int
        /// Number of QEMU consoles.
        public var consoles: Int
        /// Whether the guest pointer device is absolute (usb-tablet).
        public var abs: Bool?
        public init(v: Int, consoles: Int, abs: Bool? = nil) {
            self.v = v; self.consoles = consoles; self.abs = abs
        }
    }

    /// A new guest surface: geometry plus the shared file holding the pixels.
    public struct SurfaceSwitch: Codable, Sendable, Equatable {
        public var con: Int
        public var w: Int
        public var h: Int
        /// Row pitch in bytes.
        public var stride: Int
        /// Pixel format; only "bgra8" exists in protocol version 1.
        public var fmt: String
        /// Absolute path of the shared framebuffer file.
        public var shm: String
        /// Byte size of the shared file (page rounded, >= stride * h).
        public var size: Int
        public init(con: Int, w: Int, h: Int, stride: Int, fmt: String, shm: String, size: Int) {
            self.con = con; self.w = w; self.h = h; self.stride = stride
            self.fmt = fmt; self.shm = shm; self.size = size
        }

        /// The geometry is usable by this library (format known, sizes consistent).
        public var isValid: Bool {
            fmt == "bgra8" && w > 0 && h > 0 && stride >= w * 4 && size >= stride * h
        }
    }

    /// A rectangle of the surface changed in shared memory.
    public struct Update: Codable, Sendable, Equatable {
        public var con: Int
        public var x: Int
        public var y: Int
        public var w: Int
        public var h: Int
        public init(con: Int, x: Int, y: Int, w: Int, h: Int) {
            self.con = con; self.x = x; self.y = y; self.w = w; self.h = h
        }
    }

    /// A new hardware cursor image (ARGB32 words, no row padding) in a shared file.
    public struct CursorDefine: Codable, Sendable, Equatable {
        public var con: Int
        public var w: Int
        public var h: Int
        /// Hot spot.
        public var hx: Int
        public var hy: Int
        public var shm: String
        /// Byte size of the pixel data (w * h * 4).
        public var size: Int
        public init(con: Int, w: Int, h: Int, hx: Int, hy: Int, shm: String, size: Int) {
            self.con = con; self.w = w; self.h = h; self.hx = hx; self.hy = hy
            self.shm = shm; self.size = size
        }
    }

    /// Guest-driven cursor position and visibility (absolute pointer devices).
    public struct MousePosition: Codable, Sendable, Equatable {
        public var con: Int
        public var x: Int
        public var y: Int
        public var on: Bool
        public init(con: Int, x: Int, y: Int, on: Bool) {
            self.con = con; self.x = x; self.y = y; self.on = on
        }
    }
}

/// Pointer buttons, numbered as QEMU's qapi `InputButton` enum (v11.1.1:
/// left, middle, right, wheel-up, wheel-down, side, extra, wheel-left,
/// wheel-right, touch).
///
/// `touch` (9) is the qapi multi-touch contact button. The v1 protocol
/// document lists only 0..8 for `btn`; the backend accepts any qapi ordinal,
/// but usb-tablet (HID) has no mapping for it and drops it silently. Only
/// virtio-input devices act on it.
public enum InputButton: Int, Sendable, CaseIterable {
    case left = 0, middle, right, wheelUp, wheelDown, side, extra, wheelLeft, wheelRight, touch
}

/// Messages sent by the app to QEMU.
public enum ToQEMU: Sendable, Equatable {
    /// Key press or release. `mac` is a macOS virtual keycode (`NSEvent.keyCode`),
    /// mapped by QEMU itself; `q` is a `QKeyCode` used when `mac` is nil.
    case key(mac: Int?, q: QKeyCode?, down: Bool)
    /// Absolute pointer position in 0...32767 on both axes.
    case abs(con: Int, x: Int, y: Int)
    /// Relative pointer motion in pixels.
    case rel(con: Int, dx: Int, dy: Int)
    case btn(con: Int, button: InputButton, down: Bool)
    /// Flush queued pointer events to the guest.
    case sync
    /// Release every key QEMU believes is held.
    case lift
    /// Ask the guest to switch to this resolution (virtio-gpu guests only).
    case ui(con: Int, w: Int, h: Int)
    /// Ask QEMU to re-send a whole-surface `update`.
    case refresh(con: Int)

    /// Maximum absolute coordinate accepted by `abs`.
    public static let absoluteMax = 32767
}

public enum DisplayProtocolError: Error, Equatable, Sendable {
    case malformedJSON(String)
    case missingType
    case lineTooLong(Int)
}

extension FromQEMU {
    private struct Envelope: Decodable { let t: String }

    /// Decode one line (without the trailing newline).
    public static func decode(_ line: Data) throws -> FromQEMU {
        let decoder = JSONDecoder()
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: line)
        } catch {
            if (try? JSONSerialization.jsonObject(with: line)) is [String: Any] {
                throw DisplayProtocolError.missingType
            }
            throw DisplayProtocolError.malformedJSON(String(decoding: line.prefix(200), as: UTF8.self))
        }
        do {
            switch envelope.t {
            case "hello": return .hello(try decoder.decode(Hello.self, from: line))
            case "switch": return .switchSurface(try decoder.decode(SurfaceSwitch.self, from: line))
            case "update": return .update(try decoder.decode(Update.self, from: line))
            case "cursor": return .cursor(try decoder.decode(CursorDefine.self, from: line))
            case "mouse": return .mouse(try decoder.decode(MousePosition.self, from: line))
            case "bye": return .bye
            default: return .unknown(type: envelope.t)
            }
        } catch {
            throw DisplayProtocolError.malformedJSON("\(envelope.t): \(error)")
        }
    }
}

extension ToQEMU {
    /// The JSON line for this message, including the trailing newline.
    /// Only integers and booleans are emitted, so no escaping is needed.
    public var encodedLine: String {
        switch self {
        case let .key(mac, q, down):
            var s = "{\"t\":\"key\""
            if let mac { s += ",\"mac\":\(mac)" }
            if let q { s += ",\"q\":\(q.rawValue)" }
            return s + ",\"down\":\(down)}\n"
        case let .abs(con, x, y):
            let cx = min(max(x, 0), ToQEMU.absoluteMax)
            let cy = min(max(y, 0), ToQEMU.absoluteMax)
            return "{\"t\":\"abs\",\"con\":\(con),\"x\":\(cx),\"y\":\(cy)}\n"
        case let .rel(con, dx, dy):
            return "{\"t\":\"rel\",\"con\":\(con),\"dx\":\(dx),\"dy\":\(dy)}\n"
        case let .btn(con, button, down):
            return "{\"t\":\"btn\",\"con\":\(con),\"b\":\(button.rawValue),\"down\":\(down)}\n"
        case .sync:
            return "{\"t\":\"sync\"}\n"
        case .lift:
            return "{\"t\":\"lift\"}\n"
        case let .ui(con, w, h):
            return "{\"t\":\"ui\",\"con\":\(con),\"w\":\(w),\"h\":\(h)}\n"
        case let .refresh(con):
            return "{\"t\":\"refresh\",\"con\":\(con)}\n"
        }
    }
}
