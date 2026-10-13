import Foundation
import AlcoveQMP

/// A problem with the arguments of `alcovectl run-script`, or a request for its help text.
public struct RunScriptUsageError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public let isHelp: Bool
    init(_ description: String, isHelp: Bool = false) { self.description = description; self.isHelp = isHelp }
}

/// The arguments of `alcovectl run-script`.
public struct RunScriptOptions: Equatable, Sendable {
    /// Absolute path of the script file.
    public var file: String
    /// The script file as it was given on the command line.
    public var givenFile: String
    public var vm: String?
    public var variables: [String: String] = [:]
    public var snapshot: String?
    public var socket: String?
    public var inProcess = false
    /// Variable names given more than once with `--var`; the last value is used.
    public var repeatedVariables: [String] = []

    public static let usage = """
    usage: alcovectl run-script [--vm NAME] [--var KEY[=VALUE]]... [--snapshot NAME] [--socket PATH] [--in-process] [--] FILE

    Replays a script file (made by script.save or alcove_script_save) against a VM without a model and prints one
    line per step, then PASSED or FAILED.

      FILE             the script, a JSON file on this Mac; after -- it may start with a dash
      --vm NAME        the VM to run against; default: the "vm" of the script
      --var KEY=VALUE  gives ${KEY} in the script the value VALUE; repeatable, the last one wins; VALUE may contain '='
      --var KEY        gives ${KEY} the value of the environment variable KEY
      --snapshot NAME  restores this snapshot before step 1
      --socket PATH    the control socket to use; default: the socket of the Alcove app
      --in-process     with no control server running, runs the script in this process with a headless registry

    The script runs through the control server at the socket (the Alcove app or alcovectl serve). When no server
    answers, the command stops with exit status 2 unless --in-process is given.
    With --in-process the command holds an exclusive lock on the VM (run-script.lock in its bundle) for the whole run
    and refuses when another run-script --in-process holds it or the VM is running under another process. No other
    Alcove process (the app, alcovectl serve) may start that VM during the run: the lock stops only other
    run-script --in-process commands. A VM the run started is stopped when the run ends, also after a failure or a
    signal.
    A value given as KEY=VALUE is visible to other users in the process list; give secrets as --var KEY with the
    value in the environment variable KEY. A variable whose name contains password, key, token or secret is printed
    as KEY=<hidden> and its value is removed from the output.
    When a step fails, the screenshot taken at that moment is written next to the script as FILE.failure.png. The
    file is removed when a run starts, so it exists afterwards only when that run failed and produced a screenshot.
    SIGINT and SIGTERM stop the run; the last line is INTERRUPTED.

    exit status: 0 the script passed, 1 a step failed, 2 the script could not run (bad arguments, unreadable
    script, no VM, no server, refused before step 1; the reason is printed on stderr), 130 interrupted by SIGINT,
    143 interrupted by SIGTERM
    """

