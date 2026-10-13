import Foundation
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP

/// The time limits of the steps of `vm.collect_diagnostics`. The steps run at the same time, so the op takes as long as its slowest step.
enum DiagnosticsTiming {
    /// Longest the op waits for the guest tools to be connected before it skips the guest steps.
    nonisolated(unsafe) static var agentWait = Duration.seconds(5)
    nonisolated(unsafe) static var screenshot = Duration.seconds(10)
    /// Longest `windows.json` waits for its turn at the UI helper, and for the helper's answer counted from the start.
    nonisolated(unsafe) static var windowsTurn = Duration.seconds(15)
    nonisolated(unsafe) static var windows = Duration.seconds(30)
    /// Longest `ui-tree.txt` waits for its turn at the UI helper, and for the helper's answer counted from the start.
    nonisolated(unsafe) static var treeTurn = Duration.seconds(40)
    nonisolated(unsafe) static var tree = Duration.seconds(50)
    nonisolated(unsafe) static var processes = Duration.seconds(35)
    /// One event log read; the guest recipe itself stops after 60 s.
    nonisolated(unsafe) static var eventLog = Duration.seconds(80)
    nonisolated(unsafe) static var jobs = Duration.seconds(45)
    nonisolated(unsafe) static var logFiles = Duration.seconds(45)
    nonisolated(unsafe) static var doctor = Duration.seconds(85)
    /// The crash dump list, which is a guest recipe like an event log read.
    nonisolated(unsafe) static var dumpList = Duration.seconds(80)
    /// The whole dump step: the list and every pull.
    nonisolated(unsafe) static var dumps = Duration.seconds(100)
    nonisolated(unsafe) static var recordingFiles = Duration.seconds(30)
}

/// The size limits of a diagnostics bundle.
enum DiagnosticsLimits {
    /// Lines and bytes of the tail of one requested log file; the smaller of the two applies.
    static let logLines = 2000
    static let logBytes = 262_144
    /// Bytes of each stream of one job.
    static let jobBytes = 262_144
    /// Most guest log files one call collects.
    static let maxLogFiles = 20
    /// Most bytes of `trace.jsonl` that are copied: its newest whole lines.
    static let traceBytes = 32 * 1024 * 1024
    /// Most bytes of crash dumps that are pulled, counted by the sizes the guest lists.
    nonisolated(unsafe) static var dumpBudget = 500 * 1024 * 1024
    static let eventLogEntries = 500
    static let treeNodes = 1000
}

/// A step that did not finish within its time limit.
struct DiagnosticsTimeout: Error {}

/// Host file names for names that come from the guest: a single path component without separators, control characters or
/// leading dots, at most `maxBytes` bytes, and different from every name handed out before it (compared without regard to case).
struct DiagnosticsNames {
    static let maxBytes = 100
    private var taken: Set<String> = []

    /// A name for `guestName` (its last path component) that no earlier call returned; `fallback` stands for a name with nothing usable.
    mutating func claim(_ guestName: String, fallback: String) -> String {
        let clean = DiagnosticsNames.clean(guestName, fallback: fallback)
        var candidate = clean
        var number = 1
        while taken.contains(candidate.lowercased()) {
            number += 1
            candidate = DiagnosticsNames.numbered(clean, number)
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    static func clean(_ guestName: String, fallback: String) -> String {
        let last = guestName.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var name = ""
        for scalar in last.unicodeScalars {
            let unusable = scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) || scalar.value == 0x2028 || scalar.value == 0x2029
                || ":*?\"<>|".unicodeScalars.contains(scalar)
            name.unicodeScalars.append(unusable ? "_" : scalar)
        }
        while name.hasPrefix(".") || name.hasPrefix(" ") { name.removeFirst() }
        while name.hasSuffix(".") || name.hasSuffix(" ") { name.removeLast() }
        if name.isEmpty { return fallback }
        var ext = (name as NSString).pathExtension
        if ext.utf8.count > 16 { ext = "" }
        var stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        let suffix = ext.isEmpty ? "" : "." + ext
        while !stem.isEmpty, (stem + suffix).utf8.count > maxBytes { stem.removeLast() }
        return stem.isEmpty ? fallback : stem + suffix
    }

    private static func numbered(_ name: String, _ number: Int) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return "\(name)-\(number)" }
        return "\(String(name.dropLast(ext.count + 1)))-\(number).\(ext)"
    }
}

/// What the steps of one `vm.collect_diagnostics` call found: the failures, the notes and the facts the summary reports.
final class DiagnosticsLog: @unchecked Sendable {
    struct Dump: Sendable {
        let file: String
        let bytes: Int
        let time: String
        var outcome: String
    }

