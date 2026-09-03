import AlcoveDisplayProtocol
import AppKit
import MetalKit

/// The guest screen: an `MTKView` that presents the shared framebuffer
/// distributed by a `DisplayFeed` and forwards keyboard and pointer input to
/// QEMU through the feed's `DisplayConnection`.
///
/// The view never iterates the connection's message stream itself (a stream
/// has one consumer for its whole life); it attaches a sink to the feed,
/// which replays the current surface on attach so a view created after the
/// guest's last `switch` still maps the framebuffer.
///
/// Rendering is demand-driven (`isPaused` + `enableSetNeedsDisplay`): every
/// `update`, cursor or resize marks the view dirty and AppKit coalesces the
/// redraws into one per display cycle. Only console 0 is presented.
///
/// Input model (mirrors QEMU's own Cocoa backend):
/// - Raw macOS virtual keycodes go to QEMU, which maps them itself.
/// - Modifier keys are derived from `flagsChanged` using the event's keycode
///   plus the device-dependent left/right bits; keys are released when their
///   flag disappears from any later event, and every held key is lifted when
///   the view loses focus.
/// - Cmd-combos are forwarded from `performKeyEquivalent`, except the ones
///   macOS should keep (Cmd-Q/W/H/M/Tab).
/// - The pointer is absolute (`abs` in 0...32767); positions outside the
///   letterboxed surface are dropped unless a button is held, in which case
///   they clamp to the edge so drags keep tracking.
/// - The host cursor is hidden over the view only while the guest provides a
///   hardware cursor image (which the renderer then overlays).
@MainActor
final class DisplayNSView: MTKView {
    /// The guest console this view presents.
    static let console = 0

    /// Why nothing is being drawn, for the placeholder text.
    private enum Status: Equatable {
        case noRenderer(String)
        case idle
        case waiting
        case live
        case disconnected
        case failed(String)
    }

    /// The feed distributing the guest's display messages. Setting a
    /// different instance re-attaches the view (the feed replays the current
    /// surface); `nil` detaches and blanks the view.
    var feed: DisplayFeed? {
        didSet { if feed !== oldValue { feedDidChange(from: oldValue) } }
    }

    /// The connection input is sent through, while a feed is attached.
    private var connection: DisplayConnection? { feed?.connection }

    /// Called on the main actor whenever the guest surface size changes.
    var onGuestResolutionChange: ((Int, Int) -> Void)?
    /// Asks the guest to adopt a display mode (view size in points). When nil
    /// the view sends QEMU's resize hint itself; the app supplies a closure
    /// that prefers the guest tools, which viogpudo actually honours.
    var onResolutionRequest: ((Int, Int) -> Void)?

    /// Send `ui` requests so a virtio-gpu guest follows the view size (in
    /// points). Ignored by guests without a driver (ramfb).
    var resolutionFollowsView = true

    /// The reason rendering is unavailable, if Metal could not be set up.
    private(set) var rendererError: String?

    /// Points of precise (trackpad) scrolling per wheel notch.
    private static let pointsPerNotch: CGFloat = 10
    /// Debounce for window-resize driven `ui` requests.
    private static let resizeDebounce: Duration = .milliseconds(300)
    /// Upper bound on wheel notches emitted for one scroll event.
    private static let maxNotchesPerEvent = 32

    private var renderer: MetalRenderer?
    private var status: Status = .idle { didSet { if status != oldValue { updatePlaceholder() } } }
    private var resizeTask: Task<Void, Never>?
    private var surface: SharedFramebuffer?
    private var surfaceGeometry: FromQEMU.SurfaceSwitch?
    private var cursorImage: SharedFramebuffer?
    private var hasGuestCursor = false
    private var reportedResolution: (w: Int, h: Int)?
    private var heldModifierKeys = Set<UInt16>()
    private var heldButtons = Set<InputButton>()
    private var lastAbsolute: (x: Int, y: Int)?
    private var scrollRemainder = (x: CGFloat(0), y: CGFloat(0))
    private let placeholderLabel = NSTextField(labelWithString: "")

