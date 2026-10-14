import AppKit
import SwiftUI
import AlcoveEngine

/// Application entry point: the VM library window, one window per virtual
/// machine (keyed by session id), the menu bar commands and quit handling.
///
/// The library is a `Window` scene (a single, unique window) rather than a
/// `WindowGroup`: `openWindow(id:)` on a group always creates another window,
/// and a second library would present the shared New VM sheet twice. It is
/// the window shown at launch (see `presentLibraryAtLaunch()`); the app
/// delegate keeps the app running when it is closed.
@main
struct AlcoveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    /// Set once the library has been presented for this launch; see `presentLibraryAtLaunch()`.
    @State private var didPresentLibrary = false
    private let model = AppModel.shared

    var body: some Scene {
        Window("Library", id: LibraryView.windowID) {
            LibraryView()
                .environment(model)
        }
        .defaultSize(width: 560, height: 420)
        // The library is the window the app launches with, kept out of window
        // restoration. `.presented` alone is not enough: SwiftUI honours it only
        // "in the absence of any previously restored scenes", and AppKit keeps
        // state from every quit (the macOS default keeps windows on quit). Once
        // such state exists a launch after a quit with a VM window open showed
        // only that window, and one after a quit with no windows showed nothing
        // at all (verified on macOS 26.6). So the library is also presented
        // explicitly, once per launch, as soon as the scene phase is reported.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .onChange(of: scenePhase, initial: true) { presentLibraryAtLaunch() }
        .commands {
            AlcoveCommands()
        }

        WindowGroup("Virtual Machine", for: String.self) { $sessionID in
            VMWindowView(sessionID: $sessionID)
                .environment(model)
        }
        .defaultSize(width: 1024, height: 800)
        .windowToolbarStyle(.unified)
        // Engines never outlive the app, so a restored VM window could only show
        // a stopped guest — or "Virtual Machine Not Found" when the VM directory
        // differs from the previous run. VM windows are opened from the library.
        .restorationBehavior(.disabled)
    }

    /// Open the library the first time the scene phase is reported for this
    /// launch. `Window` scenes are unique, so this only brings the library
    /// forward when SwiftUI's default launch behavior already presented it.
    private func presentLibraryAtLaunch() {
        guard !didPresentLibrary else { return }
        didPresentLibrary = true
        openWindow(id: LibraryView.windowID)
        openRequestedVMWindow()
    }

    /// Development and test hook: `ALCOVE_OPEN_VM=<name>` opens that VM's
    /// window at launch and `ALCOVE_AUTOSTART=1` also starts it, so a test can
    /// exercise the window without UI scripting. Ignored when unset.
    private func openRequestedVMWindow() {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment["ALCOVE_OPEN_VM"], !name.isEmpty else { return }
        Task { @MainActor in
            for _ in 0..<50 {
                if let session = model.sessions.first(where: { $0.name == name }) {
                    openWindow(value: session.id)
                    if environment["ALCOVE_AUTOSTART"] == "1", session.canStart {
                        await session.start()
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            model.pendingError = "ALCOVE_OPEN_VM is set to “\(name)”, but no virtual machine with that name was found."
        }
    }
}

/// File > New Virtual Machine… and the Virtual Machine menu. The menu acts on
/// the session exposed through `FocusedValues.vmCommands` by the key window.
/// Destructive items (Force Stop, Reset, Discard Suspended State) go through
/// the window's confirmation dialogs, exactly like the toolbar buttons.
struct AlcoveCommands: Commands {
    @FocusedValue(\.vmCommands) private var vm
    @Environment(\.openWindow) private var openWindow
    private let model = AppModel.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Virtual Machine…") {
                openWindow(id: LibraryView.windowID)
                model.requestNewVM()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model.engine == nil)
        }

        CommandMenu("Virtual Machine") {
            Button("Start") { vm?.start() }
                .disabled(!(vm?.session.canStart ?? false))
                .keyboardShortcut("r", modifiers: [.command, .shift])

            if vm?.session.state == .paused {
                Button("Resume") { vm?.run { await $0.resume() } }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            } else {
                Button("Pause") { vm?.run { await $0.pause() } }
                    .disabled(!(vm?.session.canPause ?? false))
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }

            Divider()

            Button("Shut Down") { vm?.run { await $0.shutdown(force: false) } }
                .disabled(!(vm?.session.state.isActive ?? false))
            Button("Force Stop…") { vm?.forceStop() }
                .disabled(!(vm?.session.state.isActive ?? false))
            Button("Reset…") { vm?.reset() }
                .disabled(!(vm?.session.canReset ?? false))
            Button("Suspend") { vm?.run { await $0.suspend() } }
                .disabled(!(vm?.session.canSuspend ?? false))
            Button("Discard Suspended State…") { vm?.discardSuspendState() }
                .disabled(!(vm?.session.canDiscardSuspendState ?? false))

            Divider()

            Button("Take Snapshot…") { vm?.takeSnapshot() }
                .disabled(vm == nil)
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}

/// Launch and quit handling: hosts the automation control socket while the
/// app runs, and with active VMs offers to suspend or shut them all down;
/// before either, the guests of running HTTP captures are restored, for 20 s
/// at most.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        model.refreshDockBadge()
        // Starts the control server unless another server owns the socket.
        let control = AppControlServer.shared
        control.start()
        if let failure = control.startFailure {
            model.pendingError = [model.pendingError, failure].compactMap { $0 }.joined(separator: "\n\n")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppControlServer.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        let active = model.activeSessions
        guard !active.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = active.count == 1
            ? "“\(active[0].name)” is still running."
            : "\(active.count) virtual machines are still running."
        alert.informativeText = "Suspend saves the guests to disk so they resume where they left off on the next start. "
            + "Shut Down presses each guest's power button and waits for it to power off."
        alert.addButton(withTitle: "Suspend All")
        alert.addButton(withTitle: "Shut Down All")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                await AppControlServer.shared.endCaptures()
                await model.suspendAll()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            Task {
                await AppControlServer.shared.endCaptures()
                await model.shutdownAll()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        default:
            return .terminateCancel
        }
    }
}
