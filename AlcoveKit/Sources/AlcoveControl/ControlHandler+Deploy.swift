import Foundation
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP

/// The guest folder `vm.deploy` copies into: which folders it accepts and how their paths are written.
enum DeployTarget {
    /// The folder below which a Windows guest keeps deployed apps by default.
    static let defaultRoot = "C:\\alcove-apps"
    /// The owners `fs.stat` reports for a `defaultRoot` that only elevated processes can change.
    static let trustedOwners: Set<String> = ["administrators", "system"]
    /// The file `vm.deploy` writes into every folder it copied to.
    static let marker = ".alcove-deploy"
    static let markerText = "vm.deploy of Alcove copied the files of this folder and replaces them on the next deploy.\n"

    private static let reservedNames: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for n in 1...9 { names.insert("COM\(n)"); names.insert("LPT\(n)") }
        return names
    }()
    private static let invalidCharacters = Set("<>:\"/\\|?*".unicodeScalars)
    private static let profileFolders: Set<String> = ["desktop", "documents", "downloads"]
    private static let posixFolders: Set<String> = ["usr", "etc", "bin", "sbin", "var", "boot", "home", "root", "opt"]

    private static func refusal(_ message: String) -> ControlHandler.ControlError { .failed(message) }

    /// Whether Windows can use `name` as the name of a folder: not empty, `.` or `..`, no trailing dot or space,
    /// none of `<>:"/\|?*`, no control character, and not a device name such as `CON` or `COM1` with or without an extension.
    static func isWindowsName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", let last = name.unicodeScalars.last, last != ".", last != " " else { return false }
        guard !name.unicodeScalars.contains(where: { $0.value < 0x20 || invalidCharacters.contains($0) }) else { return false }
        let stem = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
        return !reservedNames.contains(stem.trimmingCharacters(in: .whitespaces).uppercased())
    }

    /// Whether a host file or folder called `name` would take the place of the marker in a guest folder. For a
    /// Windows guest the name is compared without its trailing dots and spaces and without regard to case.
    static func isMarker(_ name: String, windows: Bool) -> Bool {
        var given = name.precomposedStringWithCanonicalMapping
        guard windows else { return given == marker }
        while let last = given.last, last == "." || last == " " { given.removeLast() }
        return given.lowercased() == marker
    }

    /// Whether `segment` has a `~` followed by a digit, the form of a Windows short name such as `PROGRA~1`.
    static func looksLikeShortName(_ segment: String) -> Bool {
        let scalars = Array(segment.unicodeScalars)
        return scalars.indices.dropLast().contains { scalars[$0] == "~" && ("0"..."9").contains(scalars[$0 + 1]) }
    }

    /// Whether `name` can be the last segment of the default guest folder: a name Windows can use that does not look
    /// like a short name.
    static func isDefaultName(_ name: String) -> Bool { isWindowsName(name) && !looksLikeShortName(name) }

    /// The default guest folder for a host file or directory called `name`.
    static func defaultDirectory(named name: String) throws -> String {
        guard isWindowsName(name) else { throw refusal("pass guestDir; '\(name)' cannot be used as a folder name") }
        guard !looksLikeShortName(name) else {
            throw refusal("pass guestDir; '\(name)' has the form of a Windows short name and cannot be used as a folder name")
        }
        return defaultRoot + "\\" + name
    }

    /// `requested` written the guest's way, without repeated or trailing separators. Throws for a path that is not absolute,
    /// has a `.` or `..` segment, is a filesystem root, or is a system or profile folder; on Windows also for a device
    /// path, the administrative share of a drive on any server, a server, share or folder name Windows cannot use, a
    /// short name, and `defaultRoot` itself. `example` is the folder the refusal suggests.
    static func directory(_ requested: String, windows: Bool, example: String) throws -> String {
        func fail(_ reason: String) -> ControlHandler.ControlError { refusal("guestDir '\(requested)' \(reason) such as \(example)") }
        func unusable(_ name: String) -> String { "has the segment '\(name)', which Windows cannot use as a folder name; pass a plain folder path" }
        let relative = windows ? "is not an absolute path; pass a full path" : "is not an absolute path of this guest; pass a full path"
        let prefix: String
        let segments: [String]
        if windows {
            let text = requested.replacingOccurrences(of: "/", with: "\\")
            let scalars = Array(text.unicodeScalars.prefix(3))
            if text.hasPrefix("\\\\") {
                let parts = text.dropFirst(2).split(separator: "\\").map(String.init)
                guard !text.dropFirst(2).hasPrefix("\\") else { throw fail(relative) }
                if parts.first == "?" || parts.first == "." {
                    throw refusal("device paths such as \\\\?\\ cannot be used; pass a drive or share path")
                }
                guard parts.count >= 2 else { throw fail(relative) }
                if isDriveShare(parts[1]) {
                    throw refusal("administrative shares such as \\\\host\\C$ cannot be used; pass the drive path")
                }
                if let bad = parts.prefix(2).first(where: { !isWindowsName($0) }) { throw fail(unusable(bad)) }
                prefix = "\\\\" + parts[0] + "\\" + parts[1]
                segments = Array(parts.dropFirst(2))
            } else if scalars.count == 3, scalars[0].isASCII, scalars[0].properties.isAlphabetic, scalars[1] == ":", scalars[2] == "\\" {
                prefix = String(text.prefix(2))
                segments = text.dropFirst(3).split(separator: "\\").map(String.init)
            } else {
                throw fail(relative)
            }
        } else {
            guard requested.hasPrefix("/"), !requested.contains("\\") else { throw fail(relative) }
            prefix = ""
            segments = requested.split(separator: "/").map(String.init)
        }
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { throw fail("has a '.' or '..' segment; pass the folder's full path") }
        if windows, let bad = segments.first(where: { !isWindowsName($0) }) { throw fail(unusable(bad)) }
        if windows, let short = segments.first(where: looksLikeShortName) {
            throw refusal("guestDir '\(requested)' has the short name '\(short)'; pass the long path")
        }
        guard !segments.isEmpty else { throw fail("is a filesystem root; pass a folder below it") }
        let folded = segments.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        if windows {
            guard !isWindowsSystemFolder(folded) else { throw fail("is a system or profile folder; pass a folder of its own") }
            let directory = prefix + "\\" + segments.joined(separator: "\\")
            guard directory.precomposedStringWithCanonicalMapping.lowercased() != defaultRoot.lowercased() else {
                throw fail("holds every deployed app; pass a folder below it")
            }
            return directory
        }
        let single = folded.count == 1 && (posixFolders.contains(folded[0]) || folded[0].hasPrefix("lib"))
        guard !single, !(folded.count == 2 && folded[0] == "home") else { throw fail("is a system or home folder; pass a folder of its own") }
        return "/" + segments.joined(separator: "/")
    }

    /// Whether `share` is the administrative share of a drive: one ASCII letter followed by `$`.
    private static func isDriveShare(_ share: String) -> Bool {
        let scalars = Array(share.unicodeScalars)
        return scalars.count == 2 && scalars[0].isASCII && scalars[0].properties.isAlphabetic && scalars[1] == "$"
    }

    /// Whether the lower-case `segments` below a drive or share name the Windows folder or one below it, a `Program Files`
    /// folder itself, `ProgramData` itself or the agent's folder in it, `Users`, a profile, or a profile's Desktop,
    /// Documents, Downloads or anything in its AppData.
    private static func isWindowsSystemFolder(_ segments: [String]) -> Bool {
        switch segments[0] {
        case "windows": return true
        case "programdata": return segments.count == 1 || segments[1] == "alcove"
        case "users":
            guard segments.count >= 3 else { return true }
            return segments[2] == "appdata" || (segments.count == 3 && profileFolders.contains(segments[2]))
        default: return segments.count == 1 && segments[0].hasPrefix("program files")
        }
    }

    /// Whether `directory` lies below `defaultRoot`.
    static func isUnderDefaultRoot(_ directory: String) -> Bool {
        ControlHandler.isPath(directory, under: defaultRoot, windows: true)
    }

    /// Whether the guest path `path` is absolute: on Windows it starts with a separator or a drive letter, on other
    /// guests with `/`.
    static func isAbsolute(_ path: String, windows: Bool) -> Bool {
        if path.hasPrefix("/") { return true }
        guard windows else { return false }
        if path.hasPrefix("\\") { return true }
        let scalars = Array(path.unicodeScalars.prefix(2))
        return scalars.count == 2 && scalars[1] == ":" && scalars[0].isASCII && scalars[0].properties.isAlphabetic
    }

    /// The segments of the relative guest path `path`, which `/` separates, and on Windows `\` as well.
    private static func segments(of path: String, windows: Bool) -> [String] {
        path.split(whereSeparator: { $0 == "/" || (windows && $0 == "\\") }).map(String.init)
    }

    /// Whether the relative guest path `path` has a `.` or `..` segment.
    static func leavesFolder(_ path: String, windows: Bool) -> Bool {
        segments(of: path, windows: windows).contains { $0 == "." || $0 == ".." }
    }

    /// The first segment of the relative Windows guest path `path` that Windows cannot use as a file or folder name,
    /// such as `.. `, `x.` or `NUL`; nil when it has none.
    static func unusableSegment(of path: String) -> String? {
        segments(of: path, windows: true).first { !isWindowsName($0) }
    }
}

