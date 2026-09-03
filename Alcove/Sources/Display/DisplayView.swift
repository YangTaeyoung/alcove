import AlcoveDisplayProtocol
import SwiftUI

/// SwiftUI wrapper around `DisplayNSView`: renders the guest framebuffer
/// distributed by a `DisplayFeed` and forwards keyboard and mouse input to
/// the guest through the feed's connection.
///
/// Pass `nil` while the VM is stopped to show a blank placeholder; pass the
/// new feed after a restart and the view switches over, dropping the previous
/// surface. Closing and reopening the window attaches a fresh view to the
/// same feed, which replays the current surface, so the display is never
/// lost for the life of the run. Guest resolution changes are reported
/// through `onGuestResolutionChange` (width and height in guest pixels) so
/// the window can size itself.
struct DisplayView: NSViewRepresentable {
    /// The live display feed, or `nil` when there is no guest display.
    let feed: DisplayFeed?
    /// Invoked on the main actor when the guest switches to a new surface size.
    let onGuestResolutionChange: ((Int, Int) -> Void)?

    init(feed: DisplayFeed?, onGuestResolutionChange: ((Int, Int) -> Void)? = nil) {
        self.feed = feed
        self.onGuestResolutionChange = onGuestResolutionChange
    }

    func makeNSView(context: Context) -> DisplayNSView {
        let view = DisplayNSView()
        view.onGuestResolutionChange = onGuestResolutionChange
        view.feed = feed
        return view
    }

    func updateNSView(_ view: DisplayNSView, context: Context) {
        view.onGuestResolutionChange = onGuestResolutionChange
        if view.feed !== feed {
            view.feed = feed
        }
    }

    static func dismantleNSView(_ view: DisplayNSView, coordinator: ()) {
        view.feed = nil
        view.onGuestResolutionChange = nil
    }
}
