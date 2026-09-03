import AppKit
import SwiftUI
import AlcoveEngine

/// Root of a VM window. Resolves the session id carried by the window scene;
/// the id changes when the VM is renamed from the Settings sheet.
struct VMWindowView: View {
    @Binding var sessionID: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = sessionID.flatMap(model.session(id:)) {
            VMContentView(session: session, sessionID: $sessionID)
                .id(session.id)
        } else {
            ContentUnavailableView("Virtual Machine Not Found", systemImage: "questionmark.square.dashed",
                                   description: Text("It may have been deleted or moved. Close this window and open it again from the library."))
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}

/// The guest display with toolbar, status bar and the stopped-state overlay.
private struct VMContentView: View {
    @Bindable var session: VMSession
    @Binding var sessionID: String?
    @Environment(AppModel.self) private var model

    @State private var guestSize: (width: Int, height: Int)?
    @State private var showSnapshots = false
    @State private var showSettings = false
    @State private var confirmReset = false
    @State private var confirmForceStop = false
    @State private var pendingDiscard: VMSession?
    @State private var window: NSWindow?
    @State private var userResized = false
    /// The last screenshot written, shown transiently in the status bar.
    @State private var screenshotNotice: URL?
    @State private var screenshotNoticeTask: Task<Void, Never>?