/// `vm.deploy`: copies a host file or directory into a guest folder, optionally runs an installer and launches a program.
/// Built on the agent's `proc.*`, `fs.*`, `exec.run` and `app.launch` operations.
extension ControlHandler {
    static let defaultDeployWaitSeconds = 20.0
    static let installTimeoutMilliseconds = 900_000
    /// The installer exit code that means success with a restart pending.
    static let installRestartCode = 3010

    private struct InstallPlan {
        let msi: Bool
        let file: String
        let args: [JSON]
    }

    private struct LaunchPlan {
        let exe: String
        var fields: [String: JSON]
    }

    private struct DeployPlan {
        let source: URL
        let isDirectory: Bool
        let guestDir: String
        let windows: Bool
        let killRunning: Bool
        let waitMs: Int
        let install: InstallPlan?
        let launch: LaunchPlan?

        var separator: String { windows ? "\\" : "/" }
        func path(_ relative: String) -> String { ControlHandler.guestPath(relative, in: guestDir, windows: windows) }
    }

    /// Checks the parameters, the host path, the names of the host files and the guest folder's path without asking the
    /// guest, then runs the deploy when no other deploy to the VM is running.
    func deploy(_ params: JSON) async throws -> JSON {
        let given = try string(params, "path")
        guard given.hasPrefix("/") else { throw ControlError.failed("pass an absolute host path") }
        var requestedDir: String?
        if let value = params["guestDir"], value != .null {
            guard let text = value.stringValue, !text.isEmpty else { throw ControlError.missing("guestDir") }
            requestedDir = text
        }
        let killRunning = try optional(params, "killRunning", .boolean)?.boolValue ?? true
        let waitMs = try waitWindowMilliseconds(params, default: ControlHandler.defaultDeployWaitSeconds)
        let install = try installPlan(params["install"])
        let launching = try launchPlan(params["launch"])

        let source = URL(fileURLWithPath: given).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw ControlError.failed("'\(given)' does not exist on the host; check the path")
        }
        let t = try await running(params)
        let windows = await t.guestOS() == .windows
        let relative = [("install.file", install?.file, "run"), ("launch.exe", launching?.exe, "start")].compactMap { field, path, verb in
            path.flatMap { DeployTarget.isAbsolute($0, windows: windows) ? nil : (field, $0, verb) }
        }
        for (field, path, verb) in relative where DeployTarget.leavesFolder(path, windows: windows) {
            throw ControlError.failed("\(field) must stay inside guestDir; pass an absolute path to \(verb) something else")
        }
        if windows {
            for (field, path, _) in relative {
                guard let segment = DeployTarget.unusableSegment(of: path) else { continue }
                throw ControlError.failed("'\(segment)' in \(field) cannot be used as a file or folder name on Windows")
            }
        }
        let names = isDirectory.boolValue ? (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? [] : [source.lastPathComponent]
        if names.contains(where: { DeployTarget.isMarker($0, windows: windows) }) {
            throw ControlError.failed("a file named \(DeployTarget.marker) cannot be deployed, vm.deploy keeps its own file under that name; rename the file")
        }
        if windows, !isDirectory.boolValue, !DeployTarget.isWindowsName(source.lastPathComponent.precomposedStringWithCanonicalMapping) {
            throw ControlError.failed("'\(source.lastPathComponent)' cannot be used as a file name on Windows; rename the file")
        }
        let base = (isDirectory.boolValue ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent)
            .precomposedStringWithCanonicalMapping
        let guestDir: String
        if let requestedDir {
            let name = (windows ? DeployTarget.isDefaultName(base) : DeployTarget.isWindowsName(base)) ? base : "app"
            guestDir = try DeployTarget.directory(requestedDir, windows: windows, example: windows ? DeployTarget.defaultRoot + "\\" + name : "/opt/" + name)
        } else {
            let fallback = try DeployTarget.defaultDirectory(named: base)
            guard windows else { throw ControlError.failed("pass guestDir; the default \(fallback) only fits Windows guests") }
            guestDir = fallback
        }
        if isDirectory.boolValue {
            do { try AgentClient.checkSyncSource(source, toGuestPath: guestDir, preserving: [DeployTarget.marker]) }
            catch { throw agentFailure(error, vm: t.name, op: "vm.deploy") }
        }
        let plan = DeployPlan(source: source, isDirectory: isDirectory.boolValue, guestDir: guestDir, windows: windows, killRunning: killRunning,
                              waitMs: waitMs, install: install, launch: launching)
        return try await deployGate.withLock(t.name) {
            try Task.checkCancellation()
            return try await self.run(plan, on: t)
        }
    }