    /// Parses the arguments that follow `run-script`.
    public static func parse(_ argv: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> RunScriptOptions {
        var file: String?
        var vm: String?, snapshot: String?, socket: String?
        var variables: [String: String] = [:]
        var repeated: [String] = []
        var inProcess = false
        var optionsEnded = false
        var index = 0
        func value(of option: String) throws -> String {
            index += 1
            guard index < argv.count else { throw RunScriptUsageError("\(option) needs a value; see alcovectl run-script --help") }
            return argv[index]
        }
        while index < argv.count {
            let argument = argv[index]
            if optionsEnded || !argument.hasPrefix("-") || argument == "-" {
                guard file == nil else { throw RunScriptUsageError("run-script takes one script file; got '\(file!)' and '\(argument)'") }
                file = argument
                index += 1
                continue
            }
            switch argument {
            case "--":
                optionsEnded = true
            case "--in-process":
                inProcess = true
            case "--help", "-h":
                throw RunScriptUsageError(usage, isHelp: true)
            case "--vm":
                let name = try value(of: argument)
                guard !name.isEmpty else { throw RunScriptUsageError("--vm needs a VM name; see alcovectl run-script --help") }
                vm = name
            case "--snapshot":
                let name = try value(of: argument)
                guard !name.isEmpty else { throw RunScriptUsageError("--snapshot needs a snapshot name; see alcovectl run-script --help") }
                snapshot = name
            case "--socket":
                let path = try value(of: argument)
                guard !path.isEmpty else { throw RunScriptUsageError("--socket needs a path; see alcovectl run-script --help") }
                socket = path
            case "--var":
                let pair = try value(of: argument)
                let key: String, text: String
                if let equals = pair.firstIndex(of: "=") {
                    key = String(pair[..<equals])
                    text = String(pair[pair.index(after: equals)...])
                } else {
                    key = pair
                    guard let fromEnvironment = environment[pair] else {
                        throw RunScriptUsageError("--var \(pair) needs a value: pass \(pair)=VALUE or set the environment variable \(pair)")
                    }
                    text = fromEnvironment
                }
                guard !key.isEmpty else { throw RunScriptUsageError("--var needs KEY=VALUE, for example --var message=hello; got '\(pair)'") }
                if variables[key] != nil, !repeated.contains(key) { repeated.append(key) }
                variables[key] = text
            default:
                throw RunScriptUsageError("unknown option '\(argument)'; see alcovectl run-script --help, and put -- before a file name that starts with a dash")
            }
            index += 1
        }
        guard let file, !file.isEmpty else { throw RunScriptUsageError("run-script needs the script file; usage: alcovectl run-script FILE [--vm NAME] [--var KEY=VALUE]...") }
        let expanded = (file as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
        return RunScriptOptions(file: URL(fileURLWithPath: absolute).standardized.path, givenFile: file, vm: vm, variables: variables,
                                snapshot: snapshot, socket: socket, inProcess: inProcess, repeatedVariables: repeated)
    }

    /// The sentence that says why the script file cannot be run, or nil when it is a readable file.
    public var unreadableProblem: String? {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: file, isDirectory: &isDirectory), !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: file) {
            return nil
        }
        let resolved = givenFile == file ? "" : " (resolved from '\(givenFile)' in '\(FileManager.default.currentDirectoryPath)')"
        return "cannot read the script '\(file)'\(resolved); check that the file exists and is readable"
    }

    /// The `script.run` request for these options.
    public var params: [String: JSON] {
        var out: [String: JSON] = ["path": .string(file)]
        if let vm { out["name"] = .string(vm) }
        if let snapshot { out["snapshot"] = .string(snapshot) }
        if !variables.isEmpty { out["variables"] = .object(variables.mapValues(JSON.string)) }
        return out
    }
}

/// What `alcovectl run-script` prints and writes.
public enum ScriptReport {
    /// Whether a variable of this name holds a secret: its name contains password, key, token or secret.
    public static func isSecret(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return ["password", "key", "token", "secret"].contains { lowered.contains($0) }
    }

    /// `name=value` for each variable by name, with `<hidden>` in place of the value of a secret; nil without variables.
    public static func variablesLine(_ variables: [String: String]) -> String? {
        guard !variables.isEmpty else { return nil }
        return "variables: " + variables.keys.sorted().map { "\($0)=\(isSecret($0) ? "<hidden>" : variables[$0]!)" }.joined(separator: ", ")
    }

    /// `text` without the values of the secret variables.
    public static func masked(_ text: String, variables: [String: String]) -> String {
        var out = text
        for (name, value) in variables.sorted(by: { $0.value.count > $1.value.count }) where isSecret(name) && !value.isEmpty {
            out = out.replacingOccurrences(of: value, with: "<hidden>")
        }
        return out
    }