    private let statusBarHeight: CGFloat = 26
    /// How long the "screenshot saved" notice stays in the status bar.
    private static let screenshotNoticeDuration: Duration = .seconds(4)

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                DisplayView(feed: session.display,
                            onGuestResolutionChange: { width, height in
                                guestResolutionChanged(width: width, height: height)
                            },
                            onResolutionRequest: { [session] width, height in
                                session.requestGuestResolution(width: width, height: height)
                            })
                if !session.state.isActive {
                    stoppedOverlay
                }
            }
            .frame(minWidth: 640, minHeight: 400)
            statusBar
        }
        .background(WindowAccessor(onWindow: { window = $0 }, onUserResize: { userResized = true }))
        .navigationTitle(session.name)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showSnapshots) { SnapshotsSheet(session: session) }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(session: session) { renamed in sessionID = renamed.id }
        }
        .confirmationDialog("Reset “\(session.name)”?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { Task { await session.reset() } }
        } message: {
            Text("The guest restarts immediately, like pressing a hardware reset button. Unsaved work in the guest is lost.")
        }
        .confirmationDialog("Force stop “\(session.name)”?", isPresented: $confirmForceStop) {
            Button("Force Stop", role: .destructive) { Task { await session.shutdown(force: true) } }
        } message: {
            Text("The engine quits without telling the guest, like pulling the power cord. Unsaved work in the guest is lost.")
        }
        .confirmDiscardSuspendState($pendingDiscard) { session in
            Task { await session.discardSuspendState() }
        }
        .errorAlert($session.lastError)
        .focusedSceneValue(\.vmCommands, VMWindowCommands(session: session,
                                                          start: { Task { await session.start() } },
                                                          run: { operation in Task { await operation(session) } },
                                                          takeSnapshot: { showSnapshots = true },
                                                          reset: { confirmReset = true },
                                                          forceStop: { confirmForceStop = true },
                                                          discardSuspendState: { pendingDiscard = session }))
        .task { model.usbDevices.startWatching() }
        .onDisappear { screenshotNoticeTask?.cancel() }
    }

    private var subtitle: String {
        if case .stopped = session.state, session.isSuspended { return "Suspended" }
        return session.state.label
    }

    // MARK: - toolbar

    /// The controller accepts a shutdown in every active state but
    /// `.stopping`: while `.starting` it aborts the start, while
    /// `.suspending` only a forced stop is honoured (it drops the partial
    /// state). The Shut Down group follows those rules so a stuck start or
    /// suspend can be interrupted from the toolbar, not only the menu bar.
    private var canShutDown: Bool { session.state.isActive && session.state != .stopping }
    private var forceStopOnly: Bool { session.state == .suspending }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if session.state.isActive {
                Menu {
                    Button("Suspend to Disk") { Task { await session.suspend() } }
                        .disabled(!session.canSuspend)
                    Button("Force Stop…", role: .destructive) { confirmForceStop = true }
                } label: {
                    Label(session.state == .starting ? "Abort Start" : "Shut Down", systemImage: "power")
                } primaryAction: {
                    if forceStopOnly {
                        confirmForceStop = true
                    } else {
                        Task { await session.shutdown(force: false) }
                    }
                }
                .help(shutDownHelp)
                .disabled(!canShutDown)
            } else if session.isSuspended {
                Menu {
                    Button("Discard Suspended State…") { pendingDiscard = session }
                        .disabled(!session.canDiscardSuspendState)
                } label: {
                    Label("Resume", systemImage: "play.fill")
                } primaryAction: {
                    Task { await session.start() }
                }
                .help("Resume from disk. The menu can discard the saved session instead.")
            } else {
                Button { Task { await session.start() } } label: { Label("Start", systemImage: "play.fill") }
                    .help("Start")
            }

            if session.state == .paused {
                Button { Task { await session.resume() } } label: { Label("Resume", systemImage: "playpause.fill") }
                    .help("Resume")
            } else {
                Button { Task { await session.pause() } } label: { Label("Pause", systemImage: "pause.fill") }
                    .help("Pause")
                    .disabled(!session.canPause)
            }

            Button { confirmReset = true } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                .help("Reset")
                .disabled(!session.canReset)

            Button { showSnapshots = true } label: { Label("Snapshots", systemImage: "camera.on.rectangle") }
                .help("Snapshots…")

            usbMenu

            Button { Task { await takeScreenshot() } } label: { Label("Screenshot", systemImage: "camera") }
                .help("Save a screenshot to Pictures")
                .disabled(!session.state.isActive || session.state.isTransitional)

            Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                .help("Settings…")
        }
    }

    private var shutDownHelp: String {
        switch session.state {
        case .starting: "Abort the start. The menu offers Force Stop."
        case .suspending: "Suspending… Force Stop abandons the partial state."
        default: "Shut Down (power button). The menu offers Suspend and Force Stop."
        }
    }

    private var usbMenu: some View {
        Menu {
            if model.usbDevices.devices.isEmpty {
                Text("No USB devices")
            }
            ForEach(model.usbDevices.devices) { device in
                let attachedID = session.attachedUSB[device.selector.id]
                Toggle(isOn: Binding(get: { attachedID != nil }, set: { on in toggleUSB(device, attach: on) })) {
                    VStack(alignment: .leading) {
                        Text(device.displayName)
                        Text(device.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Button("Refresh") { model.usbDevices.refresh() }
            if let error = model.usbDevices.lastError {
                Text(error)
            }
        } label: {
            Label("USB", systemImage: "cable.connector")
        }
        .help(session.state.isActive ? "Attach or detach host USB devices" : "Start the VM to attach USB devices")
        .disabled(!session.state.isActive || session.state.isTransitional)
    }

    // MARK: - overlays

    private var stoppedOverlay: some View {
        ZStack {
            Color.black
            VStack(spacing: 18) {
                Image(systemName: session.config.guestOS.symbolName)
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.secondary)
                Text(session.name)
                    .font(.title2)
                    .foregroundStyle(.white)
                if case .failed(let message) = session.state {
                    ScrollView {
                        Text(ErrorText.humanize(message))
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: 560, maxHeight: 140)
                    .padding(8)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                Button { Task { await session.start() } } label: {
                    Label(session.isSuspended ? "Resume" : "Start", systemImage: "play.fill")
                        .font(.title3)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                if session.isSuspended {
                    Button("Discard Suspended State…") { pendingDiscard = session }
                        .buttonStyle(.link)
                        .foregroundStyle(.secondary)
                        .disabled(!session.canDiscardSuspendState)
                        .help("Delete the saved session so the next start boots from scratch")
                }
            }
            .padding(32)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(stateColor).frame(width: 8, height: 8)
            Text(subtitle)
            if session.state.isTransitional {
                ProgressView().controlSize(.mini)
            }
            if let screenshotNotice {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([screenshotNotice])
                } label: {
                    Label("Saved \(screenshotNotice.lastPathComponent)", systemImage: "checkmark.circle")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.link)
                .help("Show \(screenshotNotice.path) in Finder")
                .transition(.opacity)
            }
            Spacer()
            if session.state.isActive {
                Label(session.toolsConnected ? "Tools" : "No tools",
                      systemImage: session.toolsConnected ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(session.toolsConnected ? .secondary : .tertiary)
                    .help(session.toolsConnected
                          ? "Alcove guest tools are connected: shell, clipboard, file drop and exact display modes are available."
                          : "Alcove guest tools are not running in this guest. Install alcove-agent inside the guest to enable shell access, clipboard sync and file drop.")
            }
            if let guestSize, session.state.isActive {
                Text("\(guestSize.width) × \(guestSize.height)").monospacedDigit()
            }
            Text("\(session.config.cpuCount) vCPU · \(memoryText)")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(height: statusBarHeight)
        .background(.bar)
        .animation(.default, value: screenshotNotice)
    }

    private var stateColor: Color {
        switch session.state {
        case .running: .green
        case .paused: .yellow
        case .starting, .stopping, .suspending: .orange
        case .failed: .red
        case .stopped: session.isSuspended ? .blue : .secondary
        }
    }

    private var memoryText: String {
        let gib = Double(session.config.memoryMiB) / 1024
        return gib == gib.rounded() ? "\(Int(gib)) GiB" : String(format: "%.1f GiB", gib)
    }

    // MARK: - actions

    private func toggleUSB(_ device: USBDeviceList.Device, attach: Bool) {
        Task {
            if attach {
                await session.attachUSB(device.selector)
            } else if let id = session.attachedUSB[device.selector.id] {
                await session.detachUSB(id: id)
            }
        }
    }

    /// QMP `screendump` (PNG) into ~/Pictures. Success is reported in the
    /// status bar rather than with an alert, which would steal the keyboard
    /// from the guest; failures still go through `lastError`.
    private func takeScreenshot() async {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = pictures.appendingPathComponent("Alcove Screenshot \(session.name) \(formatter.string(from: Date())).png")
        guard await session.screenshot(to: url) else { return }
        screenshotNotice = url
        screenshotNoticeTask?.cancel()
        screenshotNoticeTask = Task {
            try? await Task.sleep(for: Self.screenshotNoticeDuration)
            guard !Task.isCancelled, screenshotNotice == url else { return }
            screenshotNotice = nil
        }
    }

    /// Fit the window to the guest surface (1 guest pixel = 1 point, scaled
    /// down to fit the screen) until the user resizes the window by hand.
    private func guestResolutionChanged(width: Int, height: Int) {
        guestSize = (width, height)
        guard !userResized, width > 0, height > 0, let window else { return }
        var content = CGSize(width: CGFloat(width), height: CGFloat(height) + statusBarHeight)
        if let screen = window.screen ?? NSScreen.main {
            let available = screen.visibleFrame
            let chrome = window.frame.height - (window.contentView?.frame.height ?? 0)
            let maxWidth = available.width - 24
            let maxHeight = available.height - chrome - 24
            let scale = min(1, maxWidth / CGFloat(width), maxHeight / (CGFloat(height) + statusBarHeight))
            if scale < 1 {
                content = CGSize(width: (CGFloat(width) * scale).rounded(.down),
                                 height: (CGFloat(height) * scale).rounded(.down) + statusBarHeight)
            }
        }
        window.setContentSize(content)
        // setContentSize keeps the top-left corner, so a taller window can hang
        // off the bottom of the screen; constrainFrameRect only pins the title
        // bar, so move the whole frame back inside the visible area.
        if let screen = window.screen ?? NSScreen.main {
            let available = screen.visibleFrame
            var frame = window.frame
            frame.origin.x = min(max(frame.minX, available.minX), max(available.minX, available.maxX - frame.width))
            frame.origin.y = min(max(frame.minY, available.minY), max(available.minY, available.maxY - frame.height))
            if frame != window.frame {
                window.setFrame(frame, display: true)
            }
        }
    }
}