    private func run(_ plan: DeployPlan, on t: VMTarget) async throws -> JSON {
        let op = "vm.deploy"
        let agent = try await tools(t)
        let guestDir = plan.guestDir
        var out: [String: JSON] = ["guestDir": .string(guestDir)]
        do {
            let underRoot = plan.windows && DeployTarget.isUnderDefaultRoot(guestDir)
            let rootExisted = underRoot ? try await checkDefaultRoot(agent) : true
            let marked = try await checkFolder(plan, agent)
            if plan.killRunning { try await stopProcesses(plan, agent) }
            if !marked {
                _ = try await agent.call("fs.write", ["path": .string(plan.path(DeployTarget.marker)),
                                                      "data": .string(Data(DeployTarget.markerText.utf8).base64EncodedString()),
                                                      "truncate": true, "mkdirs": true])
            }
            if !rootExisted { try await checkDefaultRoot(agent) }
            if plan.isDirectory {
                let r = try await agent.syncDirectory(plan.source, toGuestPath: guestDir, deleteExtras: true, preserving: [DeployTarget.marker],
                                                      refusingObstacles: true)
                out["sent"] = .array(r.sent.map(JSON.string)); out["skipped"] = .int(Int64(r.skipped)); out["bytes"] = .int(Int64(r.bytes))
            } else {
                let name = plan.source.lastPathComponent.precomposedStringWithCanonicalMapping
                let r = try await agent.pushFile(plan.source, toGuestPath: plan.path(name), overwrite: true)
                out["sent"] = [.string(name)]; out["skipped"] = 0; out["bytes"] = .int(Int64(r.bytes))
            }
            if let install = plan.install { out["installCode"] = .int(Int64(try await runInstaller(install, plan, agent))) }
        } catch is CancellationError {
            throw CancellationError()
        } catch let obstacle as SyncObstacle {
            let what = obstacle.isLink ? "is a link" : "is not a folder"
            throw ControlError.failed("'\(obstacle.guestPath)' in the guest \(what); remove it or deploy to another folder")
        } catch {
            throw agentFailure(error, vm: t.name, op: op)
        }
        if let launching = plan.launch {
            var request = launching.fields
            let exe = plan.path(launching.exe)
            request["path"] = .string(exe)
            if request["cwd"] == nil { request["cwd"] = .string(guestDir) }
            await addProxyEnvironment(to: &request, vm: t.name)
            do {
                for (key, value) in try await launch(agent, request, waitMs: plan.waitMs).objectValue ?? [:] { out[key] = value }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ControlError.failed("the files were copied to \(guestDir), but starting \(exe) failed: \(agentFailure(error, vm: t.name, op: op))")
            }
        }
        return .object(out)
    }