    /// The output lines for the reply of `script.run`: one per step (`ok` or `FAIL`, number, label or op,
    /// milliseconds, markers), the error of a failed step, the warning, then `PASSED` or `FAILED`; `INTERRUPTED` and
    /// no error line for a run a signal stopped.
    public static func lines(_ reply: JSON, variables: [String: String], interrupted: Bool = false) -> [String] {
        var out: [String] = []
        for entry in reply["steps"]?.arrayValue ?? [] {
            let number = entry["step"]?.intValue ?? 0
            let ok = entry["ok"]?.boolValue == true
            let name = entry["label"]?.stringValue ?? entry["op"]?.stringValue ?? "step"
            let milliseconds = Int(((entry["seconds"]?.doubleValue ?? 0) * 1000).rounded())
            var markers: [String] = []
            if entry["usedFallback"]?.boolValue == true { markers.append("fallback") }
            if entry["usedAltSelector"]?.boolValue == true { markers.append("alt selector") }
            if entry["positional"]?.boolValue == true { markers.append("positional") }
            let tags = markers.map { " [\($0)]" }.joined()
            out.append("\(ok ? "ok  " : "FAIL") \(number) \(name) \(milliseconds) ms\(tags)")
            if !ok, let error = entry["error"]?.stringValue { out.append("     \(error)") }
        }
        if !interrupted, let error = reply["error"]?.stringValue { out.append("error: \(error)") }
        if let warning = reply["warning"]?.stringValue { out.append("warning: \(warning)") }
        if interrupted { return (out + ["INTERRUPTED"]).map { masked($0, variables: variables) } }
        let seconds = String(format: "%.1f", reply["seconds"]?.doubleValue ?? 0)
        let count = reply["stepsRun"]?.intValue ?? 0
        if reply["passed"]?.boolValue == true {
            out.append("PASSED: \(count) step\(count == 1 ? "" : "s") in \(seconds) s")
        } else {
            let failed = reply["failedStep"]?.intValue.map { "step \($0) failed" } ?? "the run stopped"
            out.append("FAILED: \(failed) after \(seconds) s")
        }
        return out.map { masked($0, variables: variables) }
    }

    /// The PNG of the failure screenshot in the reply of `script.run`.
    public static func failureImage(_ reply: JSON) -> Data? {
        reply["failure"]?["png"]?.stringValue.flatMap { Data(base64Encoded: $0) }
    }

    /// Where the failure screenshot of the script at `file` is written.
    public static func failureImagePath(forScript file: String) -> String { file + ".failure.png" }

    /// Removes the failure screenshot file of the script at `file`.
    public static func removeFailureImage(forScript file: String) {
        try? FileManager.default.removeItem(atPath: failureImagePath(forScript: file))
    }

    /// Replaces the failure screenshot file of the script at `file` by the one of a failed run, and removes it when the
    /// run passed or produced none. Returns a sentence when the file could not be written.
    public static func storeFailureImage(_ reply: JSON, scriptFile file: String) -> String? {
        let path = failureImagePath(forScript: file)
        guard reply["passed"]?.boolValue != true, let png = failureImage(reply) else {
            removeFailureImage(forScript: file)
            return nil
        }
        do {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            return nil
        } catch {
            return "cannot write the failure screenshot '\(path)'; check that the folder of the script is writable"
        }
    }

    /// The VM named by the script at `file`, if it can be read and names one.
    public static func vmName(ofScriptAt file: String) -> String? {
        guard let data = FileManager.default.contents(atPath: file), let script = try? Script.parse(data),
              let vm = script.vm, !vm.isEmpty else { return nil }
        return vm
    }
}

/// The exit status of `alcovectl run-script` for a run a signal stopped.
public enum RunScriptExit {
    public static let passed: Int32 = 0
    public static let failed: Int32 = 1
    public static let couldNotRun: Int32 = 2

    /// 128 plus the signal number for SIGINT and SIGTERM; nil for other signals.
    public static func status(forSignal signal: Int32) -> Int32? {
        signal == SIGINT || signal == SIGTERM ? 128 + signal : nil
    }
}

