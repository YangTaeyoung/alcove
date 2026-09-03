import Foundation

/// A child process (QEMU or swtpm) with its output captured to a log file
/// and an awaitable exit.
public final class ChildProcess: @unchecked Sendable {
    public enum ProcessError: Error, Equatable { case launchFailed(String) }

    private let process = Process()
    private let lock = NSLock()
    private var exitContinuations: [UUID: CheckedContinuation<Int32?, Never>] = [:]
    private var exitStatus: Int32?
    public let logURL: URL?

    public init(executable: String, arguments: [String], logURL: URL?, environment: [String: String]? = nil) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        self.logURL = logURL
    }

    public var processIdentifier: Int32 { process.processIdentifier }
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return exitStatus == nil && process.isRunning }

    public func start() throws {
        if let logURL {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            if let h = try? FileHandle(forWritingTo: logURL) {
                process.standardOutput = h
                process.standardError = h
            }
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.lock.lock()
            self.exitStatus = p.terminationStatus
            let waiters = Array(self.exitContinuations.values)
            self.exitContinuations.removeAll()
            self.lock.unlock()
            for w in waiters { w.resume(returning: p.terminationStatus) }
        }
        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed("\(error)")
        }
    }

    /// Wait for the process to exit; returns immediately if it already has.
    public func waitForExit() async -> Int32 {
        await waitForExit(timeout: nil) ?? -1
    }

    /// Wait up to `timeout` for the process to exit. Returns nil on timeout.
    public func waitForExit(timeout: Duration?) async -> Int32? {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32?, Never>) in
            lock.lock()
            if let s = exitStatus { lock.unlock(); cont.resume(returning: s); return }
            let token = UUID()
            exitContinuations[token] = cont
            lock.unlock()
            guard let timeout else { return }
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let waiter = self.exitContinuations.removeValue(forKey: token)
                self.lock.unlock()
                waiter?.resume(returning: nil)
            }
        }
    }

    /// SIGTERM.
    public func terminate() { if process.isRunning { process.terminate() } }
    /// SIGKILL.
    public func kill() { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }

    /// Last lines of the log, for error reports.
    public func logTail(lines: Int = 20) -> String {
        guard let logURL, let data = try? Data(contentsOf: logURL) else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }
}