    // MARK: - parameters

    private nonisolated func installPlan(_ value: JSON?) throws -> InstallPlan? {
        guard let value, value != .null else { return nil }
        guard let kind = value["kind"]?.stringValue, kind == "msi" || kind == "exe", let file = value["file"]?.stringValue, !file.isEmpty else {
            throw ControlError.failed("install needs kind 'msi' or 'exe' and a string 'file'")
        }
        var args: [JSON] = []
        if let list = value["args"], list != .null {
            guard let items = list.arrayValue, items.allSatisfy(isString) else { throw ControlError.failed("install.args must be an array of strings") }
            args = items
        }
        return InstallPlan(msi: kind == "msi", file: file, args: args)
    }

    private nonisolated func launchPlan(_ value: JSON?) throws -> LaunchPlan? {
        guard let value, value != .null else { return nil }
        guard let exe = value["exe"]?.stringValue, !exe.isEmpty else { throw ControlError.failed("launch needs a string 'exe'") }
        var fields: [String: JSON] = [:]
        if let args = value["args"], args != .null {
            guard let items = args.arrayValue, items.allSatisfy(isString) else { throw ControlError.failed("launch.args must be an array of strings") }
            fields["args"] = args
        }
        if let env = value["env"], env != .null {
            guard let entries = env.objectValue, entries.values.allSatisfy(isString) else { throw ControlError.failed("launch.env must be an object of strings") }
            fields["env"] = env
        }
        if let cwd = value["cwd"], cwd != .null {
            guard cwd.stringValue != nil else { throw ControlError.failed("launch.cwd must be a string") }
            fields["cwd"] = cwd
        }
        return LaunchPlan(exe: exe, fields: fields)
    }

