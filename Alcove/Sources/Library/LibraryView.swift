import AppKit
import SwiftUI
import AlcoveEngine

/// The VM library: every bundle in the VM directory with its state and quick
/// actions. Double-click (or Open) shows the VM window.
struct LibraryView: View {
    static let windowID = "library"

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    private let controlServer = AppControlServer.shared
    @State private var selection: String?
    @State private var settingsFor: VMSession?
    @State private var snapshotsFor: VMSession?
    @State private var pendingDelete: VMSession?
    @State private var pendingReset: VMSession?
    @State private var pendingForceStop: VMSession?
    @State private var pendingDiscard: VMSession?

    var body: some View {
        @Bindable var model = model
        Group {
            if let issue = model.engineIssue {
                EngineMissingView(issue: issue, bundleCount: model.bundlesAwaitingEngine) { model.locateEngine(); model.reload() }
            } else if model.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Virtual Machines", systemImage: "desktopcomputer")
                } description: {
                    Text("Create one from an installer ISO to get started.")
                } actions: {
                    Button("New Virtual Machine…") { model.newVMRequested = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                list
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .navigationTitle("Virtual Machines")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.newVMRequested = true } label: { Label("New Virtual Machine", systemImage: "plus") }
                    .help("New Virtual Machine… (⌘N)")
                    .disabled(model.engine == nil)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if !model.loadFailures.isEmpty { loadFailureBar }
                if let issue = controlServer.issue { controlServerBar(issue) }
            }
        }
        .sheet(isPresented: $model.newVMRequested) { NewVMSheet() }
        .sheet(item: $settingsFor) { session in
            SettingsSheet(session: session) { renamed in selection = renamed.id }
        }
        .sheet(item: $snapshotsFor) { session in SnapshotsSheet(session: session) }
        .alert("Delete “\(pendingDelete?.name ?? "")”?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { session in
            Button("Delete", role: .destructive) { delete(session) }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("The virtual machine bundle at \(session.bundle.url.path), including its disk images and snapshots, will be moved to the Trash.")
        }
        .confirmationDialog("Reset “\(pendingReset?.name ?? "")”?", isPresented: Binding(get: { pendingReset != nil }, set: { if !$0 { pendingReset = nil } }), presenting: pendingReset) { session in
            Button("Reset", role: .destructive) { perform({ await $0.reset() }, on: session) }
        } message: { _ in
            Text("The guest restarts immediately, like pressing a hardware reset button. Unsaved work in the guest is lost.")
        }
        .confirmationDialog("Force stop “\(pendingForceStop?.name ?? "")”?", isPresented: Binding(get: { pendingForceStop != nil }, set: { if !$0 { pendingForceStop = nil } }), presenting: pendingForceStop) { session in
            Button("Force Stop", role: .destructive) { perform({ await $0.shutdown(force: true) }, on: session) }
        } message: { _ in
            Text("The engine quits without telling the guest, like pulling the power cord. Unsaved work in the guest is lost.")
        }
        .confirmDiscardSuspendState($pendingDiscard) { session in
            perform({ await $0.discardSuspendState() }, on: session)
        }
        .errorAlert($model.pendingError)
        .focusedSceneValue(\.vmCommands, selectedCommands)
    }

    private var list: some View {
        List(model.sessions, selection: $selection) { session in
            VMRow(session: session, onStart: { start(session) }, onShutDown: { shutDown(session) })
                .tag(session.id)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let session = ids.first.flatMap(model.session(id:)) {
                contextMenu(for: session)
            }
        } primaryAction: { ids in
            if let session = ids.first.flatMap(model.session(id:)) { open(session) }
        }
    }

    @ViewBuilder
    private func contextMenu(for session: VMSession) -> some View {
        Button("Open") { open(session) }
        Button(session.isSuspended ? "Resume" : "Start") { start(session) }.disabled(!session.canStart)
        Button("Shut Down") { shutDown(session) }.disabled(!session.state.isActive)
        if session.isSuspended {
            Button("Discard Suspended State…") { pendingDiscard = session }.disabled(!session.canDiscardSuspendState)
        }
        Divider()
        Button("Settings…") { settingsFor = session }
        Button("Snapshots…") { snapshotsFor = session }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.bundle.url]) }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = session }.disabled(session.state.isActive)
    }

    private var loadFailureBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Some bundles could not be loaded", systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
            ForEach(model.loadFailures, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.bar)
    }

    /// Automation (alcove-mcp, alcovectl) cannot reach this app's VMs.
    private func controlServerBar(_ issue: String) -> some View {
        Label(issue, systemImage: "terminal")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.bar)
    }

    private var selectedCommands: VMWindowCommands? {
        guard let session = selection.flatMap(model.session(id:)) else { return nil }
        return VMWindowCommands(session: session,
                                start: { start(session) },
                                run: { operation in perform(operation, on: session) },
                                takeSnapshot: { snapshotsFor = session },
                                reset: { pendingReset = session },
                                forceStop: { pendingForceStop = session },
                                discardSuspendState: { pendingDiscard = session })
    }

    // MARK: - actions

    private func open(_ session: VMSession) {
        openWindow(value: session.id)
    }

    /// Start shows the VM window so the guest (and any start error) is visible.
    private func start(_ session: VMSession) {
        open(session)
        Task { await session.start() }
    }

    private func shutDown(_ session: VMSession) {
        perform({ await $0.shutdown(force: false) }, on: session)
    }

    /// Run an operation and re-route its error to the library's alert, because
    /// the VM window (which normally presents `lastError`) may not be open.
    private func perform(_ operation: @escaping @MainActor (VMSession) async -> Void, on session: VMSession) {
        Task {
            await operation(session)
            if let error = session.lastError {
                session.lastError = nil
                model.pendingError = error
            }
        }
    }

    private func delete(_ session: VMSession) {
        do {
            try model.deleteVM(session)
            if selection == session.id { selection = nil }
        } catch {
            model.pendingError = ErrorText.describe(error)
        }
    }
}