/// An exclusive advisory lock on a file in a VM bundle, held until `release()` or until the object is gone.
public final class ScriptRunLock: @unchecked Sendable {
    public static let fileName = "run-script.lock"
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// The lock on `fileName` in `bundle`; nil when another descriptor holds it. Throws when the file cannot be opened.
    public static func acquire(in bundle: URL) throws -> ScriptRunLock? {
        let path = bundle.appendingPathComponent(fileName).path
        let descriptor = open(path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else {
            throw Failure(description: "cannot open the lock file '\(path)'; check that the VM bundle is writable")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            if errno == EWOULDBLOCK { return nil }
            throw Failure(description: "cannot lock '\(path)'; check that the VM bundle is on a local volume")
        }
        return ScriptRunLock(descriptor: descriptor)
    }

    public func release() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

/// Lets another thread end a `ControlSocketClient.call` that is waiting for its reply.
public final class ControlCallCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var signalNumber: Int32?

    public init() {}

    /// The signal passed to `cancel`, once it was called.
    public var signal: Int32? { lock.lock(); defer { lock.unlock() }; return signalNumber }

    /// Closes the connection of the call, which makes the server cancel the request; a later call is cancelled at once.
    public func cancel(signal: Int32) {
        lock.lock(); defer { lock.unlock() }
        if signalNumber == nil { signalNumber = signal }
        if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR) }
    }

    fileprivate func attach(_ fd: Int32) {
        lock.lock(); defer { lock.unlock() }
        descriptor = fd
        if signalNumber != nil { shutdown(fd, SHUT_RDWR) }
    }

    fileprivate func detach() {
        lock.lock(); defer { lock.unlock() }
        descriptor = -1
    }
}

/// A blocking client for the control socket.
public enum ControlSocketClient {
    /// The call was ended by `ControlCallCancellation.cancel`.
    public struct Interrupted: Error, Equatable {
        public let signal: Int32
    }

    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    /// Sends one request and waits for its reply. Throws `Failure` with the server's sentence when it answers `ok: false`.
    public static func call(op: String, params: [String: JSON], socketPath: String, cancellation: ControlCallCancellation? = nil) throws -> JSON {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "cannot create a socket; check the open file limit") }
        defer { Darwin.close(fd) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard socketPath.utf8.count <= maxLength else { throw Failure(description: "the socket path '\(socketPath)' is too long; use a shorter --socket path") }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: maxLength + 1) { dst in _ = socketPath.withCString { strncpy(dst, $0, maxLength) } }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw Failure(description: "no control server answers at '\(socketPath)'") }
        cancellation?.attach(fd)
        defer { cancellation?.detach() }
        func checkCancelled() throws {
            if let signal = cancellation?.signal { throw Interrupted(signal: signal) }
        }

        var request = params
        request["id"] = 1
        request["op"] = .string(op)
        var data = try JSON.object(request).serialized()
        data.append(10)
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress! + offset, data.count - offset) }
            if n > 0 { offset += n; continue }
            if n < 0, errno == EINTR { continue }
            try checkCancelled()
            throw Failure(description: "cannot send the request to '\(socketPath)'; check that the control server is running")
        }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !reply.contains(10) {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { reply.append(contentsOf: chunk[0..<n]); continue }
            if n < 0, errno == EINTR { continue }
            try checkCancelled()
            throw Failure(description: "the control server at '\(socketPath)' closed the connection before it answered; check that it is still running")
        }
        let line = reply.prefix(upTo: reply.firstIndex(of: 10)!)
        guard let json = try? JSON.parse(Data(line)) else {
            throw Failure(description: "the control server at '\(socketPath)' sent an answer that is not JSON; check that it is an Alcove control server")
        }
        guard json["ok"]?.boolValue == true else { throw Failure(description: json["error"]?.stringValue ?? "\(op) failed") }
        return json
    }
}