    // MARK: - guest paths

    /// `path` when it is absolute in the guest, otherwise `path` below `directory` with the guest's separator.
    static func guestPath(_ path: String, in directory: String, windows: Bool) -> String {
        if DeployTarget.isAbsolute(path, windows: windows) { return path }
        let separator = windows ? "\\" : "/"
        let tail = windows ? path.replacingOccurrences(of: "/", with: "\\") : path
        return directory.hasSuffix(separator) ? directory + tail : directory + separator + tail
    }

    /// Whether `path` lies below `directory`, at a separator; Windows paths compare without regard to case or the kind of separator.
    static func isPath(_ path: String, under directory: String, windows: Bool) -> Bool {
        guard !path.isEmpty else { return false }
        guard windows else { return path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/") }
        func fold(_ s: String) -> String { s.replacingOccurrences(of: "/", with: "\\").precomposedStringWithCanonicalMapping.lowercased() }
        let root = fold(directory)
        return fold(path).hasPrefix(root.hasSuffix("\\") ? root : root + "\\")
    }

    // MARK: - steps

    /// Refuses `DeployTarget.defaultRoot` when the agent reports it as a link, as owned by anyone but the
    /// Administrators group or SYSTEM (also an owner it reports as `unknown`), or with `locked: false`. An agent that
    /// reports no owner leaves the owner unchecked, and one that reports no `locked` leaves the access list unchecked.
    /// Returns whether the root exists; a root that does not exist is accepted.
    @discardableResult
    private func checkDefaultRoot(_ agent: AgentClient) async throws -> Bool {
        let root = DeployTarget.defaultRoot
        let found = try await agent.call("fs.stat", ["path": .string(root)])
        let fix = "restart the guest, so that alcove-agent moves it aside and creates the folder again when it starts, or pass a guestDir outside it"
        let risk = "so another user may have changed what it holds; \(fix)"
        if found["link"]?.boolValue == true {
            throw ControlError.failed("'\(root)' is a link in the guest; \(fix)")
        }
        guard found["exists"]?.boolValue == true else { return false }
        if let owner = found["owner"]?.stringValue, !DeployTarget.trustedOwners.contains(owner) {
            if owner == "unknown" { throw ControlError.failed("'\(root)' in the guest has an owner that alcove-agent cannot read, \(risk)") }
            let who = owner == "user" ? "a user" : owner
            throw ControlError.failed("'\(root)' in the guest belongs to \(who), not to Administrators or SYSTEM, \(risk)")
        }
        if found["locked"]?.boolValue == false {
            throw ControlError.failed("'\(root)' in the guest is not locked against other users, \(risk)")
        }
        return true
    }

    /// Accepts the guest folder when it does not exist, is empty, lies below the default root or holds the deploy marker
    /// as a plain file, and returns whether it holds that marker. A folder the agent reports as a link is refused, and
    /// so is a marker path that holds a link or a folder; the marker path is read with one `fs.stat` for every folder
    /// that is not refused before.
    private func checkFolder(_ plan: DeployPlan, _ agent: AgentClient) async throws -> Bool {
        let guestDir = plan.guestDir
        let found = try await agent.call("fs.stat", ["path": .string(guestDir)])
        guard found["link"]?.boolValue != true else {
            throw ControlError.failed("'\(guestDir)' is a link in the guest; pass the folder it points to")
        }
        let exists = found["exists"]?.boolValue == true
        guard !exists || found["dir"]?.boolValue == true else {
            throw ControlError.failed("'\(guestDir)' is a file in the guest; pass a folder as guestDir")
        }
        let markerPath = plan.path(DeployTarget.marker)
        let marker = try await agent.call("fs.stat", ["path": .string(markerPath)])
        guard marker["dir"]?.boolValue != true, marker["link"]?.boolValue != true else {
            throw ControlError.failed("'\(markerPath)' is not a plain file; remove it or deploy to another folder")
        }
        if marker["exists"]?.boolValue == true { return true }
        guard exists else { return false }
        if plan.windows, DeployTarget.isUnderDefaultRoot(guestDir) { return false }
        let listing = try await agent.call("fs.list", ["path": .string(guestDir)])
        guard (listing["entries"]?.arrayValue ?? []).isEmpty, listing["truncated"]?.boolValue != true else {
            let hint = plan.windows ? ", or one under \(DeployTarget.defaultRoot)" : ""
            throw ControlError.failed("'\(guestDir)' already holds files that Alcove did not deploy; choose an empty or new folder\(hint)")
        }
        return false
    }

    /// The processes whose executable lies below the guest folder.
    private func processes(_ plan: DeployPlan, _ agent: AgentClient) async throws -> [JSON] {
        let list = try await agent.call("proc.list")["procs"]?.arrayValue ?? []
        return list.filter { ControlHandler.isPath($0["path"]?.stringValue ?? "", under: plan.guestDir, windows: plan.windows) }
    }

    /// The process id of the agent: the parent of a shell the agent starts.
    private func agentProcessID(_ plan: DeployPlan, _ agent: AgentClient) async -> Int? {
        guard let r = try? await agent.call("exec.run", ["cmd": .string(GuestRecipes.parentProcessID(windows: plan.windows)), "timeout_ms": 30_000],
                                            timeout: .seconds(45)),
              r["code"]?.intValue == 0, r["timed_out"]?.boolValue != true else { return nil }
        return Int((r["stdout"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Kills the process trees running from the guest folder and waits until none is left; fails when one survives `processExitTimeout`.
    /// Nothing is killed when the agent's own process cannot be told, or when the agent or one of its ancestors runs from the folder.
    private func stopProcesses(_ plan: DeployPlan, _ agent: AgentClient) async throws {
        let all = try await agent.call("proc.list")["procs"]?.arrayValue ?? []
        var running = all.filter { ControlHandler.isPath($0["path"]?.stringValue ?? "", under: plan.guestDir, windows: plan.windows) }
        guard !running.isEmpty else { return }
        guard let own = await agentProcessID(plan, agent) else {
            throw ControlError.failed("vm.deploy could not find the guest agent's own process, so it stopped nothing under '\(plan.guestDir)'; "
                                      + "stop the running copies with vm.process.kill, or pass killRunning: false")
        }
        var parents: [Int: Int] = [:]
        for process in all { if let pid = process["pid"]?.intValue, let parent = process["ppid"]?.intValue { parents[pid] = parent } }
        var protected: Set<Int> = []
        var next: Int? = own
        while let pid = next, protected.insert(pid).inserted { next = parents[pid] }
        if let kept = running.first(where: { protected.contains($0["pid"]?.intValue ?? -1) }) {
            let name = kept["name"]?.stringValue ?? "a process"
            throw ControlError.failed("the guest agent or a process that started it (\(name), pid \(kept["pid"]?.intValue ?? own)) runs from "
                                      + "'\(plan.guestDir)'; pass another guestDir")
        }
        for process in running {
            guard let pid = process["pid"] else { continue }
            do { _ = try await agent.call("proc.kill", ["pid": pid, "tree": true]) } catch AgentClient.AgentError.remote { continue }
        }
        let deadline = ContinuousClock.now + UITiming.processExitTimeout
        while true {
            running = try await processes(plan, agent)
            guard let survivor = running.first else { return }
            if ContinuousClock.now >= deadline {
                let name = survivor["name"]?.stringValue ?? "a process"
                let pid = survivor["pid"]?.intValue.map { " (pid \($0))" } ?? ""
                throw ControlError.failed("\(name)\(pid) under '\(plan.guestDir)' is still running after vm.deploy tried to stop it; "
                                          + "stop it with vm.process.kill or pass another guestDir")
            }
            try await Task.sleep(for: UITiming.processPoll)
        }
    }

    /// Runs the installer without a shell and returns its exit code; a code other than 0 and `installRestartCode`, or a timeout, fails.
    private func runInstaller(_ install: InstallPlan, _ plan: DeployPlan, _ agent: AgentClient) async throws -> Int {
        let file = plan.path(install.file)
        let argv: [JSON] = install.msi ? ["msiexec.exe", "/i", .string(file), "/qn", "/norestart"] + install.args : [.string(file)] + install.args
        let seconds = ControlHandler.installTimeoutMilliseconds / 1000
        let r = try await agent.call("exec.run", ["argv": .array(argv), "cwd": .string(plan.guestDir),
                                                  "timeout_ms": .int(Int64(ControlHandler.installTimeoutMilliseconds))],
                                     timeout: .seconds(seconds + 15))
        if r["timed_out"]?.boolValue == true {
            throw ControlError.failed("installer '\(file)' did not finish within \(seconds) s and was stopped; run it with vm.exec.start to see where it waits")
        }
        let code = r["code"]?.intValue ?? -1
        guard code == 0 || code == ControlHandler.installRestartCode else {
            let err = (r["stderr"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let said = err.isEmpty ? (r["stdout"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : err
            throw ControlError.failed("installer '\(file)' exited with code \(code)\(said.isEmpty ? "" : ": \(said)"); "
                                      + "fix the installer or its arguments and call vm.deploy again")
        }
        return code
    }
}
