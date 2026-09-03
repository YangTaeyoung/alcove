import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AlcoveEngine

/// "New Virtual Machine" form. Creates the bundle in the background, opens
/// the VM window and starts the guest.
struct NewVMSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var name = ""
    @State private var guestOS: VMConfig.GuestOS = .linux
    @State private var isoPath: String?
    @State private var cpuCount = 4
    @State private var memoryGiB = 4.0
    @State private var diskGiB = 32
    @State private var diskBus: VMConfig.DiskBus = .virtioBlk
    @State private var display: VMConfig.DisplayDevice = .virtioGPU
    @State private var creating = false
    @State private var errorMessage: String?

    private let hostCPUs = ProcessInfo.processInfo.activeProcessorCount
    private var hostMemoryGiB: Double { max(1, (Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded(.down)) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Ubuntu 24.04"))
                    Picker("Guest OS", selection: $guestOS) {
                        ForEach(VMConfig.GuestOS.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Installer ISO") {
                        HStack {
                            Text(isoPath.map { ($0 as NSString).lastPathComponent } ?? "None")
                                .foregroundStyle(isoPath == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(isoPath ?? "")
                            Spacer()
                            if isoPath != nil { Button("Remove") { isoPath = nil } }
                            Button("Choose…") { chooseISO() }
                        }
                    }
                }
                Section("Hardware") {
                    Stepper("CPUs: \(cpuCount)", value: $cpuCount, in: 1...max(1, hostCPUs))
                    LabeledContent("Memory") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Slider(value: $memoryGiB, in: 1...hostMemoryGiB, step: 0.5)
                            Text(memoryText).font(.caption).monospacedDigit()
                        }
                    }
                    LabeledContent("Disk") {
                        HStack(spacing: 4) {
                            TextField("Disk", value: $diskGiB, format: .number.grouping(.never))
                                .labelsHidden()
                                .frame(width: 64)
                            Text("GiB")
                            Stepper("Disk size", value: $diskGiB, in: 1...4096, step: 8).labelsHidden()
                        }
                    }
                    Picker("Disk Bus", selection: $diskBus) {
                        Text("virtio-blk (fast; Windows needs the viostor driver)").tag(VMConfig.DiskBus.virtioBlk)
                        Text("NVMe (works out of the box on Windows)").tag(VMConfig.DiskBus.nvme)
                    }
                    Picker("Display", selection: $display) {
                        Text("ramfb (works everywhere, fixed resolution)").tag(VMConfig.DisplayDevice.ramfb)
                        Text("virtio-gpu (dynamic resolution with a guest driver)").tag(VMConfig.DisplayDevice.virtioGPU)
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: guestOS, initial: true) { _, newValue in applyDefaults(for: newValue) }

            Divider()
            HStack {
                if let errorMessage {
                    // Engine errors list the searched paths and the build
                    // command; keep every line readable and copyable.
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(creating)
                Button(action: create) {
                    if creating { ProgressView().controlSize(.small).padding(.horizontal, 12) } else { Text("Create") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
            }
            .padding()
        }
        .frame(width: 520)
        .navigationTitle("New Virtual Machine")
    }

    private var memoryText: String {
        memoryGiB == memoryGiB.rounded() ? "\(Int(memoryGiB)) GiB" : String(format: "%.1f GiB", memoryGiB)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canCreate: Bool {
        !creating && !trimmedName.isEmpty && (try? buildConfig().validate()) != nil
    }

    /// Re-seed hardware fields from `VMConfig.defaults` when the guest OS changes.
    private func applyDefaults(for os: VMConfig.GuestOS) {
        let d = VMConfig.defaults(name: "x", guestOS: os)
        cpuCount = min(d.cpuCount, max(1, hostCPUs))
        memoryGiB = min(Double(d.memoryMiB) / 1024, hostMemoryGiB)
        if let disk = d.disks.first {
            diskGiB = disk.sizeGiB
            diskBus = disk.bus
        }
        display = d.display
    }

    private func buildConfig() -> VMConfig {
        var config = VMConfig.defaults(name: trimmedName, guestOS: guestOS, installISO: isoPath)
        config.cpuCount = cpuCount
        config.memoryMiB = Int(memoryGiB * 1024)
        if !config.disks.isEmpty {
            config.disks[0].sizeGiB = diskGiB
            config.disks[0].bus = diskBus
        }
        config.display = display
        return config
    }

    private func chooseISO() {
        let panel = NSOpenPanel()
        panel.title = "Choose an installer image"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "iso"), .diskImage].compactMap { $0 }
        if panel.runModal() == .OK, let url = panel.url {
            isoPath = url.path
            if trimmedName.isEmpty { name = url.deletingPathExtension().lastPathComponent }
        }
    }

    private func create() {
        guard canCreate else { return }
        creating = true
        errorMessage = nil
        let config = buildConfig()
        Task {
            do {
                let session = try await model.createVM(config)
                openWindow(value: session.id)
                dismiss()
                await session.start()
            } catch {
                errorMessage = ErrorText.describe(error)
                creating = false
            }
        }
    }
}
