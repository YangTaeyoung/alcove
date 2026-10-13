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
    public var vm: String?
    public var variables: [String: String] = [:]
    public var snapshot: String?
    public var socket: String?

    public static let usage = """
    usage: alcovectl run-script FILE [--vm NAME] [--var KEY=VALUE]... [--snapshot NAME] [--socket PATH]

    Replays a script file (made by script.save or alcove_script_save) against a VM without a model and prints one
    line per step, then PASSED or FAILED.

      FILE             the script, a JSON file on this Mac
      --vm NAME        the VM to run against; default: the "vm" of the script
      --var KEY=VALUE  gives ${KEY} in the script the value VALUE; repeatable; VALUE may contain '='
      --snapshot NAME  restores this snapshot before step 1
      --socket PATH    the control socket to use; default: the socket of the Alcove app

    The script runs through the control server at the socket. When no server answers, it runs in this process with
    a headless registry; that is refused while the VM is running under another process (its pidfile is locked),
    and VMs this process started are stopped when the run ends.
    A variable whose name contains password, key, token or secret is printed as KEY=<hidden> and its value is
    removed from the output.
    When a step fails, the screenshot taken at that moment is written next to the script as FILE.failure.png; a
    passing run removes an older file of that name.

    exit status: 0 the script passed, 1 a step failed, 2 the script could not run (bad arguments, unreadable
    script, no VM, refused before step 1; the reason is printed on stderr)
    """

    /// Parses the arguments that follow `run-script`.
    public static func parse(_ argv: [String]) throws -> RunScriptOptions {
        var file: String?
        var vm: String?, snapshot: String?, socket: String?
        var variables: [String: String] = [:]
        var index = 0
        func value(of option: String) throws -> String {
            index += 1
            guard index < argv.count else { throw RunScriptUsageError("\(option) needs a value; see alcovectl run-script --help") }
            return argv[index]
        }
        while index < argv.count {
            let argument = argv[index]
            switch argument {
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
                guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else {
                    throw RunScriptUsageError("--var needs KEY=VALUE, for example --var message=hello; got '\(pair)'")
                }
                variables[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
            default:
                if argument.hasPrefix("--") { throw RunScriptUsageError("unknown option '\(argument)'; see alcovectl run-script --help") }
                guard file == nil else { throw RunScriptUsageError("run-script takes one script file; got '\(file!)' and '\(argument)'") }
                file = argument
            }
            index += 1
        }
        guard let file, !file.isEmpty else { throw RunScriptUsageError("run-script needs the script file; usage: alcovectl run-script FILE [--vm NAME] [--var KEY=VALUE]...") }
        let expanded = (file as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
        return RunScriptOptions(file: URL(fileURLWithPath: absolute).standardized.path, vm: vm, variables: variables, snapshot: snapshot, socket: socket)
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
    /// milliseconds, markers), the error of a failed step, the warning, then `PASSED` or `FAILED`.
    public static func lines(_ reply: JSON, variables: [String: String]) -> [String] {
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
        if let error = reply["error"]?.stringValue { out.append("error: \(error)") }
        if let warning = reply["warning"]?.stringValue { out.append("warning: \(warning)") }
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

    /// Writes the failure screenshot of a failed run next to the script, or removes the file of an earlier run when
    /// the run passed. Returns a sentence when the file could not be written.
    public static func storeFailureImage(_ reply: JSON, scriptFile file: String) -> String? {
        let path = failureImagePath(forScript: file)
        if reply["passed"]?.boolValue == true {
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }
        guard let png = failureImage(reply) else { return nil }
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

/// A blocking client for the control socket.
public enum ControlSocketClient {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    /// Sends one request and waits for its reply. Throws `Failure` with the server's sentence when it answers `ok: false`.
    public static func call(op: String, params: [String: JSON], socketPath: String) throws -> JSON {
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
            throw Failure(description: "cannot send the request to '\(socketPath)'; check that the control server is running")
        }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !reply.contains(10) {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { reply.append(contentsOf: chunk[0..<n]); continue }
            if n < 0, errno == EINTR { continue }
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
