import Foundation

/// Typed wrappers for the QMP commands Alcove uses. Argument names come from
/// the qapi schema of the pinned QEMU (build/qemu-src/qapi/*.json).
extension QMPClient {
    // MARK: run state (qapi/run-state.json, misc.json, machine.json, control.json)

    public struct Status: Sendable, Equatable {
        public let running: Bool
        /// `RunState` name: running, paused, shutdown, prelaunch, inmigrate, ...
        public let state: String
    }

    /// `query-status` (qapi/run-state.json).
    public func queryStatus() async throws -> Status {
        let r = try await execute("query-status")
        guard let running = r["running"]?.boolValue, let state = r["status"]?.stringValue else {
            throw QMPError.unexpectedReturn(command: "query-status", value: r)
        }
        return Status(running: running, state: state)
    }

    /// `stop`: pause all vCPUs (qapi/misc.json).
    public func stop() async throws { _ = try await execute("stop") }
    /// `cont`: resume (qapi/misc.json).
    public func cont() async throws { _ = try await execute("cont") }
    /// `system_powerdown`: ACPI/PSCI power button (qapi/machine.json).
    public func systemPowerdown() async throws { _ = try await execute("system_powerdown") }
    /// `system_reset` (qapi/machine.json).
    public func systemReset() async throws { _ = try await execute("system_reset") }
    /// `quit`: terminate QEMU (qapi/control.json).
    public func quit() async throws { _ = try await execute("quit") }

    // MARK: block devices (qapi/block.json, block-core.json)

    public struct BlockDevice: Sendable, Equatable {
        public let device: String
        public let qdev: String?
        public let removable: Bool
        public let file: String?
        public let trayOpen: Bool?
    }

    /// `query-block` (qapi/block-core.json): drives created with `-drive`.
    public func queryBlock() async throws -> [BlockDevice] {
        let r = try await execute("query-block")
        guard let list = r.arrayValue else { throw QMPError.unexpectedReturn(command: "query-block", value: r) }
        return list.map { b in
            BlockDevice(device: b["device"]?.stringValue ?? "", qdev: b["qdev"]?.stringValue,
                        removable: b["removable"]?.boolValue ?? false,
                        file: b["inserted"]?["file"]?.stringValue, trayOpen: b["tray_open"]?.boolValue)
        }
    }

    /// `query-named-block-nodes` (qapi/block-core.json): node names usable for snapshots.
    public func queryNamedBlockNodeNames() async throws -> [String] {
        let r = try await execute("query-named-block-nodes", arguments: ["flat": true])
        guard let list = r.arrayValue else { throw QMPError.unexpectedReturn(command: "query-named-block-nodes", value: r) }
        return list.compactMap { $0["node-name"]?.stringValue }
    }

    /// `blockdev-change-medium` (qapi/block.json): insert `filename` into the removable device `id`.
    public func changeMedium(deviceID: String, filename: String, format: String = "raw") async throws {
        _ = try await execute("blockdev-change-medium", arguments: ["id": .string(deviceID), "filename": .string(filename), "format": .string(format)])
    }

    /// `eject` (qapi/block.json).
    public func eject(deviceID: String, force: Bool = false) async throws {
        _ = try await execute("eject", arguments: ["id": .string(deviceID), "force": .bool(force)])
    }

    // MARK: devices (qapi/qdev.json)

    /// `device_add` with arbitrary properties.
    public func deviceAdd(driver: String, id: String, bus: String? = nil, properties: [String: JSON] = [:]) async throws {
        var args = properties
        args["driver"] = .string(driver)
        args["id"] = .string(id)
        if let bus { args["bus"] = .string(bus) }
        _ = try await execute("device_add", arguments: .object(args))
    }

    /// `device_del`. Completion is signalled by the `DEVICE_DELETED` event.
    public func deviceDel(id: String) async throws {
        _ = try await execute("device_del", arguments: ["id": .string(id)])
    }

    /// Pass a host USB device through (`usb-host`, hw/usb/host-libusb.c properties
    /// `vendorid`/`productid`/`hostbus`/`hostaddr`).
    public func attachUSBHost(id: String, vendorID: Int, productID: Int, bus: String) async throws {
        try await deviceAdd(driver: "usb-host", id: id, bus: bus,
                            properties: ["vendorid": .int(Int64(vendorID)), "productid": .int(Int64(productID))])
    }