    struct LogCount: Sendable {
        let count: Int
        let atLeast: Bool
        let newest: String?
    }

    struct State: Sendable {
        var failures: [(step: String, sentence: String)] = []
        var notes: [String] = []
        var windows: [JSON]?
        var foreground: String?
        var dumps: [Dump]?
        var logCounts: [String: LogCount] = [:]
        var failedJobs: [(job: String, code: Int)]?
        var processes: [JSON]?
    }

    private let lock = NSLock()
    private var state = State()

    func update(_ body: (inout State) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&state)
    }

    func fail(_ step: String, _ sentence: String) { update { $0.failures.append((step, sentence)) } }
    func note(_ text: String) { update { $0.notes.append(text) } }
    var snapshot: State { lock.lock(); defer { lock.unlock() }; return state }
}

/// The directory a diagnostics bundle is written to.
struct DiagnosticsBundle: Sendable {
    let root: URL

    /// Writes `data` to the path `relative` below the bundle, creating its folder; false with `log` told when it fails.
    @discardableResult
    func put(_ data: Data, _ relative: String, step: String, log: DiagnosticsLog) -> Bool {
        let url = root.appendingPathComponent(relative)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            log.fail(step, "could not write \(relative): \(ControlHandler.failureReason(error, fallback: "the disk write failed")); free disk space or choose another dir")
            return false
        }
    }

    @discardableResult
    func put(_ text: String, _ relative: String, step: String, log: DiagnosticsLog) -> Bool {
        put(Data(text.utf8), relative, step: step, log: log)
    }

    /// Writes the sentence into `<stem>.error.txt` and tells `log` that `step` failed.
    func fail(_ step: String, stem: String, _ sentence: String, log: DiagnosticsLog) {
        log.fail(step, sentence)
        put(sentence + "\n", stem + ".error.txt", step: step, log: log)
    }

    func folder(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
}

/// `vm.collect_diagnostics`: gathers the evidence of a VM's current state into one directory on the host.
extension ControlHandler {
    func collectDiagnostics(_ params: JSON) async throws -> JSON {
        let t = try await target(params)
        let vm = t.name
        let since = try diagnosticsSinceMinutes(params)
        let logFiles = try diagnosticsLogFiles(params)
        let processName = try diagnosticsProcessName(params)
        let root = try diagnosticsFolder(params, vm: vm)

        let collected = wallClock()
        let os = await t.guestOS()
        let state = await t.state()
        let running = state == .running || state == .paused
        let agent = running ? await t.agent(timeout: DiagnosticsTiming.agentWait) : nil
        let log = DiagnosticsLog()
        let bundle = DiagnosticsBundle(root: root)
        let base: JSON = ["name": .string(vm)]

        if !running {
            log.note("VM '\(vm)' is \(describe(state)); call vm.start and collect again for the screenshot and the guest files")
        } else if agent == nil {
            log.note(ControlError.noTools(vm).description + ". Collected: screenshot, doctor report, guest events and recording files. Skipped: windows, UI tree, processes, event logs, jobs, log files and crash dumps")
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.collectScreenshot(t, running: running, state: state, bundle, log) }
            group.addTask { await self.collectJSON(step: "doctor", file: "doctor.json", limit: DiagnosticsTiming.doctor, bundle, log) { try await self.guest(op: "vm.doctor", params: base) } }
            group.addTask { await self.collectJSON(step: "events", file: "events.json", limit: DiagnosticsTiming.recordingFiles, bundle, log) { try await self.guestEvents(base) } }
            group.addTask { await self.collectRecording(vm, bundle, log) }
            guard running, agent != nil else { return }
            group.addTask { await self.collectWindows(t, bundle, log) }
            group.addTask { await self.collectTree(t, bundle, log) }
            group.addTask { await self.collectProcesses(t, processName: processName, bundle, log) }
            let logs = os == .windows ? [("Application", "eventlog-application"), ("System", "eventlog-system")] : [("System", "eventlog-system")]
            for (name, stem) in logs {
                group.addTask { await self.collectEventLog(t, log: name, stem: stem, since: since, bundle, log) }
            }
            group.addTask { await self.collectJobs(t, bundle, log) }
            if !logFiles.isEmpty { group.addTask { await self.collectLogFiles(t, logFiles, bundle, log) } }
            group.addTask { await self.collectDumps(t, since: since, bundle, log) }
        }

