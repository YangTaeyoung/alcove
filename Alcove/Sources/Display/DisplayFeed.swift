import AlcoveDisplayProtocol
import Foundation

/// The single consumer of a `DisplayConnection`'s inbound stream.
///
/// `DisplayConnection.messages` is an `AsyncStream`, which supports exactly
/// one consumer for its whole life: cancelling the consuming task terminates
/// the stream for good, and a message that was already consumed (the guest's
/// `switch`, which QEMU sends only when the surface changes) is gone. A view
/// that iterated the stream itself therefore lost the display whenever its
/// window was closed and reopened. The feed owns that one iteration for as
/// long as the connection lives, remembers the messages a late-comer needs
/// (the current surface, cursor image and pointer position) and fans every
/// message out to the display views attached at the time.
///
/// Attaching replays the cached state synchronously and then asks QEMU to
/// re-mark the whole surface, so a freshly created view maps the framebuffer
/// and shows the current frame at once. Detaching only unregisters the view;
/// the feed's task is never cancelled from a view. The owner (`VMSession`)
/// drops the feed when the VM stops, which cancels the (by then finished)
/// task.
@MainActor
final class DisplayFeed {
    /// What attached views receive.
    enum Event {
        /// A message from QEMU (including `bye`).
        case message(FromQEMU)
        /// The inbound stream finished: QEMU disconnected or the connection was closed.
        case ended
    }

    /// The connection whose messages this feed distributes; views send input through it.
    let connection: DisplayConnection

    /// The latest `switch` per console, replayed to views that attach later.
    private(set) var surfaces: [Int: FromQEMU.SurfaceSwitch] = [:]
    /// The latest `cursor` per console.
    private(set) var cursors: [Int: FromQEMU.CursorDefine] = [:]
    /// The latest `mouse` per console.
    private(set) var pointers: [Int: FromQEMU.MousePosition] = [:]
    /// Whether the inbound stream has finished.
    private(set) var hasEnded = false

    private var sinks: [ObjectIdentifier: (Event) -> Void] = [:]
    private var task: Task<Void, Never>?

    init(connection: DisplayConnection) {
        self.connection = connection
        task = Task { @MainActor [weak self] in
            for await message in connection.messages {
                guard let self else { return }
                self.record(message)
                self.deliver(.message(message))
            }
            guard let self else { return }
            self.hasEnded = true
            self.deliver(.ended)
        }
    }

    deinit {
        task?.cancel()
    }

    /// Register `owner`'s sink. The cached surface, cursor and pointer (or
    /// `.ended` when the stream already finished) are delivered before this
    /// returns, then QEMU is asked to re-send the pixels of every known surface.
    func attach(_ owner: AnyObject, sink: @escaping (Event) -> Void) {
        sinks[ObjectIdentifier(owner)] = sink
        if hasEnded {
            sink(.ended)
            return
        }
        for con in surfaces.keys.sorted() {
            if let surface = surfaces[con] { sink(.message(.switchSurface(surface))) }
            if let cursor = cursors[con] { sink(.message(.cursor(cursor))) }
            if let pointer = pointers[con] { sink(.message(.mouse(pointer))) }
            connection.send(.refresh(con: con))
        }
    }

    /// Stop delivering to `owner`. Safe when it was never attached.
    func detach(_ owner: AnyObject) {
        sinks[ObjectIdentifier(owner)] = nil
    }

    // MARK: - internals

    private func record(_ message: FromQEMU) {
        switch message {
        case .switchSurface(let surface):
            surfaces[surface.con] = surface
            // A new surface invalidates the pointer position reported for the old one.
            pointers[surface.con] = nil
        case .cursor(let cursor):
            cursors[cursor.con] = cursor
        case .mouse(let pointer):
            pointers[pointer.con] = pointer
        case .hello, .update, .bye, .unknown:
            break
        }
    }

    private func deliver(_ event: Event) {
        // Snapshot: a sink may detach (or attach another view) while running.
        for sink in Array(sinks.values) {
            sink(event)
        }
    }
}
