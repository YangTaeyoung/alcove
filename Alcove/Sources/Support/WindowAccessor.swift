import AppKit
import SwiftUI

/// An invisible view that reports the hosting `NSWindow` and tells the
/// caller when the user finishes a live resize (used to stop auto-fitting).
struct WindowAccessor: NSViewRepresentable {
    var onWindow: @MainActor (NSWindow?) -> Void
    var onUserResize: @MainActor () -> Void = {}

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onWindow = onWindow
        view.onUserResize = onUserResize
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onWindow = onWindow
        view.onUserResize = onUserResize
    }

    final class TrackingView: NSView {
        var onWindow: (@MainActor (NSWindow?) -> Void)?
        var onUserResize: (@MainActor () -> Void)?
        private weak var observedWindow: NSWindow?

        override var isHidden: Bool {
            get { true }
            set {}
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observedWindow {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didEndLiveResizeNotification, object: observedWindow)
            }
            observedWindow = window
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(didEndLiveResize(_:)),
                                                       name: NSWindow.didEndLiveResizeNotification, object: window)
            }
            onWindow?(window)
        }

        @objc private func didEndLiveResize(_ notification: Notification) {
            onUserResize?()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