        let summary = ControlHandler.diagnosticsSummary(vm: vm, collected: collected, os: os, since: since, processName: processName, log.snapshot)
        let wrote = bundle.put(summary + "\n", "summary.txt", step: "summary", log: log)
        if !wrote { throw ControlError.failed("could not write summary.txt in '\(root.path)'; free disk space or choose another dir") }
        return ["dir": .string(root.path), "files": .array(ControlHandler.bundleFiles(root).map(JSON.string)), "summary": .string(summary)]
    }

    // MARK: - parameters

    private func diagnosticsSinceMinutes(_ params: JSON) throws -> Int {
        let since = try optional(params, "sinceMinutes", .integer)?.intValue ?? 30
        guard (1...5_256_000).contains(since) else { throw ControlError.failed("sinceMinutes must be between 1 and 5256000") }
        return since
    }

    private func diagnosticsLogFiles(_ params: JSON) throws -> [String] {
        guard let value = params["logFiles"], value != .null else { return [] }
        let message = "logFiles must be a list of 1 to \(DiagnosticsLimits.maxLogFiles) guest file paths"
        guard let items = value.arrayValue, items.count <= DiagnosticsLimits.maxLogFiles else { throw ControlError.failed(message) }
        let paths = items.compactMap(\.stringValue)
        guard paths.count == items.count, paths.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else { throw ControlError.failed(message) }
        return paths
    }

    private func diagnosticsProcessName(_ params: JSON) throws -> String? {
        guard let value = params["processName"], value != .null else { return nil }
        guard let name = value.stringValue, !name.isEmpty else { throw ControlError.failed("processName must be a program name such as MyApp.exe") }
        return name
    }

    /// The new, empty folder of the bundle: `dir` when it is missing or empty, otherwise a fresh `<vm>-<time>` folder below the
    /// Diagnostics folder. A `dir` that holds anything is refused.
    private func diagnosticsFolder(_ params: JSON, vm: String) throws -> URL {
        var request = params.objectValue ?? [:]
        if request["dir"] == .null { request["dir"] = nil }
        let explicit = request["dir"] != nil
        let base = diagnosticsDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Alcove/Diagnostics")
        var url = try recordingDirectory(.object(request), vm: vm, base: base).standardizedFileURL
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if explicit {
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else { throw ControlError.failed("'\(url.path)' is a file; choose a directory that is missing or empty") }
                guard ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).isEmpty else {
                    throw ControlError.failed("'\(url.path)' is not empty; choose a directory that is missing or empty, or leave dir out for a new folder")
                }
            }
        } else {
            let first = url
            var number = 1
            while fm.fileExists(atPath: url.path) {
                number += 1
                url = first.deletingLastPathComponent().appendingPathComponent("\(first.lastPathComponent)-\(number)")
            }
        }
        do { try fm.createDirectory(at: url, withIntermediateDirectories: true) } catch {
            throw ControlError.failed("cannot create the diagnostics folder '\(url.path)': \(ControlHandler.failureReason(error, fallback: "the directory could not be written; choose another dir"))")
        }
        return url
    }

    /// The files below `root` as paths relative to it, sorted.
    nonisolated static func bundleFiles(_ root: URL) -> [String] {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var files: [String] = []
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
            if !relative.hasSuffix(".alcove-part") { files.append(relative) }
        }
        return files.sorted()
    }

    // MARK: - time limits

    /// The result of `work`, or `DiagnosticsTimeout` when it has not finished after `limit`; the work is cancelled then and
    /// its late result is dropped.
    nonisolated func timed<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async -> Result<T, Error> {
        let answer = CallAnswer<Result<T, Error>>()
        let task = Task {
            do { await answer.finish(.success(try await work())) } catch { await answer.finish(.failure(error)) }
        }
        if let outcome = await answer.outcome(until: .now + limit) { return outcome.result }
        task.cancel()
        return .failure(DiagnosticsTimeout())
    }

    /// The sentence that tells why a step failed.
    nonisolated func diagnosticsSentence(_ error: Error, step: String, limit: Duration) -> String {
        if error is DiagnosticsTimeout || error is CancellationError {
            return "the \(step) step did not finish within \(Int(limit.components.seconds)) s; run vm.doctor to check the guest tools, then collect again"
        }
        return ControlHandler.failureReason(error, fallback: "the \(step) step failed unexpectedly; collect again")
    }

    /// One `file` holding the JSON `work` returns.
    private func collectJSON(step: String, file: String, limit: Duration, _ bundle: DiagnosticsBundle, _ log: DiagnosticsLog,
                             _ work: @escaping @Sendable () async throws -> JSON) async {
        switch await timed(limit, work) {
        case .success(let json):
            bundle.put(ControlHandler.prettyJSON(json), file, step: step, log: log)
        case .failure(let error):
            bundle.fail(step, stem: String(file.dropLast(".json".count)), diagnosticsSentence(error, step: step, limit: limit), log: log)
        }
    }

    nonisolated static func prettyJSON(_ json: JSON) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(json)) ?? Data()) + Data("\n".utf8)
    }

    // MARK: - screenshot, windows, tree, processes

    private func collectScreenshot(_ t: VMTarget, running: Bool, state: VMController.State, _ bundle: DiagnosticsBundle, _ log: DiagnosticsLog) async {
        guard running else {
            bundle.fail("screenshot", stem: "screenshot", ControlError.notRunning(t.name, state).description, log: log)
            return
        }
        let result = await timed(DiagnosticsTiming.screenshot) {
            let png = try await self.screenshot(t).encoded(.png)
            guard !png.isEmpty else { throw ControlError.failed("the screenshot could not be encoded as PNG; call vm.screenshot") }
            return png
        }
        switch result {
        case .success(let png): bundle.put(png, "screenshot.png", step: "screenshot", log: log)
        case .failure(let error):
            bundle.fail("screenshot", stem: "screenshot", diagnosticsSentence(error, step: "screenshot", limit: DiagnosticsTiming.screenshot), log: log)
        }
    }

    /// One helper call that waits `turn` for its turn at the VM's UI helper and `total` for the agent's answer. A call that was
    /// sent keeps the helper until the agent answers, also when this wait ended; a call still waiting for its turn is not sent.
    func boundedHelperCall(_ agent: AgentClient, _ agentOp: String, _ fields: [String: JSON], vm: String, op: String,
                           turn: Duration, total: Duration) async throws -> JSON {
        let start = ContinuousClock.now
        let probe = startHelperCall(agent, agentOp, fields, vm: vm, turnBy: start + turn)
        guard let outcome = await probe.answer.outcome(until: start + max(turn, total)) else {
            let phase = await probe.answer.phase
            probe.abandon()
            if case .sent = phase {
                throw ControlError.failed("the UI helper in '\(vm)' did not answer \(op) within \(Int(total.components.seconds)) s; run vm.doctor and retry")
            }
            throw ControlError.failed("the UI helper is busy with other requests; retry")
        }
        switch outcome.result {
        case .success(let reply): return reply
        case .failure(let error):
            if error is HelperBusy { throw ControlError.failed("the UI helper is busy with other requests; retry") }
            throw agentFailure(error, vm: vm, op: op)
        }
    }

    private func collectWindows(_ t: VMTarget, _ bundle: DiagnosticsBundle, _ log: DiagnosticsLog) async {
        let limit = DiagnosticsTiming.windows + .seconds(5)
        let result = await timed(limit) {
            let agent = try await self.uiAgent(t, op: "vm.window.list")
            let r = try await self.boundedHelperCall(agent, "win.list", [:], vm: t.name, op: "vm.window.list",
                                                     turn: DiagnosticsTiming.windowsTurn, total: DiagnosticsTiming.windows)
            return JSON.object(["windows": r["windows"] ?? []])
        }
        switch result {
        case .success(let json):
            let windows = json["windows"]?.arrayValue ?? []
            log.update {
                $0.windows = windows
                $0.foreground = windows.first { $0["foreground"]?.boolValue == true }?["title"]?.stringValue
            }
            bundle.put(ControlHandler.prettyJSON(json), "windows.json", step: "windows", log: log)
        case .failure(let error):
            bundle.fail("windows", stem: "windows", diagnosticsSentence(error, step: "windows", limit: limit), log: log)
        }
    }

    private func collectTree(_ t: VMTarget, _ bundle: DiagnosticsBundle, _ log: DiagnosticsLog) async {
        let limit = DiagnosticsTiming.tree + .seconds(5)
        let result = await timed(limit) {
            let agent = try await self.uiAgent(t, op: "vm.ui.tree")
            let request: [String: JSON] = ["window": "foreground", "filter": "all", "max": .int(Int64(DiagnosticsLimits.treeNodes))]
            return try await self.boundedHelperCall(agent, "ui.tree", request, vm: t.name, op: "vm.ui.tree",
                                                    turn: DiagnosticsTiming.treeTurn, total: DiagnosticsTiming.tree)
        }
        switch result {
        case .success(let r):
            var text = UITreeText.render(r["nodes"]?.arrayValue ?? [])
            if r["truncated"]?.boolValue == true { text += "\n… more elements; call vm.ui.tree to read the whole window" }
            if let title = r["window"]?["title"]?.stringValue { log.update { $0.foreground = $0.foreground ?? title } }
            bundle.put(text + "\n", "ui-tree.txt", step: "ui-tree", log: log)
        case .failure(let error):
            bundle.fail("ui-tree", stem: "ui-tree", diagnosticsSentence(error, step: "ui-tree", limit: limit), log: log)
        }
    }

    private func collectProcesses(_ t: VMTarget, processName: String?, _ bundle: DiagnosticsBundle, _ log: DiagnosticsLog) async {
        var request: [String: JSON] = ["name": .string(t.name)]
        if let processName { request["filter"] = .string(processName) }
        let params = JSON.object(request)
        let result = await timed(DiagnosticsTiming.processes) { try await self.shell(op: "vm.process.list", params: params) }
        switch result {
        case .success(let json):
            log.update { $0.processes = json["processes"]?.arrayValue ?? [] }
            bundle.put(ControlHandler.prettyJSON(json), "processes.json", step: "processes", log: log)
        case .failure(let error):
            bundle.fail("processes", stem: "processes", diagnosticsSentence(error, step: "processes", limit: DiagnosticsTiming.processes), log: log)
        }
    }

    // MARK: - event logs

    private func collectEventLog(_ t: VMTarget, log name: String, stem: String, since: Int, _ bundle: DiagnosticsBundle, _ log: DiagnosticsLog) async {
        let params: JSON = ["name": .string(t.name), "log": .string(name), "level": "error", "sinceMinutes": .int(Int64(since)),
                            "max": .int(Int64(DiagnosticsLimits.eventLogEntries))]
        let result = await timed(DiagnosticsTiming.eventLog) { try await self.guest(op: "vm.event_log", params: params) }
        switch result {
        case .success(let json):
            let entries = json["entries"]?.arrayValue ?? []
            let newest = entries.max { ($0["time"]?.stringValue ?? "") < ($1["time"]?.stringValue ?? "") }
            let atLeast = json["truncated"]?.boolValue == true || entries.count >= DiagnosticsLimits.eventLogEntries
            log.update {
                $0.logCounts[name] = DiagnosticsLog.LogCount(count: entries.count, atLeast: atLeast, newest: newest?["message"]?.stringValue)
            }
            bundle.put(ControlHandler.prettyJSON(json), stem + ".json", step: stem, log: log)
        case .failure(let error):
            bundle.fail(stem, stem: stem, diagnosticsSentence(error, step: stem, limit: DiagnosticsTiming.eventLog), log: log)
        }
    }

    // MARK: - jobs

    private func collectJobs(_ t: VMTarget, _ bundle: DiagnosticsBundle, _ log: DiagnosticsLog) async {
        let deadline = ContinuousClock.now + DiagnosticsTiming.jobs
        let base: JSON = ["name": .string(t.name)]
        let listed = await timed(DiagnosticsTiming.jobs) { try await self.shell(op: "vm.exec.list", params: base) }
        let rows: [JSON]
        switch listed {
        case .success(let json): rows = json["jobs"]?.arrayValue ?? []
        case .failure(let error):
            bundle.fail("jobs", stem: "jobs", diagnosticsSentence(error, step: "jobs", limit: DiagnosticsTiming.jobs), log: log)
            return
        }
        log.update { $0.failedJobs = rows.compactMap { row in
            guard row["state"]?.stringValue == "exited", let code = row["code"]?.intValue, code != 0 else { return nil }
            return (row["job"]?.stringValue ?? "", code)
        } }
        var names = DiagnosticsNames()
        let jobs = rows.compactMap { row in row["job"]?.stringValue.map { (id: $0, row: row, file: names.claim($0, fallback: "job") + ".txt") } }
        await withTaskGroup(of: Void.self) { group in
            for job in jobs {
                group.addTask {
                    let remaining = max(.seconds(1), ContinuousClock.now.duration(to: deadline))
                    let result = await self.timed(remaining) { try await self.readJob(t.name, job.id) }
                    let step = "jobs/\(job.file)"
                    switch result {
                    case .success(let out):
                        bundle.put(ControlHandler.jobText(job.id, job.row, out), "jobs/" + job.file, step: step, log: log)
                    case .failure(let error):
                        log.fail(step, self.diagnosticsSentence(error, step: step, limit: remaining))
                        bundle.put(self.diagnosticsSentence(error, step: step, limit: remaining) + "\n", "jobs/" + job.file + ".error.txt", step: step, log: log)
                    }
                }
            }
        }
    }

    struct JobTail: Sendable {
        var out = Data()
        var err = Data()
        var cutOut = false
        var cutErr = false
        var dropped = false
    }

    /// The last `DiagnosticsLimits.jobBytes` bytes of each stream of `job`, read from offset 0 without consuming anything.
    private func readJob(_ vm: String, _ job: String) async throws -> JobTail {
        var tail = JobTail()
        var outOffset = 0, errOffset = 0
        for _ in 0..<10 {
            let r = try await shell(op: "vm.exec.read", params: ["name": .string(vm), "job": .string(job), "outOffset": .int(Int64(outOffset)),
                                                                 "errOffset": .int(Int64(errOffset)), "max": .int(Int64(DiagnosticsLimits.jobBytes))])
            tail.out.append(Data((r["out"]?.stringValue ?? "").utf8))
            tail.err.append(Data((r["err"]?.stringValue ?? "").utf8))
            if tail.out.count > DiagnosticsLimits.jobBytes { tail.out = Data(tail.out.suffix(DiagnosticsLimits.jobBytes)); tail.cutOut = true }
            if tail.err.count > DiagnosticsLimits.jobBytes { tail.err = Data(tail.err.suffix(DiagnosticsLimits.jobBytes)); tail.cutErr = true }
            if r["dropped"]?.boolValue == true || (r["dropped"]?.intValue ?? 0) > 0 { tail.dropped = true }
            let nextOut = r["outNext"]?.intValue ?? outOffset, nextErr = r["errNext"]?.intValue ?? errOffset
            if nextOut == outOffset && nextErr == errOffset { break }
            outOffset = nextOut; errOffset = nextErr
        }
        return tail
    }

    nonisolated static func jobText(_ id: String, _ row: JSON, _ tail: JobTail) -> String {
        var head = "job \(id)"
        if let state = row["state"]?.stringValue {
            head += ": \(state)"
            if let code = row["code"]?.intValue { head += ", code \(code)" }
        }
        var text = head + "\n"
        if let cmd = row["cmd"]?.stringValue { text += "command: \(cmd)\n" }
        if let started = row["started"]?.stringValue { text += "started: \(started)\n" }
        if tail.dropped { text += "the guest no longer holds the oldest output of this job\n" }
        let limit = DiagnosticsLimits.jobBytes
        text += "--- stdout\(tail.cutOut || tail.dropped ? " (last \(limit) bytes)" : "") ---\n" + String(decoding: tail.out, as: UTF8.self) + "\n"
        text += "--- stderr\(tail.cutErr || tail.dropped ? " (last \(limit) bytes)" : "") ---\n" + String(decoding: tail.err, as: UTF8.self) + "\n"
        return text
    }

    // MARK: - log files

    private func collectLogFiles(_ t: VMTarget, _ paths: [String], _ bundle: DiagnosticsBundle, _ log: DiagnosticsLog) async {
        var names = DiagnosticsNames()
        let plan = paths.map { (path: $0, file: names.claim($0, fallback: "log")) }
        let limit = DiagnosticsTiming.logFiles
        await withTaskGroup(of: Void.self) { group in
            for item in plan {
                group.addTask {
                    let params: JSON = ["name": .string(t.name), "path": .string(item.path), "tail": .int(Int64(DiagnosticsLimits.logLines))]
                    let result = await self.timed(limit) {
                        do { return try await self.readText(t, params) } catch { throw self.agentFailure(error, vm: t.name, op: "vm.fs.read") }
                    }
                    let step = "logs/\(item.file)"
                    switch result {
                    case .success(let r):
                        let text = ControlHandler.cappedTail(r["text"]?.stringValue ?? "", bytes: DiagnosticsLimits.logBytes)
                        if text.isEmpty, (r["size"]?.intValue ?? 0) > 0 {
                            log.note("log file \(item.file): the guest file has \(r["size"]?.intValue ?? 0) bytes but no complete line in its last \(DiagnosticsLimits.logBytes) bytes")
                        }
                        bundle.put(text, "logs/" + item.file, step: step, log: log)
                    case .failure(let error):
                        let sentence = self.diagnosticsSentence(error, step: step, limit: limit)
                        log.fail(step, sentence)
                        bundle.put(sentence + "\n", "logs/" + item.file + ".error.txt", step: step, log: log)
                    }
                }
            }
        }
    }

    /// `text` itself, or its last `bytes` UTF-8 bytes starting at a line start.
    nonisolated static func cappedTail(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        let tail = String(decoding: text.utf8.suffix(bytes), as: UTF8.self)
        guard let newline = tail.firstIndex(of: "\n") else { return tail }
        return String(tail[tail.index(after: newline)...])
    }

    // MARK: - crash dumps

    struct DumpRow: Sendable, Equatable {
        let file: String
        let bytes: Int
        let time: String
    }

    /// The rows to pull, in the given order, while their sizes add up to at most `budget`; a row that does not fit is skipped
    /// and the rows after it still get their chance.
    nonisolated static func selectDumps(_ rows: [DumpRow], budget: Int) -> (take: [DumpRow], skipped: [DumpRow]) {
        var take: [DumpRow] = [], skipped: [DumpRow] = []
        var total = 0
        for row in rows {
            if total + row.bytes <= budget { take.append(row); total += row.bytes } else { skipped.append(row) }
        }
        return (take, skipped)
    }

    /// The time of a guest timestamp such as `2026-10-13T09:30:00.1234567Z`.
    nonisolated static func guestTime(_ text: String) -> Date? {
        let shortened = text.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: shortened) ?? ISO8601DateFormatter().date(from: shortened)
    }

    private func collectDumps(_ t: VMTarget, since: Int, _ bundle: DiagnosticsBundle, _ log: DiagnosticsLog) async {
        let deadline = ContinuousClock.now + DiagnosticsTiming.dumps
        let base: JSON = ["name": .string(t.name)]
        let listLimit = min(DiagnosticsTiming.dumpList, DiagnosticsTiming.dumps)
        let listed = await timed(listLimit) { try await self.guest(op: "vm.crash_dumps.list", params: base) }
        let all: [DumpRow]
        switch listed {
        case .success(let json):
            all = (json["dumps"]?.arrayValue ?? []).map {
                DumpRow(file: $0["file"]?.stringValue ?? "", bytes: $0["bytes"]?.intValue ?? 0, time: $0["time"]?.stringValue ?? "")
            }
        case .failure(let error):
            bundle.fail("dumps", stem: "dumps", diagnosticsSentence(error, step: "dumps", limit: listLimit), log: log)
            return
        }
        let cutoff = wallClock().addingTimeInterval(-Double(since) * 60)
        let recent = all.filter { row in ControlHandler.guestTime(row.time).map { $0 >= cutoff } ?? true }
            .sorted { (ControlHandler.guestTime($0.time) ?? .distantPast) > (ControlHandler.guestTime($1.time) ?? .distantPast) }
        let (take, skipped) = ControlHandler.selectDumps(recent, budget: DiagnosticsLimits.dumpBudget)
        var found = skipped.map { DiagnosticsLog.Dump(file: $0.file, bytes: $0.bytes, time: $0.time,
                                                      outcome: "not collected: it does not fit the \(DiagnosticsLimits.dumpBudget / 1_048_576) MiB dump budget; pull it with vm.crash_dumps.pull") }
        var names = DiagnosticsNames()
        for row in take {
            let file = names.claim(row.file, fallback: "dump.dmp")
            let step = "dumps/\(file)"
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else {
                let sentence = "the dump step ran out of time before this dump; pull it with vm.crash_dumps.pull"
                found.append(.init(file: row.file, bytes: row.bytes, time: row.time, outcome: "not collected: " + sentence))
                log.fail(step, sentence)
                continue
            }
            let destination = bundle.folder("dumps").appendingPathComponent(file)
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let params: JSON = ["name": .string(t.name), "file": .string(row.file), "path": .string(destination.path)]
            switch await timed(remaining, { try await self.files(op: "vm.crash_dumps.pull", params: params) }) {
            case .success:
                found.append(.init(file: row.file, bytes: row.bytes, time: row.time, outcome: "collected as dumps/\(file)"))
            case .failure(let error):
                let sentence = diagnosticsSentence(error, step: step, limit: remaining)
                found.append(.init(file: row.file, bytes: row.bytes, time: row.time, outcome: "not collected: " + sentence))
                log.fail(step, sentence)
                bundle.put(sentence + "\n", "dumps/" + file + ".error.txt", step: step, log: log)
                try? FileManager.default.removeItem(at: destination)
            }
        }
        log.update { $0.dumps = found }
    }

    // MARK: - recording

    private func collectRecording(_ vm: String, _ bundle: DiagnosticsBundle, _ log: DiagnosticsLog) async {
        guard let recording = recordings.active[vm] else {
            log.note("no recording is active; trace.jsonl and video.mp4 are collected while one runs")
            return
        }
        let trace = recording.directory.appendingPathComponent(TraceWriter.traceName)
        let destination = bundle.root.appendingPathComponent("trace.jsonl")
        let limit = DiagnosticsTiming.recordingFiles
        let copied = await timed(limit) {
            let data = try await Task.detached { try ControlHandler.wholeLines(of: trace, limit: DiagnosticsLimits.traceBytes) }.value
            try data.write(to: destination, options: .atomic)
        }
        if case .failure(let error) = copied {
            bundle.fail("trace", stem: "trace", diagnosticsSentence(error, step: "trace", limit: limit), log: log)
        }
        guard recording.video else { return }
        if await recording.isActive {
            bundle.fail("video", stem: "video", "the recording is still running; call vm.record.stop and collect again for the video", log: log)
            return
        }
        let ended = await recording.stop()
        guard let video = ended.video else {
            bundle.fail("video", stem: "video", "the recording ended without a playable video; check lastWriteError of vm.record.stop and record again", log: log)
            return
        }
        let videoDestination = bundle.root.appendingPathComponent("video.mp4")
        let moved = await timed(limit) {
            try await Task.detached { try FileManager.default.copyItem(at: URL(fileURLWithPath: video), to: videoDestination) }.value
        }
        if case .failure(let error) = moved {
            try? FileManager.default.removeItem(at: videoDestination)
            bundle.fail("video", stem: "video", diagnosticsSentence(error, step: "video", limit: limit), log: log)
        }
    }

    /// The whole lines among the last `limit` bytes of the file at `url`, as far as it reached when this call began; a line
    /// that is not finished yet, and a first line the limit cut, are left out.
    nonisolated static func wholeLines(of url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        let start = max(0, size - limit)
        try handle.seek(toOffset: UInt64(start))
        var data = try handle.read(upToCount: size - start) ?? Data()
        if start > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else { return Data() }
            data = Data(data[data.index(after: newline)...])
        }
        guard let last = data.lastIndex(of: 0x0A) else { return Data() }
        return Data(data[...last])
    }

    // MARK: - summary

    nonisolated static func oneLine(_ text: String, limit: Int = 200) -> String {
        let flat = text.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F || $0.value == 0x2028 || $0.value == 0x2029 ? " " : String($0) }.joined()
        let squeezed = flat.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return squeezed.count > limit ? String(squeezed.prefix(limit)) + "…" : squeezed
    }

    private static let stepOrder = ["screenshot", "windows", "ui-tree", "processes", "eventlog-application", "eventlog-system", "events", "jobs",
                                    "logs", "dumps", "doctor", "trace", "video", "summary"]

    nonisolated static func diagnosticsSummary(vm: String, collected: Date, os: VMConfig.GuestOS, since: Int, processName: String?,
                                               _ state: DiagnosticsLog.State) -> String {
        var lines = ["VM \(vm), collected \(ISO8601DateFormatter().string(from: collected)), guest \(os.rawValue)"]
        if let windows = state.windows {
            let stuck = windows.filter { $0["responding"]?.boolValue == false }
            if stuck.isEmpty { lines.append("windows not responding: none") }
            for window in stuck {
                let process = window["process"]?.stringValue.map { ", " + oneLine($0, limit: 60) } ?? ""
                lines.append("window not responding: \(window["id"]?.stringValue ?? "?") \(UITreeText.quoted(oneLine(window["title"]?.stringValue ?? "", limit: 120))) (pid \(window["pid"]?.intValue ?? 0)\(process))")
            }
        }
        if let title = state.foreground {
            lines.append("foreground window: \(UITreeText.quoted(oneLine(title, limit: 120)))")
        } else if state.windows != nil {
            lines.append("foreground window: none")
        }
        if let dumps = state.dumps {
            if dumps.isEmpty { lines.append("crash dumps: none newer than \(since) minutes") }
            for dump in dumps {
                lines.append("crash dump \(oneLine(dump.file, limit: 120)): \(dump.bytes) bytes, \(oneLine(dump.time, limit: 40)), \(dump.outcome)")
            }
        }
        for name in ["Application", "System"] {
            guard let found = state.logCounts[name] else { continue }
            let count = "\(found.atLeast ? "at least " : "")\(found.count) \(found.count == 1 && !found.atLeast ? "entry" : "entries")"
            lines.append("event log \(name): \(count) of level error or worse in the last \(since) minutes" + (found.newest.map { "; newest: " + oneLine($0) } ?? ""))
        }
        if let failed = state.failedJobs {
            if failed.isEmpty { lines.append("jobs exited with a non-zero code: none") }
            for job in failed { lines.append("job \(oneLine(job.job, limit: 40)) exited with code \(job.code)") }
        }
        if let processName, let rows = state.processes {
            let pids = rows.compactMap { $0["pid"]?.intValue }
            lines.append(pids.isEmpty ? "process \(oneLine(processName, limit: 80)): not running"
                                      : "process \(oneLine(processName, limit: 80)): running, pid \(pids.prefix(5).map(String.init).joined(separator: ", "))")
        }
        lines += state.notes.sorted().map { oneLine($0, limit: 400) }
        func rank(_ step: String) -> Int { stepOrder.firstIndex(of: String(step.prefix { $0 != "/" })) ?? stepOrder.count }
        let failures = state.failures.sorted { (rank($0.step), $0.step) < (rank($1.step), $1.step) }
        if failures.isEmpty {
            lines.append("steps that failed: none")
        } else {
            lines.append("steps that failed:")
            lines += failures.map { "\(oneLine($0.step, limit: 120)): \(oneLine($0.sentence, limit: 400))" }
        }
        return lines.joined(separator: "\n")
    }
}
