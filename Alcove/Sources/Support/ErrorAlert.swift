import SwiftUI
import AlcoveDisplayProtocol
import AlcoveEngine
import AlcoveQMP

extension View {
    /// Present an alert whenever `message` is non-nil; dismissing clears it.
    func errorAlert(_ message: Binding<String?>, title: String = "Something Went Wrong") -> some View {
        modifier(ErrorAlertModifier(message: message, title: title))
    }
}

private struct ErrorAlertModifier: ViewModifier {
    @Binding var message: String?
    let title: String

    func body(content: Content) -> some View {
        content.alert(title, isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }
}

/// User-facing descriptions for the error types thrown by AlcoveKit and the app.
enum ErrorText {
    /// The engine's hint after a failed resume names the API
    /// (`VMController.savedSessionKeptHint`, internal to AlcoveEngine); the
    /// app offers the same thing as a menu item, so name that instead.
    private static let savedSessionHintAPI = "discard it (discardSuspendState) to boot the VM from scratch"
    private static let savedSessionHintUI = "use “Discard Suspended State” to boot the VM from scratch"

    /// Rewrite engine wording that refers to code rather than to the UI.
    static func humanize(_ message: String) -> String {
        message.replacingOccurrences(of: savedSessionHintAPI, with: savedSessionHintUI)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let e as VMController.ControllerError:
            return describe(e)
        case let e as QMPClient.QMPError:
            return describe(e)
        case let e as VMBundle.BundleError:
            return describe(e)
        case let e as VMConfig.ValidationError:
            return describe(e)
        case let e as EngineLocator.LocateError:
            return describe(e)
        case let e as DisplayConnection.ConnectionError:
            return describe(e)
        case let e as ChildProcess.ProcessError:
            switch e { case .launchFailed(let m): return "The engine process could not be launched.\n\(m)" }
        case let e as AppModel.AppError:
            return describe(e)
        case is CocoaError, is POSIXError, is URLError:
            return (error as NSError).localizedDescription
        case let e as LocalizedError:
            return e.errorDescription ?? "\(e)"
        default:
            return "\(error)"
        }
    }

    private static func describe(_ e: VMController.ControllerError) -> String {
        switch e {
        case .notRunning: "The virtual machine is not running."
        case .alreadyRunning: "The virtual machine is already running."
        case .engineDidNotStart(let m): humanize(m)
        case .qmpUnavailable(let m): "Lost contact with the engine: \(m)"
        case .invalidSnapshotName(let n): "“\(n)” is not a valid snapshot name."
        case .snapshotListFailed(let m): "Could not read the snapshot list.\n\(m)"
        }
    }

    private static func describe(_ e: QMPClient.QMPError) -> String {
        switch e {
        case .notConnected: "Not connected to the engine."
        case .connect(let m): "Could not connect to the engine: \(m)"
        case .disconnected(let m): "The engine connection closed: \(m)"
        case .command(let name, let cls, let desc): "QEMU rejected \(name) (\(cls)): \(desc)"
        case .protocolViolation(let m): "Unexpected reply from QEMU: \(m)"
        case .timeout(let what): "Timed out waiting for \(what)."
        case .job(let id, let err): "Operation \(id) failed: \(err)"
        case .unexpectedReturn(let command, _): "Unexpected result from \(command)."
        }
    }

    private static func describe(_ e: VMBundle.BundleError) -> String {
        switch e {
        case .alreadyExists(let p): "A virtual machine already exists at \(p)."
        case .notABundle(let p): "\(p) is not a virtual machine bundle."
        case .qemuImgFailed(let m): "Creating the disk image failed.\n\(m)"
        case .missingFirmware: "The UEFI firmware is missing from the engine."
        }
    }

    private static func describe(_ e: VMConfig.ValidationError) -> String {
        switch e {
        case .emptyName: "Enter a name for the virtual machine."
        case .invalidName(let n): "“\(n)” cannot be used as a name (no “/”, “:” or “,”)."
        case .cpuCount(let n): "\(n) CPUs is out of range (1–64)."
        case .memory(let m): "\(m) MiB of memory is out of range (256 MiB – 512 GiB)."
        case .noDisks: "The virtual machine needs at least one disk."
        case .duplicateID(let id): "Duplicate device id “\(id)”."
        case .invalidMAC(let mac): "“\(mac)” is not a valid MAC address."
        case .diskSize(let id, let size): "Disk \(id) cannot be \(size) GiB."
        }
    }

    private static func describe(_ e: EngineLocator.LocateError) -> String {
        switch e {
        case .notFound(let searched):
            "qemu-system-aarch64 was not found. Searched:\n" + searched.map { "• \($0)" }.joined(separator: "\n")
                + "\n\nBuild it with scripts/build-qemu.sh or point ALCOVE_QEMU_DIR at an engine directory."
        }
    }

    private static func describe(_ e: DisplayConnection.ConnectionError) -> String {
        switch e {
        case .socket(let n): "Could not create the display socket (errno \(n))."
        case .bind(let path, let n): "Could not bind the display socket at \(path) (errno \(n))."
        case .listen(let n): "Could not listen on the display socket (errno \(n))."
        case .pathTooLong(let p): "The display socket path is too long: \(p)"
        }
    }

    private static func describe(_ e: AppModel.AppError) -> String {
        switch e {
        case .engineUnavailable(let m): m.isEmpty ? "The QEMU engine is not available." : m
        case .vmIsActive(let name): "“\(name)” is running. Shut it down first."
        case .vmRunsInAnotherHost(let name, let host):
            "“\(name)” is running in another Alcove host (\(host)). Stop it there or quit that host first."
        case .vmHeldByEarlierEngine(let name):
            "An engine from an earlier session still holds “\(name)”. Start the VM once to stop that engine, shut it down, then try again."
        case .nameAlreadyUsed(let name): "A virtual machine named “\(name)” already exists."
        case .templateHasClones(let name, let clones):
            "“\(name)” is the template of \(clones.joined(separator: ", ")). Delete the clones first."
        }
    }
}
