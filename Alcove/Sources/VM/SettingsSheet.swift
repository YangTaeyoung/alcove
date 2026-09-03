import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AlcoveEngine

/// Edit a VM's `VMConfig`. Fields are disabled while the VM is active; Save
/// writes `config.json` (renames move the bundle and hand back a new session).
///
/// While a suspend-to-disk image exists the hardware is locked too: the next
/// start resumes with the configuration saved next to the image
/// (`VMBundle.suspendConfigURL`), so edits would be silently ignored until a
/// later cold boot. The banner offers to discard the saved session instead.
struct SettingsSheet: View {
    let session: VMSession
    /// Called with the replacement session after a rename.
    var onRenamed: ((VMSession) -> Void)? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: VMConfig
    @State private var memoryGiB: Double
    @State private var networkEnabled: Bool
    @State private var forwards: [ForwardRow]
    @State private var errorMessage: String?
    @State private var pendingDiscard: VMSession?

    private let hostCPUs = ProcessInfo.processInfo.activeProcessorCount
    private var hostMemoryGiB: Double { max(1, (Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded(.down)) }

    /// Editable port forward with a stable identity for `ForEach`.
    struct ForwardRow: Identifiable {
        let id = UUID()
        var proto: VMConfig.PortForward.Proto = .tcp
        var hostPort = 2222
        var guestPort = 22

        init() {}
        init(_ f: VMConfig.PortForward) { proto = f.proto; hostPort = f.hostPort; guestPort = f.guestPort }
        var forward: VMConfig.PortForward { VMConfig.PortForward(proto: proto, hostPort: hostPort, guestPort: guestPort) }
    }

    init(session: VMSession, onRenamed: ((VMSession) -> Void)? = nil) {
        self.session = session
        self.onRenamed = onRenamed
        let config = session.config
        _draft = State(initialValue: config)
        _memoryGiB = State(initialValue: Double(config.memoryMiB) / 1024)
        switch config.network {
        case .user(let list):
            _networkEnabled = State(initialValue: true)
            _forwards = State(initialValue: list.map(ForwardRow.init))
        case .none:
            _networkEnabled = State(initialValue: false)
            _forwards = State(initialValue: [])
        }
    }

    /// Nothing can be saved: the engine is running with this configuration.
    private var locked: Bool { session.state.isActive }
    /// Hardware cannot change: a running engine, or a saved session that
    /// must resume on the machine that produced it. The name stays editable.
    private var hardwareLocked: Bool { locked || session.isSuspended }

    var body: some View {
        VStack(spacing: 0) {
            if locked {
                Label("“\(session.name)” is running. Settings can be changed once it is shut down and apply after restart.",
                      systemImage: "lock")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.yellow.opacity(0.15))
            } else if session.isSuspended {
                HStack(alignment: .firstTextBaseline) {
                    Label("“\(session.name)” is suspended. Hardware settings apply after the saved session is discarded or the guest is shut down.",
                          systemImage: "lock")
                        .font(.callout)
                    Spacer()
                    Button("Discard Saved Session…") { pendingDiscard = session }
                        .disabled(!session.canDiscardSuspendState)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.blue.opacity(0.12))
            }
            Form {
                general
                Group {
                    storage
                    displaySection
                    network
                    security
                    usb
                }
                .disabled(hardwareLocked)
            }
            .formStyle(.grouped)
            .disabled(locked)

            Divider()
            HStack {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(locked)
            }
            .padding()
        }
        .frame(width: 560, height: 640)
        .navigationTitle("Settings")
        .confirmDiscardSuspendState($pendingDiscard) { session in
            Task {
                await session.discardSuspendState()
                // The sheet may be open from the library, where nothing
                // observes `lastError`; show it here.
                if let error = session.lastError {
                    session.lastError = nil
                    errorMessage = error
                }
            }
        }
    }

    // MARK: - sections

    private var general: some View {
        Section("General") {
            TextField("Name", text: $draft.name)
            Group {
                Picker("Guest OS", selection: $draft.guestOS) {
                    ForEach(VMConfig.GuestOS.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Stepper("CPUs: \(draft.cpuCount)", value: $draft.cpuCount, in: 1...max(1, hostCPUs))
                LabeledContent("Memory") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Slider(value: $memoryGiB, in: 0.5...hostMemoryGiB, step: 0.5)
                        Text(memoryGiB == memoryGiB.rounded() ? "\(Int(memoryGiB)) GiB" : String(format: "%.1f GiB", memoryGiB))
                            .font(.caption).monospacedDigit()
                    }
                }
            }
            .disabled(hardwareLocked)
        }
    }