    // MARK: display (qapi/ui.json)

    public enum ImageFormat: String, Sendable { case ppm, png }

    /// `screendump`: write the current frame to `filename`.
    public func screendump(filename: String, format: ImageFormat = .png) async throws {
        _ = try await execute("screendump", arguments: ["filename": .string(filename), "format": .string(format.rawValue)], timeout: .seconds(60))
    }

    // MARK: snapshots (qapi/migration.json: snapshot-save / snapshot-load / snapshot-delete; qapi/job.json)

    public struct Snapshot: Sendable, Equatable {
        public let tag: String
        public let vmStateSize: Int
        public let dateSeconds: Int
    }

    /// Run a snapshot job to completion: start it, wait for `JOB_STATUS_CHANGE`
    /// concluded, read the error from `query-jobs`, then `job-dismiss`.
    private func runSnapshotJob(_ command: String, tag: String, vmstate: String?, devices: [String], timeout: Duration) async throws {
        let jobID = "alcove-\(command)-\(UUID().uuidString.prefix(8))"
        var args: [String: JSON] = ["job-id": .string(jobID), "tag": .string(tag), "devices": .array(devices.map(JSON.string))]
        if let vmstate { args["vmstate"] = .string(vmstate) }
        let signal = jobConcludedSignal(id: jobID)
        do {
            _ = try await execute(command, arguments: .object(args))
        } catch {
            cancelJobSignal(id: jobID)
            throw error
        }
        try await awaitJobConcluded(signal, id: jobID, timeout: timeout)
        let jobs = try await execute("query-jobs")
        let info = jobs.arrayValue?.first { $0["id"]?.stringValue == jobID }
        let error = info?["error"]?.stringValue
        _ = try? await execute("job-dismiss", arguments: ["id": .string(jobID)])
        if let error { throw QMPError.job(id: jobID, error: error) }
    }

    /// `snapshot-save`: internal qcow2 snapshot including vCPU/device state
    /// (`vmstate` and `devices` are block node names).
    public func snapshotSave(tag: String, vmstate: String, devices: [String], timeout: Duration = .seconds(600)) async throws {
        try await runSnapshotJob("snapshot-save", tag: tag, vmstate: vmstate, devices: devices, timeout: timeout)
    }

    /// `snapshot-load`: restore a snapshot; the VM must be stopped first.
    public func snapshotLoad(tag: String, vmstate: String, devices: [String], timeout: Duration = .seconds(600)) async throws {
        try await runSnapshotJob("snapshot-load", tag: tag, vmstate: vmstate, devices: devices, timeout: timeout)
    }

    /// `snapshot-delete`.
    public func snapshotDelete(tag: String, devices: [String], timeout: Duration = .seconds(600)) async throws {
        try await runSnapshotJob("snapshot-delete", tag: tag, vmstate: nil, devices: devices, timeout: timeout)
    }

    // MARK: migration to file (suspend to disk) (qapi/migration.json)

    /// `migrate` to `uri` (e.g. `file:/path` or `exec:cat > path`) and poll
    /// `query-migrate` until completed. The VM is left stopped afterwards.
    public func migrate(uri: String, timeout: Duration = .seconds(600)) async throws {
        _ = try await execute("migrate", arguments: ["uri": .string(uri)])
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            let info = try await execute("query-migrate")
            switch info["status"]?.stringValue {
            case "completed": return
            case "failed", "cancelled":
                throw QMPError.job(id: "migrate", error: info["error-desc"]?.stringValue ?? (info["status"]?.stringValue ?? "failed"))
            default: try await Task.sleep(for: .milliseconds(200))
            }
        }
        throw QMPError.timeout("migrate")
    }

    // MARK: input (qapi/ui.json input-send-event), an alternative to the display socket

    /// Send key press+release through QMP using a QKeyCode name (e.g. "ret").
    public func sendKey(qcode: String, down: Bool) async throws {
        let ev: JSON = ["type": "key", "data": ["down": .bool(down), "key": ["type": "qcode", "data": .string(qcode)]]]
        _ = try await execute("input-send-event", arguments: ["events": [ev]])
    }
}