/// One library row: guest OS icon, name, state badge, quick Start/Stop.
private struct VMRow: View {
    let session: VMSession
    let onStart: () -> Void
    let onShutDown: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.config.guestOS.symbolName)
                .font(.title)
                .frame(width: 40, height: 40)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.name).font(.headline)
                HStack(spacing: 8) {
                    StateBadge(state: session.state, suspended: session.isSuspended)
                    Text("\(session.config.cpuCount) CPU · \(memoryText) · \(session.config.guestOS.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            quickAction
        }
        .padding(.vertical, 4)
    }

    private var memoryText: String {
        let gib = Double(session.config.memoryMiB) / 1024
        return gib == gib.rounded() ? "\(Int(gib)) GiB" : String(format: "%.1f GiB", gib)
    }

    @ViewBuilder
    private var quickAction: some View {
        if session.state.isTransitional {
            ProgressView().controlSize(.small).frame(width: 28)
        } else if session.state.isActive {
            Button(action: onShutDown) { Image(systemName: "stop.fill") }
                .buttonStyle(.borderless)
                .help("Shut Down")
        } else {
            Button(action: onStart) { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .help(session.isSuspended ? "Resume" : "Start")
        }
    }
}

/// Colored capsule with the state name.
struct StateBadge: View {
    let state: VMController.State
    var suspended = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .help(help)
    }

    private var text: String {
        if case .stopped = state, suspended { return "Suspended" }
        return state.label
    }

    private var help: String {
        if case .failed(let message) = state { return message }
        return text
    }

    private var color: Color {
        switch state {
        case .stopped: suspended ? .blue : .secondary
        case .starting, .stopping, .suspending: .orange
        case .running: .green
        case .paused: .yellow
        case .failed: .red
        }
    }
}

/// Shown instead of the list while `qemu-system-aarch64` cannot be found.
private struct EngineMissingView: View {
    let issue: String
    let bundleCount: Int
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("QEMU Engine Not Found", systemImage: "engine.combustion.badge.exclamationmark")
        } description: {
            VStack(spacing: 8) {
                Text(issue).font(.callout).multilineTextAlignment(.leading).textSelection(.enabled)
                if bundleCount > 0 {
                    Text(bundleCount == 1 ? "1 virtual machine is waiting for the engine." : "\(bundleCount) virtual machines are waiting for the engine.")
                        .foregroundStyle(.secondary)
                }
            }
        } actions: {
            Button("Search Again", action: retry).buttonStyle(.borderedProminent)
        }
    }
}