    private var storage: some View {
        Section("Storage") {
            ForEach(draft.disks) { disk in
                LabeledContent(disk.fileName) {
                    Text("\(disk.sizeGiB) GiB · \(disk.bus == .nvme ? "NVMe" : "virtio-blk")").foregroundStyle(.secondary)
                }
            }
            ForEach($draft.cdroms) { $cd in
                LabeledContent("CD-ROM \(cd.id)") {
                    HStack {
                        Text(cd.path.map { ($0 as NSString).lastPathComponent } ?? "Empty")
                            .foregroundStyle(cd.path == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(cd.path ?? "")
                        Spacer()
                        if cd.path != nil { Button("Eject") { cd.path = nil } }
                        Button("Choose…") { if let path = chooseISO() { cd.path = path } }
                        Button { draft.cdroms.removeAll { $0.id == cd.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove drive")
                    }
                }
            }
            Button("Add CD-ROM Drive") {
                let used = Set(draft.cdroms.map(\.id))
                var n = draft.cdroms.count
                while used.contains("cd\(n)") { n += 1 }
                draft.cdroms.append(VMConfig.CDROM(id: "cd\(n)", path: nil))
            }
        }
    }

    private var displaySection: some View {
        Section("Display") {
            Picker("Device", selection: $draft.display) {
                Text("ramfb (works everywhere, fixed resolution)").tag(VMConfig.DisplayDevice.ramfb)
                Text("virtio-gpu (dynamic resolution with a guest driver)").tag(VMConfig.DisplayDevice.virtioGPU)
            }
        }
    }

    private var network: some View {
        Section("Network") {
            Picker("Mode", selection: $networkEnabled) {
                Text("Shared (NAT)").tag(true)
                Text("None").tag(false)
            }
            if networkEnabled {
                LabeledContent("Port Forwarding") {
                    VStack(alignment: .leading, spacing: 6) {
                        if forwards.isEmpty {
                            Text("No forwards").foregroundStyle(.secondary)
                        }
                        ForEach($forwards) { $row in
                            HStack(spacing: 6) {
                                Picker("", selection: $row.proto) {
                                    Text("TCP").tag(VMConfig.PortForward.Proto.tcp)
                                    Text("UDP").tag(VMConfig.PortForward.Proto.udp)
                                }
                                .labelsHidden()
                                .frame(width: 70)
                                Text("Host")
                                TextField("Host", value: $row.hostPort, format: .number.grouping(.never))
                                    .frame(width: 60)
                                Image(systemName: "arrow.right")
                                Text("Guest")
                                TextField("Guest", value: $row.guestPort, format: .number.grouping(.never))
                                    .frame(width: 60)
                                Button { forwards.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        Button { forwards.append(ForwardRow()) } label: { Label("Add Forward", systemImage: "plus") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    /// The engine refuses to start with a TPM (`VMController.tpmUnavailableReason`),
    /// so the toggle can only be switched off: a config that already has it on
    /// (an older file, or one edited by hand) must remain fixable here.
    private var security: some View {
        Section("Security") {
            Toggle("Trusted Platform Module (TPM 2.0)", isOn: $draft.tpm)
                .disabled(!draft.tpm)
            Text(VMController.tpmUnavailableReason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var usb: some View {
        Section {
            if draft.usbPassthrough.isEmpty {
                Text("No devices").foregroundStyle(.secondary)
            }
            ForEach(draft.usbPassthrough) { selector in
                HStack {
                    Text(selector.name ?? selector.id)
                    Text(selector.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Button { draft.usbPassthrough.removeAll { $0.id == selector.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Menu("Add Device…") {
                let available = model.usbDevices.devices.filter { d in !draft.usbPassthrough.contains { $0.id == d.selector.id } }
                if available.isEmpty { Text("No other USB devices") }
                ForEach(available) { device in
                    Button(device.displayName) { draft.usbPassthrough.append(device.selector) }
                }
            }
            .onAppear { model.usbDevices.startWatching() }
        } header: {
            Text("USB Passthrough at Boot")
        } footer: {
            Text("Listed devices are handed to the guest when it starts. Devices can also be attached while running from the USB toolbar menu.")
        }
    }

    // MARK: - actions

    private func chooseISO() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose a disc image"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "iso"), .diskImage].compactMap { $0 }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func save() {
        var config = draft
        config.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        config.memoryMiB = Int(memoryGiB * 1024)
        config.network = networkEnabled ? .user(portForwards: forwards.map(\.forward)) : .none
        do {
            try config.validate()
            if config.name != session.config.name {
                let renamed = try model.rename(session, to: config)
                onRenamed?(renamed)
            } else {
                try session.saveConfig(config)
            }
            dismiss()
        } catch {
            errorMessage = ErrorText.describe(error)
        }
    }
}
