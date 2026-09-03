import SwiftUI
import AlcoveEngine

/// qcow2 internal snapshots of the first disk: list, create, restore, delete.
/// Listing works any time; changes need the VM running or paused.
///
/// Errors are presented by the sheet itself: the session records them in
/// `lastError`, which only the VM window observes, and the sheet may have been
/// opened from the library.
struct SnapshotsSheet: View {
    let session: VMSession
    @Environment(\.dismiss) private var dismiss

    @State private var snapshots: [VMController.SnapshotInfo] = []
    @State private var selected: VMController.SnapshotInfo.ID?
    @State private var newName = ""
    @State private var loading = false
    @State private var busy = false
    @State private var pendingRestore: VMController.SnapshotInfo?
    @State private var pendingDelete: VMController.SnapshotInfo?
    @State private var errorMessage: String?
    @FocusState private var nameFieldFocused: Bool

    private var canModify: Bool { session.canModifySnapshots && !busy }
    private var selection: VMController.SnapshotInfo? { snapshots.first { $0.id == selected } }

    var body: some View {
        VStack(spacing: 0) {
            Table(snapshots, selection: $selected) {
                TableColumn("Name", value: \.name)
                TableColumn("Date") { Text($0.date, format: .dateTime.year().month().day().hour().minute()) }
                    .width(min: 140, ideal: 160)
                TableColumn("Size") { Text(ByteCountFormatter.string(fromByteCount: Int64($0.vmStateSize), countStyle: .file)) }
                    .width(min: 70, ideal: 90)
            }
            .overlay {
                if loading {
                    ProgressView()
                } else if snapshots.isEmpty {
                    ContentUnavailableView("No Snapshots", systemImage: "camera.on.rectangle",
                                           description: Text(session.canModifySnapshots ? "Name a snapshot below to save the current state." : "Start the virtual machine to take a snapshot."))
                }
            }

            Divider()
            VStack(spacing: 10) {
                if !session.canModifySnapshots {
                    Label("Snapshots can be taken, restored and deleted while the virtual machine is running or paused.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    TextField("Snapshot name", text: $newName)
                        .focused($nameFieldFocused)
                        .onSubmit(create)
                    Button("New Snapshot", action: create)
                        .disabled(!canModify || newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    Button("Restore…") { pendingRestore = selection }
                        .disabled(!canModify || selection == nil)
                    Button("Delete…") { pendingDelete = selection }
                        .disabled(!canModify || selection == nil)
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .padding()
        }
        .frame(width: 520, height: 400)
        .navigationTitle("Snapshots of \(session.name)")
        .disabled(busy)
        .task { await reload() }
        .onAppear { if canModify { nameFieldFocused = true } }
        .confirmationDialog("Restore “\(pendingRestore?.name ?? "")”?", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }), presenting: pendingRestore) { snapshot in
            Button("Restore", role: .destructive) { Task { await run { await session.restoreSnapshot(snapshot.name) } } }
        } message: { _ in
            Text("The disks and guest memory return to the state saved in the snapshot. Everything changed since then is lost.")
        }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { snapshot in
            Button("Delete", role: .destructive) { Task { await run { await session.deleteSnapshot(snapshot.name) } } }
        } message: { _ in
            Text("The snapshot is removed from the disk image. This cannot be undone.")
        }
        .errorAlert($errorMessage, title: "Snapshot Failed")
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard canModify, !name.isEmpty else { return }
        Task {
            await run { await session.createSnapshot(name) }
            newName = ""
        }
    }

    private func run(_ operation: () async -> Void) async {
        busy = true
        await operation()
        takeSessionError()
        await reload()
        busy = false
    }

    private func reload() async {
        loading = snapshots.isEmpty
        snapshots = await session.snapshots()
        takeSessionError()
        loading = false
        if let selected, !snapshots.contains(where: { $0.id == selected }) { self.selected = nil }
    }

    /// Move an error the session just recorded into this sheet's alert, as
    /// `LibraryView.perform` does, so it is shown wherever the sheet is open.
    /// Called right after the recording operation returns, before any further
    /// suspension, so the VM window's own alert never sees it.
    private func takeSessionError() {
        guard let error = session.lastError else { return }
        session.lastError = nil
        errorMessage = error
    }
}