    // MARK: - Lifecycle

    init(frame: NSRect = .zero) {
        let (renderer, error) = DisplayNSView.makeRenderer()
        self.renderer = renderer
        self.rendererError = error
        super.init(frame: frame, device: renderer?.device)
        commonInit()
    }

    required init(coder: NSCoder) {
        let (renderer, error) = DisplayNSView.makeRenderer()
        self.renderer = renderer
        self.rendererError = error
        super.init(coder: coder)
        device = renderer?.device
        commonInit()
    }

    deinit {
        // The feed holds only a sink keyed by this object's identity; the
        // closure captures `self` weakly, so a view that is deallocated
        // without being detached leaves an inert entry, not a leak.
        resizeTask?.cancel()
    }

    private static func makeRenderer() -> (MetalRenderer?, String?) {
        do {
            return (try MetalRenderer(), nil)
        } catch {
            return (nil, "\(error)")
        }
    }

    private func commonInit() {
        colorPixelFormat = MetalRenderer.colorPixelFormat
        clearColor = MetalRenderer.clearColor
        isPaused = true
        enableSetNeedsDisplay = true
        framebufferOnly = true
        layer?.backgroundColor = CGColor(red: MetalRenderer.clearColor.red, green: MetalRenderer.clearColor.green,
                                         blue: MetalRenderer.clearColor.blue, alpha: 1)

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.alignment = .center
        placeholderLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        placeholderLabel.textColor = NSColor(white: 0.62, alpha: 1)
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.maximumNumberOfLines = 4
        placeholderLabel.isSelectable = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])

        if renderer == nil {
            status = .noRenderer(rendererError ?? "Metal unavailable")
        }
        updatePlaceholder()
    }

    /// Top-left origin, matching the guest's coordinate system.
    override var isFlipped: Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey(_:)),
                                               name: NSWindow.didResignKeyNotification, object: window)
        if window.firstResponder === window {
            window.makeFirstResponder(self)
        }
    }

    @objc private func windowDidResignKey(_ note: Notification) {
        liftAllInput()
    }

    // MARK: - Feed and messages

    private func feedDidChange(from previous: DisplayFeed?) {
        previous?.detach(self)
        resizeTask?.cancel()
        resizeTask = nil
        tearDownSurface()
        heldModifierKeys.removeAll()
        heldButtons.removeAll()
        lastAbsolute = nil
        scrollRemainder = (0, 0)

        guard let feed else {
            status = renderer == nil ? status : .idle
            return
        }
        status = renderer == nil ? status : .waiting
        // Attaching replays the cached surface synchronously, so the guard
        // against a stale feed matters only for events delivered later. Both
        // captures are weak: the feed stores this closure, and a strong feed
        // capture would keep the pair alive until detach.
        feed.attach(self) { [weak self, weak feed] event in
            guard let self, let feed, self.feed === feed else { return }
            switch event {
            case .message(let message): self.handle(message)
            case .ended: self.displayEnded()
            }
        }
    }

    private func handle(_ message: FromQEMU) {
        switch message {
        case .hello:
            break
        case .switchSurface(let geometry):
            guard geometry.con == Self.console else { return }
            adoptSurface(geometry)
        case .update(let rect):
            guard rect.con == Self.console, surface != nil else { return }
            renderer?.update(rect: rect)
            needsDisplay = true
        case .cursor(let define):
            guard define.con == Self.console else { return }
            adoptCursor(define)
        case .mouse(let position):
            guard position.con == Self.console else { return }
            renderer?.setMouse(position)
            needsDisplay = true
        case .bye:
            displayEnded()
        case .unknown:
            break
        }
    }

    private func adoptSurface(_ geometry: FromQEMU.SurfaceSwitch) {
        guard geometry.isValid else {
            tearDownSurface()
            status = .failed("Unsupported guest surface: \(geometry.w)x\(geometry.h) \(geometry.fmt)")
            return
        }
        let mapped: SharedFramebuffer
        do {
            mapped = try SharedFramebuffer(path: geometry.shm, size: geometry.size)
        } catch {
            tearDownSurface()
            status = .failed("Cannot map the guest framebuffer: \(error)")
            return
        }
        surface = mapped
        surfaceGeometry = geometry
        renderer?.apply(surface: mapped, geometry: geometry)
        lastAbsolute = nil
        if renderer != nil { status = .live }
        if reportedResolution?.w != geometry.w || reportedResolution?.h != geometry.h {
            reportedResolution = (geometry.w, geometry.h)
            onGuestResolutionChange?(geometry.w, geometry.h)
        }
        needsDisplay = true
    }

    private func adoptCursor(_ define: FromQEMU.CursorDefine) {
        guard define.w > 0, define.h > 0, define.size >= define.w * define.h * 4 else { return }
        do {
            let image = try SharedFramebuffer(path: define.shm, size: define.size)
            renderer?.setCursor(image: image, define: define)
            cursorImage = image
        } catch {
            return
        }
        if !hasGuestCursor {
            hasGuestCursor = true
            window?.invalidateCursorRects(for: self)
        }
        needsDisplay = true
    }

    /// The backend said goodbye or the socket closed: blank the view.
    private func displayEnded() {
        tearDownSurface()
        if renderer != nil {
            status = feed == nil ? .idle : .disconnected
        }
        needsDisplay = true
    }

    private func tearDownSurface() {
        renderer?.clear()
        surface = nil
        surfaceGeometry = nil
        cursorImage = nil
        if hasGuestCursor {
            hasGuestCursor = false
            window?.invalidateCursorRects(for: self)
        }
    }

    private func updatePlaceholder() {
        let text: String
        switch status {
        case .noRenderer(let reason): text = "Display unavailable\n\(reason)"
        case .idle: text = "The virtual machine is not running"
        case .waiting: text = "Waiting for the guest display…"
        case .live: text = ""
        case .disconnected: text = "Display disconnected"
        case .failed(let reason): text = reason
        }
        placeholderLabel.stringValue = text
        placeholderLabel.isHidden = text.isEmpty
    }

    // MARK: - Drawing and layout

    override func draw(_ dirtyRect: NSRect) {
        renderer?.draw(in: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        scheduleResolutionRequest()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    /// Ask the guest to adopt the view's size (in points), debounced so a
    /// window drag produces one request. Skipped when the guest already
    /// matches; ramfb guests ignore it.
    private func scheduleResolutionRequest() {
        resizeTask?.cancel()
        guard resolutionFollowsView, feed != nil else { return }
        let scheduledSize = bounds.size
        resizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: DisplayNSView.resizeDebounce)
            guard !Task.isCancelled, let self, let connection = self.connection else { return }
            // A surface switch makes SwiftUI re-lay out, and the view passes
            // through its minimum size on the way. Only a size that is still
            // there when the debounce fires is the size the user is looking at.
            guard self.bounds.size == scheduledSize else { return }
            let w = Int(self.bounds.width.rounded()), h = Int(self.bounds.height.rounded())
            guard w > 0, h > 0 else { return }
            if let g = self.surfaceGeometry, g.w == w, g.h == h { return }
            if let request = self.onResolutionRequest {
                request(w, h)
            } else {
                connection.send(.ui(con: DisplayNSView.console, w: w, h: h))
            }
        }
    }

    // MARK: - Focus

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resignFirstResponder() -> Bool {
        liftAllInput()
        return true
    }

    /// Release every key and button the guest may believe is held.
    private func liftAllInput() {
        guard let connection else {
            heldModifierKeys.removeAll()
            heldButtons.removeAll()
            return
        }
        connection.send(.lift)
        heldModifierKeys.removeAll()
        if !heldButtons.isEmpty {
            for button in heldButtons {
                connection.send(.btn(con: Self.console, button: button, down: false))
            }
            connection.send(.sync)
            heldButtons.removeAll()
        }
    }

    // MARK: - Keyboard

    /// Modifier keys by `kVK_*` keycode (Carbon `Events.h`), with the generic
    /// flag and the device-dependent left/right bit (`IOLLEvent.h`
    /// `NX_DEVICE*KEYMASK`) that identify the physical key.
    private struct ModifierKey {
        let flag: NSEvent.ModifierFlags
        let deviceBit: UInt
        let pairBits: UInt
    }

    private static let modifierKeys: [UInt16: ModifierKey] = [
        0x38: ModifierKey(flag: .shift, deviceBit: 0x0002, pairBits: 0x0006),     // kVK_Shift
        0x3C: ModifierKey(flag: .shift, deviceBit: 0x0004, pairBits: 0x0006),     // kVK_RightShift
        0x3B: ModifierKey(flag: .control, deviceBit: 0x0001, pairBits: 0x2001),   // kVK_Control
        0x3E: ModifierKey(flag: .control, deviceBit: 0x2000, pairBits: 0x2001),   // kVK_RightControl
        0x3A: ModifierKey(flag: .option, deviceBit: 0x0020, pairBits: 0x0060),    // kVK_Option
        0x3D: ModifierKey(flag: .option, deviceBit: 0x0040, pairBits: 0x0060),    // kVK_RightOption
        0x37: ModifierKey(flag: .command, deviceBit: 0x0008, pairBits: 0x0018),   // kVK_Command
        0x36: ModifierKey(flag: .command, deviceBit: 0x0010, pairBits: 0x0018),   // kVK_RightCommand
    ]
    private static let capsLockKeyCode: UInt16 = 0x39  // kVK_CapsLock

    /// Cmd-combos macOS keeps: Q (quit), W (close), H (hide), M (minimize), Tab (app switcher).
    private static let reservedCommandKeyCodes: Set<UInt16> = [0x0C, 0x0D, 0x04, 0x2E, 0x30]


    /// The guest receives key input only while the display view actually owns
    /// keystrokes: no sheet (Settings, Snapshots, an alert) is attached to the
    /// window over it. Without this a key pressed with a sheet up — or a
    /// synthetic key delivered while a sheet has no focused control — would
    /// reach the guest and, because the matching key-up is routed to the sheet,
    /// stick down and autorepeat in the guest.
    private var acceptsGuestKeys: Bool {
        guard let window else { return false }
        return window.attachedSheet == nil
    }

    override func keyDown(with event: NSEvent) {
        guard let connection, acceptsGuestKeys else { return }
        syncModifiers(with: event.modifierFlags)
        connection.send(.key(mac: Int(event.keyCode), q: nil, down: true))
    }

    override func keyUp(with event: NSEvent) {
        guard let connection, acceptsGuestKeys else { return }
        syncModifiers(with: event.modifierFlags)
        connection.send(.key(mac: Int(event.keyCode), q: nil, down: false))
    }

    override func flagsChanged(with event: NSEvent) {
        guard let connection, acceptsGuestKeys else { return }
        let flags = event.modifierFlags
        let code = event.keyCode
        if code == Self.capsLockKeyCode {
            // Caps Lock is a toggle on the host; a press+release flips the guest's state.
            connection.send(.key(mac: Int(code), q: nil, down: true))
            connection.send(.key(mac: Int(code), q: nil, down: false))
            releaseModifiers(absentFrom: flags)
            return
        }
        if let key = Self.modifierKeys[code] {
            let down: Bool
            if !flags.contains(key.flag) {
                down = false
            } else if flags.rawValue & key.pairBits != 0 {
                down = flags.rawValue & key.deviceBit != 0
            } else {
                // No per-side information: infer from what we last sent.
                down = !heldModifierKeys.contains(code)
            }
            setModifier(code, down: down)
        }
        releaseModifiers(absentFrom: flags)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let connection, acceptsGuestKeys, window?.firstResponder === self else { return false }
        guard event.modifierFlags.contains(.command) else { return false }
        // Cmd-combos macOS itself keeps (Q/W/H/M/Tab): let AppKit handle them.
        if Self.reservedCommandKeyCodes.contains(event.keyCode) { return false }
        // The app's own menu shortcuts (Take Snapshot ⇧⌘S, Start ⇧⌘R,
        // Pause/Resume ⇧⌘P, New VM ⌘N, standard window/edit items) must act on
        // the app, not type into the guest. Give the main menu the event; if it
        // performs a command, consume it here so it neither double-fires nor
        // reaches the guest.
        if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) { return true }
        // Any other Cmd-combo goes to the guest as a tap (down then up in one
        // batch) so the key cannot stick down and autorepeat there.
        syncModifiers(with: event.modifierFlags)
        connection.send(.key(mac: Int(event.keyCode), q: nil, down: true))
        connection.send(.key(mac: Int(event.keyCode), q: nil, down: false))
        return true
    }

    /// The left-hand key that stands in for a modifier flag we never saw go
    /// down (see `syncModifiers(with:)`).
    private static let leftModifierKeyCodes: [(flag: NSEvent.ModifierFlags, code: UInt16)] = [
        (.shift, 0x38), (.control, 0x3B), (.option, 0x3A), (.command, 0x37),
    ]

    /// Bring the guest's modifier state in line with an event's flags:
    /// release held modifiers whose flag is gone, and press (as the left-hand
    /// key) modifiers whose flag is set but never reached `flagsChanged` —
    /// the user held it before this view became first responder (Shift-click
    /// into the display, Cmd-Tab with Cmd still down), or the event is
    /// synthetic (accessibility and automation set the flag on the key event
    /// only). Without this the guest would see `A` typed as `a`.
    private func syncModifiers(with flags: NSEvent.ModifierFlags) {
        releaseModifiers(absentFrom: flags)
        for entry in Self.leftModifierKeyCodes where flags.contains(entry.flag) {
            let held = heldModifierKeys.contains { Self.modifierKeys[$0]?.flag == entry.flag }
            if !held { setModifier(entry.code, down: true) }
        }
    }

    private func setModifier(_ code: UInt16, down: Bool) {
        guard let connection else { return }
        if down, !heldModifierKeys.contains(code) {
            heldModifierKeys.insert(code)
            connection.send(.key(mac: Int(code), q: nil, down: true))
        } else if !down, heldModifierKeys.contains(code) {
            heldModifierKeys.remove(code)
            connection.send(.key(mac: Int(code), q: nil, down: false))
        }
    }

    /// Release held modifier keys whose flag is no longer set (the state may
    /// have changed while another app was active and no event reached us).
    private func releaseModifiers(absentFrom flags: NSEvent.ModifierFlags) {
        for code in heldModifierKeys {
            if let key = Self.modifierKeys[code], !flags.contains(key.flag) {
                setModifier(code, down: false)
            }
        }
    }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: hasGuestCursor ? Self.hiddenCursor : .arrow)
    }

    /// A fully transparent cursor, used while the guest draws its own.
    private static let hiddenCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true }
        return NSCursor(image: image, hotSpot: .zero)
    }()

    override func mouseMoved(with event: NSEvent) { sendPointer(event, sync: true) }
    override func mouseDragged(with event: NSEvent) { sendPointer(event, sync: true) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event, sync: true) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event, sync: true) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendButton(.left, down: true, event: event)
    }
    override func mouseUp(with event: NSEvent) { sendButton(.left, down: false, event: event) }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendButton(.right, down: true, event: event)
    }
    override func rightMouseUp(with event: NSEvent) { sendButton(.right, down: false, event: event) }
    override func otherMouseDown(with event: NSEvent) {
        guard let button = Self.button(for: event.buttonNumber) else { return }
        window?.makeFirstResponder(self)
        sendButton(button, down: true, event: event)
    }
    override func otherMouseUp(with event: NSEvent) {
        guard let button = Self.button(for: event.buttonNumber) else { return }
        sendButton(button, down: false, event: event)
    }

    /// AppKit button numbers beyond left/right: 2 middle, 3 side (back), 4 extra (forward).
    private static func button(for number: Int) -> InputButton? {
        switch number {
        case 2: return .middle
        case 3: return .side
        case 4: return .extra
        default: return nil
        }
    }

    /// Queue an `abs` for the event's location. Returns `false` when nothing
    /// was queued (no surface, outside the surface, or unchanged position).
    @discardableResult
    private func sendPointer(_ event: NSEvent, sync: Bool) -> Bool {
        guard let connection, let geometry = surfaceGeometry else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard let guest = DisplayGeometry.guestPoint(from: point, viewSize: bounds.size,
                                                     surface: CGSize(width: geometry.w, height: geometry.h),
                                                     flippedY: isFlipped, clampToSurface: !heldButtons.isEmpty)
        else { return false }
        if let last = lastAbsolute, last.x == guest.x, last.y == guest.y { return false }
        lastAbsolute = guest
        connection.send(.abs(con: Self.console, x: guest.x, y: guest.y))
        if sync { connection.send(.sync) }
        return true
    }

    private func sendButton(_ button: InputButton, down: Bool, event: NSEvent) {
        guard let connection else { return }
        syncModifiers(with: event.modifierFlags)
        if down { heldButtons.insert(button) } else { heldButtons.remove(button) }
        // Position and button travel in one batch so the click lands where the pointer is.
        sendPointer(event, sync: false)
        connection.send(.btn(con: Self.console, button: button, down: down))
        connection.send(.sync)
    }

    override func scrollWheel(with event: NSEvent) {
        guard connection != nil, surfaceGeometry != nil else { return }
        var notchesY = 0, notchesX = 0
        if event.hasPreciseScrollingDeltas {
            if event.phase == .began || event.momentumPhase == .began { scrollRemainder = (0, 0) }
            scrollRemainder.y += event.scrollingDeltaY
            scrollRemainder.x += event.scrollingDeltaX
            notchesY = Int(scrollRemainder.y / Self.pointsPerNotch)
            notchesX = Int(scrollRemainder.x / Self.pointsPerNotch)
            scrollRemainder.y -= CGFloat(notchesY) * Self.pointsPerNotch
            scrollRemainder.x -= CGFloat(notchesX) * Self.pointsPerNotch
        } else {
            notchesY = Self.wholeNotches(event.scrollingDeltaY)
            notchesX = Self.wholeNotches(event.scrollingDeltaX)
        }
        sendPointer(event, sync: true)
        emitWheel(notchesY, positive: .wheelUp, negative: .wheelDown)
        emitWheel(notchesX, positive: .wheelLeft, negative: .wheelRight)
    }

    /// A wheel mouse reports whole lines, but slow turns arrive as fractions;
    /// every non-zero event is at least one notch (as QEMU's Cocoa UI does).
    private static func wholeNotches(_ delta: CGFloat) -> Int {
        guard delta != 0 else { return 0 }
        let magnitude = max(1, Int(abs(delta).rounded()))
        return delta > 0 ? magnitude : -magnitude
    }

    private func emitWheel(_ count: Int, positive: InputButton, negative: InputButton) {
        guard count != 0, let connection else { return }
        let button = count > 0 ? positive : negative
        for _ in 0..<min(abs(count), Self.maxNotchesPerEvent) {
            connection.send(.btn(con: Self.console, button: button, down: true))
            connection.send(.sync)
            connection.send(.btn(con: Self.console, button: button, down: false))
            connection.send(.sync)
        }
    }
}
