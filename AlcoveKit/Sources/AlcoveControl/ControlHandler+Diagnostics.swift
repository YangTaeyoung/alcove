import Foundation
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP

/// The time limits of the steps of `vm.collect_diagnostics`. Steps that do not depend on each other run at the same time.
enum DiagnosticsTiming {
    /// Longest the op waits for the guest tools to be connected before it skips the guest steps.
    nonisolated(unsafe) static var agentWait = Duration.seconds(5)
    nonisolated(unsafe) static var screenshot = Duration.seconds(10)
    /// Longest `windows.json` waits for its turn at the UI helper, and for the helper's answer counted from the start.
    nonisolated(unsafe) static var windowsTurn = Duration.seconds(15)
    nonisolated(unsafe) static var windows = Duration.seconds(30)
    /// Longest `ui-tree.txt` waits for its turn at the UI helper, and for the helper's answer counted from its own start.
    nonisolated(unsafe) static var treeTurn = Duration.seconds(40)
    nonisolated(unsafe) static var tree = Duration.seconds(50)
    nonisolated(unsafe) static var processes = Duration.seconds(35)
    /// One event log read; the guest recipe itself stops after 60 s.
    nonisolated(unsafe) static var eventLog = Duration.seconds(80)
    nonisolated(unsafe) static var events = Duration.seconds(30)
    nonisolated(unsafe) static var jobs = Duration.seconds(45)
    nonisolated(unsafe) static var logFiles = Duration.seconds(45)
    nonisolated(unsafe) static var doctor = Duration.seconds(85)
    /// The crash dump list, which is a guest recipe like an event log read.
    nonisolated(unsafe) static var dumpList = Duration.seconds(80)
    /// The whole dump step: the list and every pull.
    nonisolated(unsafe) static var dumps = Duration.seconds(100)
    /// Longest the op waits for a recording that is ending to have ended.
    nonisolated(unsafe) static var recordingEnd = Duration.seconds(30)
    /// Reading the trace of the recording.
    nonisolated(unsafe) static var trace = Duration.seconds(30)
    /// Copying the frames the trace refers to.
    nonisolated(unsafe) static var frames = Duration.seconds(30)
    /// Copying the video of the recording.
    nonisolated(unsafe) static var video = Duration.seconds(60)
    /// Added to the limit of a step whose work ends by itself at that limit.
    static let grace = Duration.seconds(5)
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
    nonisolated(unsafe) static var traceBytes = 32 * 1024 * 1024
    /// Most bytes of crash dumps that are pulled.
    nonisolated(unsafe) static var dumpBudget = 500 * 1024 * 1024
    /// Most bytes of frame files that are copied.
    nonisolated(unsafe) static var frameBytes = 256 * 1024 * 1024
    /// Most bytes a video may hold to be copied.
    nonisolated(unsafe) static var videoBytes = 1024 * 1024 * 1024
    static let eventLogEntries = 500
    static let treeNodes = 1000
}

/// A step that did not finish within its time limit.
struct DiagnosticsTimeout: Error {}

/// Host file names for names that come from the guest: a single path component without separators, control characters or
/// leading dots, at most `maxBytes` bytes before the suffix. Every name handed out differs from every earlier one and from
/// the error file name of every earlier one, compared as precomposed, case-folded text.
struct DiagnosticsNames {
    static let maxBytes = 100
    static let errorSuffix = ".error.txt"
    private var taken: Set<String> = []

    /// A file name for `guestName` (its last path component, then `suffix`); `fallback` stands for a name with nothing
    /// usable. The name and its error file name `<name>.error.txt` are both kept from later calls.
    mutating func claim(_ guestName: String, fallback: String, suffix: String = "") -> String {
        let clean = DiagnosticsNames.clean(guestName, fallback: fallback)
        var number = 1
        while true {
            let file = (number == 1 ? clean : DiagnosticsNames.numbered(clean, number)) + suffix
            let keys = [DiagnosticsNames.key(file), DiagnosticsNames.key(file + DiagnosticsNames.errorSuffix)]
            if taken.isDisjoint(with: keys) {
                taken.formUnion(keys)
                return file
            }
            number += 1
        }
    }

    /// The form in which two names are compared: precomposed and case-folded.
    static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
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
        /// The dumps older than the requested minutes: how many, and the time of the newest.
        var olderDumps: (count: Int, newest: String)?
        var logCounts: [String: LogCount] = [:]
        var failedJobs: [(job: String, code: Int)]?
        /// The job files that hold only the tail of a stream.
        var cutJobs: [String] = []
        var processes: [JSON]?
        /// The recording the bundle uses, as the summary names it.
        var recording: String?
        var frames: (copied: Int, referenced: Int)?
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

/// The directory a diagnostics bundle is written to. Files written below `.partial/` get their place in the bundle when
/// the step that waited for them moves them there.
struct DiagnosticsBundle: Sendable {
    static let partialName = ".partial"

    let root: URL

    var partial: URL { root.appendingPathComponent(DiagnosticsBundle.partialName, isDirectory: true) }

    /// Writes `data` to the path `relative` below the bundle, creating its folder; false with `log` told when it fails.
    /// Nothing is written from a cancelled task.
    @discardableResult
    func put(_ data: Data, _ relative: String, step: String, log: DiagnosticsLog) -> Bool {
        guard !Task.isCancelled else { return false }
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

    /// Writes the sentence into `<stem>.error.txt` and tells `log` that `step` failed. Nothing happens in a cancelled task.
    func fail(_ step: String, stem: String, _ sentence: String, log: DiagnosticsLog) {
        guard !Task.isCancelled else { return }
        log.fail(step, sentence)
        put(sentence + "\n", stem + DiagnosticsNames.errorSuffix, step: step, log: log)
    }

    /// A path below `.partial/` that no other call returns, ending in `suffix`.
    func scratch(_ suffix: String = "") -> URL { partial.appendingPathComponent(UUID().uuidString + suffix) }

    /// Moves the file or folder at `scratch` to the path `relative` below the bundle, creating its folder.
    func adopt(_ scratch: URL, as relative: String) throws {
        try Task.checkCancellation()
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: scratch, to: url)
    }

    /// Renames `.partial/`, then removes it with everything in it.
    func removePartial() {
        let gone = root.appendingPathComponent("\(DiagnosticsBundle.partialName)-\(UUID().uuidString)")
        guard (try? FileManager.default.moveItem(at: partial, to: gone)) != nil else { return }
        try? FileManager.default.removeItem(at: gone)
    }
}

/// How one call to the UI helper ended for a caller that waits a bounded time.
enum HelperReply: Sendable {
    case answered(JSON)
    /// The call failed with this sentence.
    case failed(String)
    /// The call was sent and the agent has not answered; it keeps the helper until the agent answers.
    case unanswered(String)
    /// The call was not sent: another call kept the helper for the whole wait.
    case busy
}

/// The recording a diagnostics bundle uses.
private enum BundleRecording {
    case running(Recording)
    case ended(LastRecording)
    /// A recording that is ending and had not ended when the wait for it ran out.
    case ending(Recording)
}

/// `vm.collect_diagnostics`: gathers the evidence of a VM's current state into one directory on the host.
extension ControlHandler {
    static let busyHelperSentence = "the UI helper is held by a call outside this collection; retry when that call has answered"
    static let treeAfterUnansweredWindows = "the window list took the time available; call vm.ui.tree when the app answers"

    func collectDiagnostics(_ params: JSON) async throws -> JSON {
        let t = try await target(params)
        let vm = t.name
        let since = try diagnosticsSinceMinutes(params)
        let logFiles = try diagnosticsLogFiles(params)
        let processName = try diagnosticsProcessName(params)
        let place = try diagnosticsFolder(params, vm: vm)
        defer { diagnosticsInProgress.remove(place.key) }
        let root = place.root

        let collected = wallClock()
        let os = await t.guestOS()
        let state = await t.state()
        let displays = state == .running || state == .paused
        let agent = state == .running ? await t.agent(timeout: DiagnosticsTiming.agentWait) : nil
        let log = DiagnosticsLog()
        let bundle = DiagnosticsBundle(root: root)
        let base: JSON = ["name": .string(vm)]
        let withoutGuest = "Collected: screenshot, doctor report, guest events and recording files. Skipped: windows, UI tree, processes, event logs, jobs, log files and crash dumps"

        if state == .paused {
            log.note("VM '\(vm)' is paused; call vm.resume and collect again for the guest files. \(withoutGuest)")
        } else if !displays {
            log.note("VM '\(vm)' is \(describe(state)); call vm.start and collect again for the screenshot and the guest files")
        } else if agent == nil {
            log.note(ControlError.noTools(vm).description + ". \(withoutGuest)")
        } else if os != .windows {
            log.note("windows, UI tree and crash dumps are collected on Windows guests only; skipped on this \(os.rawValue) guest")
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.collectScreenshot(t, displays: displays, state: state, bundle, log) }
            group.addTask { await self.collectJSON(step: "doctor", file: "doctor.json", limit: DiagnosticsTiming.doctor, bundle, log) { try await self.guest(op: "vm.doctor", params: base) } }
            group.addTask { await self.collectJSON(step: "events", file: "events.json", limit: DiagnosticsTiming.events, bundle, log) { try await self.guestEvents(base) } }
            group.addTask { await self.collectRecording(vm, since: since, collected: collected, bundle, log) }
            guard state == .running, agent != nil else { return }
            if os == .windows { group.addTask { await self.collectHelperSteps(t, bundle, log) } }
            group.addTask { await self.collectProcesses(t, processName: processName, bundle, log) }
            let logs = os == .windows ? [("Application", "eventlog-application"), ("System", "eventlog-system")] : [("System", "eventlog-system")]
            for (name, stem) in logs {
                group.addTask { await self.collectEventLog(t, log: name, stem: stem, since: since, bundle, log) }
            }
            group.addTask { await self.collectJobs(t, bundle, log) }
            if !logFiles.isEmpty { group.addTask { await self.collectLogFiles(t, logFiles, bundle, log) } }
            if os == .windows { group.addTask { await self.collectDumps(t, since: since, bundle, log) } }
        }
        bundle.removePartial()
        if Task.isCancelled {
            if place.created { try? FileManager.default.removeItem(at: root) }
            throw CancellationError()
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

    /// The folder of the bundle, holding only an empty `.partial/`: `dir` when it is missing or empty, otherwise a fresh
    /// `<vm>-<time>` folder below the Diagnostics folder. A `dir` that holds anything, or that another call of this
    /// handler is writing, is refused. `created` tells whether the folder did not exist before; `key` is the entry the
    /// folder has in `diagnosticsInProgress` until the caller removes it.
    private func diagnosticsFolder(_ params: JSON, vm: String) throws -> (root: URL, created: Bool, key: String) {
        var request = params.objectValue ?? [:]
        if request["dir"] == .null { request["dir"] = nil }
        let explicit = request["dir"] != nil
        let base = diagnosticsDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Alcove/Diagnostics")
        var url = try recordingDirectory(.object(request), vm: vm, base: base).standardizedFileURL
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if explicit {
            guard !diagnosticsInProgress.contains(url.resolvingSymlinksInPath().path) else {
                throw ControlError.failed("\(url.path) is being written by another collection")
            }
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
        let created = !fm.fileExists(atPath: url.path)
        do {
            try fm.createDirectory(at: url.appendingPathComponent(DiagnosticsBundle.partialName), withIntermediateDirectories: true)
        } catch {
            if created { try? fm.removeItem(at: url) }
            throw ControlError.failed("cannot create the diagnostics folder '\(url.path)': \(ControlHandler.failureReason(error, fallback: "the directory could not be written; choose another dir"))")
        }
        let key = url.resolvingSymlinksInPath().path
        diagnosticsInProgress.insert(key)
        return (url, created, key)
    }

    /// The regular files below `root` as paths relative to it, sorted; what lies below a `.partial` folder is left out.
    nonisolated static func bundleFiles(_ root: URL) -> [String] {
        var files: [String] = []
        let walker = FileManager.default.enumerator(atPath: root.path)
        while let relative = walker?.nextObject() as? String {
            guard walker?.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
            if !relative.hasPrefix(DiagnosticsBundle.partialName) { files.append(relative) }
        }
        return files.sorted()
    }

    // MARK: - time limits

    /// The result of `work`, or a failure when it has not finished after `limit` or the calling task was cancelled:
    /// `DiagnosticsTimeout` for the limit, `CancellationError` for the cancellation. The work is cancelled then and
    /// its late result is dropped.
    nonisolated func timed<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async -> Result<T, Error> {
        let answer = CallAnswer<Result<T, Error>>()
        let task = Task {
            do { await answer.finish(.success(try await work())) } catch { await answer.finish(.failure(error)) }
        }
        if let outcome = await answer.outcome(until: .now + limit) { return outcome.result }
        task.cancel()
        return .failure(Task.isCancelled ? CancellationError() : DiagnosticsTimeout())
    }

    /// Runs `work`, which writes one file or folder at the path below `.partial/` it is given, for `limit` at most, and
    /// moves what it wrote to `relative` when it ended in time. Work that ends later has its output removed with `.partial/`.
    nonisolated func collectFile<T: Sendable>(_ relative: String, limit: Duration, _ bundle: DiagnosticsBundle,
                                              _ work: @escaping @Sendable (URL) async throws -> T) async -> Result<T, Error> {
        let scratch = bundle.scratch()
        let result = await timed(limit) { try await work(scratch) }
        guard case .success = result else {
            try? FileManager.default.removeItem(at: scratch)
            return result
        }
        do { try bundle.adopt(scratch, as: relative) } catch { return .failure(error) }
        return result
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

    private func collectScreenshot(_ t: VMTarget, displays: Bool, state: VMController.State, _ bundle: DiagnosticsBundle, _ log: DiagnosticsLog) async {
        guard displays else {
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
    nonisolated func boundedHelperCall(_ agent: AgentClient, _ agentOp: String, _ fields: [String: JSON], vm: String, op: String,
                                       turn: Duration, total: Duration) async -> HelperReply {
        let start = ContinuousClock.now
        let probe = startHelperCall(agent, agentOp, fields, vm: vm, turnBy: start + turn)
        guard let outcome = await probe.answer.outcome(until: start + max(turn, total)) else {
            let phase = await probe.answer.phase
            probe.abandon()
            if case .sent = phase {
                return .unanswered("the UI helper in '\(vm)' did not answer \(op) within \(Int(total.components.seconds)) s; run vm.doctor and retry")
            }
            return .busy
        }
        switch outcome.result {
        case .success(let reply): return .answered(reply)
        case .failure(let error):
            if error is HelperBusy { return .busy }
            return .failed(agentFailure(error, vm: vm, op: op).description)
        }
    }

    /// The reply of a helper step as the sentence of its failure; nil for an answer.
    private nonisolated func helperFailure(_ result: Result<HelperReply, Error>, step: String, limit: Duration) -> String? {
        switch result {
        case .success(.answered): return nil
        case .success(.failed(let sentence)), .success(.unanswered(let sentence)): return sentence
        case .success(.busy): return ControlHandler.busyHelperSentence
        case .failure(let error): return diagnosticsSentence(error, step: step, limit: limit)
        }
    }

    /// `windows.json`, then `ui-tree.txt`: the two calls to the UI helper follow each other, each with its own limits.
    /// A window list that was sent and is not answered keeps the helper, and the tree is not asked for then.
    private func collectHelperSteps(_ t: VMTarget, _ bundle: DiagnosticsBundle, _ log: DiagnosticsLog) async {
        let windowsLimit = DiagnosticsTiming.windows + DiagnosticsTiming.grace
        let listed: Result<HelperReply, Error> = await timed(windowsLimit) {
            let agent = try await self.uiAgent(t, op: "vm.window.list")
            return await self.boundedHelperCall(agent, "win.list", [:], vm: t.name, op: "vm.window.list",
                                                turn: DiagnosticsTiming.windowsTurn, total: DiagnosticsTiming.windows)
        }
        if case .success(.answered(let r)) = listed {
            let windows = r["windows"]?.arrayValue ?? []
            log.update {
                $0.windows = windows
                $0.foreground = windows.first { $0["foreground"]?.boolValue == true }?["title"]?.stringValue
            }
            bundle.put(ControlHandler.prettyJSON(["windows": .array(windows)]), "windows.json", step: "windows", log: log)
        } else if let sentence = helperFailure(listed, step: "windows", limit: windowsLimit) {
            bundle.fail("windows", stem: "windows", sentence, log: log)
        }
        if case .success(.unanswered) = listed {
            bundle.fail("ui-tree", stem: "ui-tree", ControlHandler.treeAfterUnansweredWindows, log: log)
            return
        }

        let treeLimit = DiagnosticsTiming.tree + DiagnosticsTiming.grace
        let tree: Result<HelperReply, Error> = await timed(treeLimit) {
            let agent = try await self.uiAgent(t, op: "vm.ui.tree")
            let request: [String: JSON] = ["window": "foreground", "filter": "all", "max": .int(Int64(DiagnosticsLimits.treeNodes))]
            return await self.boundedHelperCall(agent, "ui.tree", request, vm: t.name, op: "vm.ui.tree",
                                                turn: DiagnosticsTiming.treeTurn, total: DiagnosticsTiming.tree)
        }
        if case .success(.answered(let r)) = tree {
            var text = UITreeText.render(r["nodes"]?.arrayValue ?? [])
            if r["truncated"]?.boolValue == true { text += "\n… more elements; call vm.ui.tree to read the whole window" }
            if let title = r["window"]?["title"]?.stringValue { log.update { $0.foreground = $0.foreground ?? title } }
            bundle.put(text + "\n", "ui-tree.txt", step: "ui-tree", log: log)
        } else if let sentence = helperFailure(tree, step: "ui-tree", limit: treeLimit) {
            bundle.fail("ui-tree", stem: "ui-tree", sentence, log: log)
        }
    }

    /// `row` with the secret-looking assignments of its `command` masked.
    nonisolated static func maskedCommand(_ row: JSON) -> JSON {
        guard var fields = row.objectValue, let command = fields["command"]?.stringValue else { return row }
        fields["command"] = .string(TraceSanitizer.maskAssignments(command))
        return .object(fields)
    }

    private func collectProcesses(_ t: VMTarget, processName: String?, _ bundle: DiagnosticsBundle, _ log: DiagnosticsLog) async {
        var request: [String: JSON] = ["name": .string(t.name)]
        if let processName { request["filter"] = .string(processName) }
        let params = JSON.object(request)
        let result = await timed(DiagnosticsTiming.processes) { try await self.shell(op: "vm.process.list", params: params) }
        switch result {
        case .success(let json):
            let rows = (json["processes"]?.arrayValue ?? []).map(ControlHandler.maskedCommand)
            log.update { $0.processes = rows }
            bundle.put(ControlHandler.prettyJSON(["processes": .array(rows)]), "processes.json", step: "processes", log: log)
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
            let atLeast = json["truncated"]?.boolValue == true || entries.count >= DiagnosticsLimits.eventLogEntries
            log.update {
                $0.logCounts[name] = DiagnosticsLog.LogCount(count: entries.count, atLeast: atLeast, newest: entries.first?["message"]?.stringValue)
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
        let jobs = rows.compactMap { row in row["job"]?.stringValue.map { (id: $0, row: row, file: names.claim($0, fallback: "job", suffix: ".txt")) } }
        await withTaskGroup(of: Void.self) { group in
            for job in jobs {
                group.addTask {
                    let remaining = max(.seconds(1), ContinuousClock.now.duration(to: deadline))
                    let result = await self.timed(remaining) { try await self.readJob(t.name, job.id) }
                    let step = "jobs/\(job.file)"
                    switch result {
                    case .success(let tail):
                        if tail.cutOut || tail.cutErr || tail.dropped { log.update { $0.cutJobs.append(job.file) } }
                        bundle.put(ControlHandler.jobText(job.id, job.row, tail), step, step: step, log: log)
                    case .failure(let error):
                        bundle.fail(step, stem: step, self.diagnosticsSentence(error, step: step, limit: remaining), log: log)
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

    /// The end of each stream of `job`, read from offset 0 without consuming anything: the whole stream when it has at
    /// most `DiagnosticsLimits.jobBytes` bytes, otherwise its last bytes within that number from a line start.
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
        if tail.cutOut { tail.out = ControlHandler.fromLineStart(tail.out) }
        if tail.cutErr { tail.err = ControlHandler.fromLineStart(tail.err) }
        return tail
    }

    /// `data` from the start of its second line when it holds one; data that is a single line loses only the leading
    /// bytes that continue a UTF-8 character begun before it.
    nonisolated static func fromLineStart(_ data: Data) -> Data {
        if let newline = data.firstIndex(of: 0x0A), data.index(after: newline) < data.endIndex {
            return Data(data[data.index(after: newline)...])
        }
        return Data(data.drop { $0 & 0xC0 == 0x80 })
    }

    nonisolated static func jobText(_ id: String, _ row: JSON, _ tail: JobTail) -> String {
        var head = "job \(id)"
        if let state = row["state"]?.stringValue {
            head += ": \(state)"
            if let code = row["code"]?.intValue { head += ", code \(code)" }
        }
        var text = head + "\n"
        if let cmd = row["cmd"]?.stringValue { text += "command: \(TraceSanitizer.maskAssignments(cmd))\n" }
        if let started = row["started"]?.stringValue { text += "started: \(started)\n" }
        if tail.dropped { text += "the guest no longer holds the oldest output of this job\n" }
        let limit = DiagnosticsLimits.jobBytes
        text += "--- stdout\(tail.cutOut || tail.dropped ? " (its end, at most \(limit) bytes)" : "") ---\n" + String(decoding: tail.out, as: UTF8.self) + "\n"
        text += "--- stderr\(tail.cutErr || tail.dropped ? " (its end, at most \(limit) bytes)" : "") ---\n" + String(decoding: tail.err, as: UTF8.self) + "\n"
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
                        do { return try await self.readTextReply(t, params) } catch { throw self.agentFailure(error, vm: t.name, op: "vm.fs.read") }
                    }
                    let step = "logs/\(item.file)"
                    switch result {
                    case .success(let read):
                        let whole = read.reply["text"]?.stringValue ?? ""
                        let size = read.reply["size"]?.intValue ?? 0
                        let text = ControlHandler.cappedTail(whole, bytes: DiagnosticsLimits.logBytes)
                        let lines = text.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
                        if text.isEmpty, size > 0 {
                            log.note("\(step): the guest file has \(size) bytes but no complete line in its last \(DiagnosticsLimits.logBytes) bytes")
                        } else if text.utf8.count < whole.utf8.count || (lines < DiagnosticsLimits.logLines && size - read.bytes > 2) {
                            log.note("\(step): \(lines) lines, fewer than \(DiagnosticsLimits.logLines), because a log tail holds at most \(DiagnosticsLimits.logBytes) bytes")
                        }
                        bundle.put(text, step, step: step, log: log)
                    case .failure(let error):
                        bundle.fail(step, stem: step, self.diagnosticsSentence(error, step: step, limit: limit), log: log)
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

    /// The dumps written in the last `since` minutes of the guest's clock and those without a readable time, newest
    /// first, within the dump budget. The guest's clock is the one its listing reports, or the host's when the listing
    /// reports none. A dump is pulled only while the size the guest reports for it at that moment fits what is left of the budget.
    private func collectDumps(_ t: VMTarget, since: Int, _ bundle: DiagnosticsBundle, _ log: DiagnosticsLog) async {
        let deadline = ContinuousClock.now + DiagnosticsTiming.dumps
        let base: JSON = ["name": .string(t.name)]
        let listLimit = min(DiagnosticsTiming.dumpList, DiagnosticsTiming.dumps)
        let listed = await timed(listLimit) {
            let reply = try await self.crashDumpsReply(op: "vm.crash_dumps.list", params: base)
            return (rows: reply.result["dumps"]?.arrayValue ?? [], guestNow: reply.guestNow)
        }
        let all: [DumpRow]
        var now = wallClock()
        switch listed {
        case .success(let reply):
            all = reply.rows.map {
                DumpRow(file: $0["file"]?.stringValue ?? "", bytes: $0["bytes"]?.intValue ?? 0, time: $0["time"]?.stringValue ?? "")
            }
            if let guestNow = reply.guestNow.flatMap(ControlHandler.guestTime) { now = guestNow }
        case .failure(let error):
            bundle.fail("dumps", stem: "dumps", diagnosticsSentence(error, step: "dumps", limit: listLimit), log: log)
            return
        }
        let cutoff = now.addingTimeInterval(-Double(since) * 60)
        func newestFirst(_ a: DumpRow, _ b: DumpRow) -> Bool {
            (ControlHandler.guestTime(a.time) ?? .distantPast) > (ControlHandler.guestTime(b.time) ?? .distantPast)
        }
        func isOlder(_ row: DumpRow) -> Bool { ControlHandler.guestTime(row.time).map { $0 < cutoff } ?? false }
        let recent = all.filter { !isOlder($0) }.sorted(by: newestFirst)
        let older = all.filter(isOlder).sorted(by: newestFirst)
        if let newest = older.first { log.update { $0.olderDumps = (older.count, newest.time) } }
        let budget = DiagnosticsLimits.dumpBudget
        let (take, skipped) = ControlHandler.selectDumps(recent, budget: budget)
        let advice = "pull it with vm.crash_dumps.pull"
        var found = skipped.map { DiagnosticsLog.Dump(file: $0.file, bytes: $0.bytes, time: $0.time,
                                                      outcome: "not collected: it does not fit the \(budget / 1_048_576) MiB dump budget; \(advice)") }
        var names = DiagnosticsNames()
        var left = budget
        for row in take {
            let file = names.claim(row.file, fallback: "dump.dmp")
            let step = "dumps/\(file)"
            func missed(_ sentence: String) {
                found.append(.init(file: row.file, bytes: row.bytes, time: row.time, outcome: "not collected: " + sentence))
                bundle.fail(step, stem: step, sentence, log: log)
            }
            guard ControlHandler.isWindowsFileName(row.file, suffix: ".dmp") else {
                missed("the guest listed a name that is no .dmp file name; list the dumps with vm.crash_dumps.list")
                continue
            }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else {
                missed("the dump step ran out of time before this dump; \(advice)")
                continue
            }
            let allowed = left
            let pulled = await collectFile(step, limit: remaining + DiagnosticsTiming.grace, bundle) { scratch in
                do {
                    return try await self.pullDump(t, file: row.file, to: scratch.path, deadline: deadline, maxBytes: allowed)
                } catch let error as TransferTooLarge {
                    throw error
                } catch {
                    throw self.agentFailure(error, vm: t.name, op: "vm.crash_dumps.pull")
                }
            }
            switch pulled {
            case .success(let r):
                left -= r["bytes"]?.intValue ?? row.bytes
                found.append(.init(file: row.file, bytes: row.bytes, time: row.time, outcome: "collected as \(step)"))
            case .failure(let error as TransferTooLarge):
                found.append(.init(file: row.file, bytes: row.bytes, time: row.time,
                                   outcome: "not collected: it holds \(error.bytes) bytes or more now, and \(error.limit) bytes are left of the \(budget / 1_048_576) MiB dump budget; \(advice)"))
            case .failure(let error):
                missed(diagnosticsSentence(error, step: step, limit: remaining))
            }
        }
        log.update { $0.dumps = found }
    }

    // MARK: - recording

    /// The recording the bundle uses: the VM's active one; else the one that is ending, once it ended or
    /// `DiagnosticsTiming.recordingEnd` passed; else the one that ended last when that was within `since` minutes.
    private func bundleRecording(_ vm: String, since: Int, collected: Date) async -> BundleRecording? {
        if let active = recordings.active[vm], await active.isActive { return .running(active) }
        if let recording = recordings.active[vm] ?? recordings.retiring[vm] {
            if case .success(let summary?) = await timed(DiagnosticsTiming.recordingEnd, { await recording.ending() }) {
                return .ended(LastRecording(recording, summary: summary))
            }
            return .ending(recording)
        }
        guard let latest = recordings.latest[vm], collected.timeIntervalSince(latest.ended) <= Double(since) * 60 else { return nil }
        return .ended(latest)
    }

    private func collectRecording(_ vm: String, since: Int, collected: Date, _ bundle: DiagnosticsBundle, _ log: DiagnosticsLog) async {
        guard let chosen = await bundleRecording(vm, since: since, collected: collected) else {
            log.update { $0.recording = "none in the last \(since) minutes" }
            return
        }
        let directory: URL
        let video: Bool
        switch chosen {
        case .running(let r):
            directory = r.directory
            video = r.video
            log.update { $0.recording = "\(r.directory.path) (running)" }
        case .ended(let last):
            directory = last.directory
            video = last.video
            let ended = ISO8601DateFormatter().string(from: last.ended)
            guard FileManager.default.fileExists(atPath: directory.path) else {
                log.update { $0.recording = "\(directory.path) (ended \(ended); its folder no longer exists)" }
                return
            }
            log.update { $0.recording = "\(directory.path) (ended \(ended))" }
        case .ending(let r):
            directory = r.directory
            video = r.video
            log.update { $0.recording = "\(r.directory.path) (ending)" }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.collectTrace(directory, bundle, log) }
            if video { group.addTask { await self.collectVideo(chosen, bundle, log) } }
        }
    }

    /// `trace.jsonl` and the frame files its lines refer to.
    private nonisolated func collectTrace(_ directory: URL, _ bundle: DiagnosticsBundle, _ log: DiagnosticsLog) async {
        let source = directory.appendingPathComponent(TraceWriter.traceName)
        let limit = DiagnosticsTiming.trace
        let cap = DiagnosticsLimits.traceBytes
        let read = await timed(limit) { try ControlHandler.wholeLines(of: source, limit: cap) }
        let lines: Data
        switch read {
        case .success(let tail):
            lines = tail.data
            if tail.leftOut > 0 {
                log.note("trace.jsonl: the first \(tail.leftOut) bytes of the trace are left out; the bundle holds its newest whole lines within \(cap / 1_048_576) MiB")
            }
            guard bundle.put(lines, "trace.jsonl", step: "trace", log: log) else { return }
        case .failure(let error):
            bundle.fail("trace", stem: "trace", diagnosticsSentence(error, step: "trace", limit: limit), log: log)
            return
        }

        let framesLimit = DiagnosticsTiming.frames
        let budget = DiagnosticsLimits.frameBytes
        let scratch = bundle.scratch()
        do { try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false) } catch {
            bundle.fail("frames", stem: "frames", "could not write frames: \(ControlHandler.failureReason(error, fallback: "the disk write failed")); free disk space or choose another dir", log: log)
            return
        }
        let copied = await timed(framesLimit + DiagnosticsTiming.grace) {
            let references = ControlHandler.frameReferences(inTrace: lines)
            let count = try ControlHandler.copyFrames(references, from: directory, to: scratch, budget: budget, until: .now + framesLimit)
            return (copied: count, referenced: references.count)
        }
        switch copied {
        case .success(let frames):
            guard frames.referenced > 0 else { return }
            if frames.copied > 0 {
                do { try bundle.adopt(scratch, as: TraceWriter.framesName) } catch {
                    bundle.fail("frames", stem: "frames", "could not write frames: \(ControlHandler.failureReason(error, fallback: "the disk write failed")); free disk space or choose another dir", log: log)
                    return
                }
            }
            log.update { $0.frames = frames }
        case .failure(let error):
            bundle.fail("frames", stem: "frames", diagnosticsSentence(error, step: "frames", limit: framesLimit), log: log)
        }
    }

    /// The frame paths the lines of a trace refer to in `before` and `after`, each once, those of the newest line first.
    nonisolated static func frameReferences(inTrace data: Data) -> [String] {
        var seen: Set<String> = []
        var references: [String] = []
        for line in data.split(separator: 0x0A).reversed() {
            guard let entry = try? JSON.parse(Data(line)) else { continue }
            for key in ["after", "before"] {
                if let path = entry[key]?.stringValue, seen.insert(path).inserted { references.append(path) }
            }
        }
        return references
    }

    /// The file a frame path of a trace names: `frames/<name>` below `directory`, when that file lies in the frames
    /// folder of the recording with every link resolved, and that folder lies directly in the resolved recording directory;
    /// nil for any other path.
    nonisolated static func frameFile(_ reference: String, in directory: URL) -> URL? {
        let parts = reference.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[0] == TraceWriter.framesName, !parts[1].isEmpty, parts[1] != ".", parts[1] != ".." else { return nil }
        let root = directory.resolvingSymlinksInPath()
        let folder = directory.appendingPathComponent(TraceWriter.framesName).resolvingSymlinksInPath()
        let file = folder.appendingPathComponent(parts[1]).resolvingSymlinksInPath()
        guard folder.deletingLastPathComponent().path == root.path, folder.lastPathComponent == TraceWriter.framesName,
              file.deletingLastPathComponent().path == folder.path, file.lastPathComponent == parts[1] else { return nil }
        return file
    }

    /// Copies the frame files of `references` from the recording in `directory` into the folder `destination`, in the
    /// given order, while their sizes add up to at most `budget`; a frame that does not fit, has no file or names a
    /// path outside the recording's frames folder is left out. Stops at `deadline`. Returns the number of files copied.
    nonisolated static func copyFrames(_ references: [String], from directory: URL, to destination: URL, budget: Int,
                                       until deadline: ContinuousClock.Instant) throws -> Int {
        var copied = 0
        var total = 0
        for reference in references {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { break }
            guard let source = frameFile(reference, in: directory),
                  let size = (try? source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])).flatMap({ $0.isRegularFile == true ? $0.fileSize : nil }),
                  total + size <= budget else { continue }
            guard (try? FileManager.default.copyItem(at: source, to: destination.appendingPathComponent(source.lastPathComponent))) != nil else { continue }
            total += size
            copied += 1
        }
        return copied
    }

    private func videoSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }

    /// The sentence for a video of `bytes` bytes that a bundle does not take; nil when it takes it.
    private nonisolated func oversizedVideo(_ bytes: Int, in directory: URL) -> String? {
        let limit = DiagnosticsLimits.videoBytes
        guard bytes > limit else { return nil }
        let megabytes = (bytes + 1_048_575) / 1_048_576
        return "the video in \(directory.path) is \(megabytes) MB, more than the \(limit / 1_048_576) MB a bundle takes; copy it from there"
    }

    /// `video.mp4`: the whole video of a recording that ended, or of a running recording the bytes its file held when
    /// the copy began, provided they open as a video. A recording that ends during that copy is waited for and its
    /// whole video copied; the two copies together take `DiagnosticsTiming.video` at most.
    private func collectVideo(_ chosen: BundleRecording, _ bundle: DiagnosticsBundle, _ log: DiagnosticsLog) async {
        func fail(_ sentence: String) { bundle.fail("video", stem: "video", sentence, log: log) }
        let limit = DiagnosticsTiming.video
        var left = limit
        var ended: LastRecording?
        switch chosen {
        case .ending(let recording):
            fail("the recording in \(recording.directory.path) has not ended within \(Int(DiagnosticsTiming.recordingEnd.components.seconds)) s; its video is complete there when vm.record.stop has returned")
            return
        case .ended(let last):
            ended = last
        case .running(let recording):
            let directory = recording.directory
            let source = directory.appendingPathComponent("video.mp4")
            let bytes = videoSize(source)
            if let sentence = oversizedVideo(bytes, in: directory) { return fail(sentence) }
            let scratch = bundle.scratch(".mp4")
            let began = ContinuousClock.now
            let copied = await timed(limit) {
                let notYet = ControlError.failed("the recording in \(directory.path) has not written a playable part of its video yet; collect again in a few seconds")
                guard bytes > 0 else { throw notYet }
                try ControlHandler.copyStart(of: source, bytes: bytes, to: scratch)
                guard await VideoRecorder.isPlayable(scratch) else { throw notYet }
            }
            if await recording.isActive {
                switch copied {
                case .success:
                    do { try bundle.adopt(scratch, as: "video.mp4") } catch {
                        return fail("could not write video.mp4: \(ControlHandler.failureReason(error, fallback: "the disk write failed")); free disk space or choose another dir")
                    }
                    if let error = recording.videoError {
                        log.note("video.mp4: copied up to the point where the video writer failed (\(error))")
                    } else {
                        log.note("video.mp4: copied while recording, up to the last second may be missing")
                    }
                case .failure(let error):
                    try? FileManager.default.removeItem(at: scratch)
                    fail(diagnosticsSentence(error, step: "video", limit: limit))
                }
                return
            }
            try? FileManager.default.removeItem(at: scratch)
            left = limit - began.duration(to: .now)
            guard case .success(let summary?) = await timed(DiagnosticsTiming.recordingEnd, { await recording.ending() }) else {
                return await collectVideo(.ending(recording), bundle, log)
            }
            log.update { $0.recording = "\(directory.path) (ended \(ISO8601DateFormatter().string(from: summary.ended)))" }
            ended = LastRecording(recording, summary: summary)
        }
        guard let ended else { return }
        let source = ended.directory.appendingPathComponent("video.mp4")
        let bytes = videoSize(source)
        var usable = bytes > 0
        if usable, ended.videoError != nil { usable = await VideoRecorder.isPlayable(source) }
        guard usable else {
            return fail("the recording ended without a playable video; check lastWriteError of vm.record.stop and record again")
        }
        if let sentence = oversizedVideo(bytes, in: ended.directory) { return fail(sentence) }
        guard left > .zero else { return fail(diagnosticsSentence(DiagnosticsTimeout(), step: "video", limit: limit)) }
        let copied = await collectFile("video.mp4", limit: left, bundle) { scratch in
            try ControlHandler.copyStart(of: source, bytes: bytes, to: scratch)
        }
        switch copied {
        case .success:
            if let error = ended.videoError { log.note("video.mp4: copied up to the point where the video writer failed (\(error))") }
        case .failure(let error):
            fail(diagnosticsSentence(error, step: "video", limit: limit))
        }
    }

    /// Writes the first `bytes` bytes of the file at `source` to a new file at `destination`. A cancelled task stops
    /// between pieces, removes the file and throws `CancellationError`.
    nonisolated static func copyStart(of source: URL, bytes: Int, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let output = try FileHandle(forWritingTo: destination)
        do {
            var left = bytes
            while left > 0 {
                try Task.checkCancellation()
                guard let piece = try input.read(upToCount: min(left, 4 * 1024 * 1024)), !piece.isEmpty else { break }
                try output.write(contentsOf: piece)
                left -= piece.count
            }
            try output.close()
            try Task.checkCancellation()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// The whole lines among the last `limit` bytes of the file at `url`, as far as it reached when this call began, and
    /// the number of bytes of the file before them; a line that is not finished yet, and a first line the limit cut,
    /// are left out.
    nonisolated static func wholeLines(of url: URL, limit: Int) throws -> (data: Data, leftOut: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        var start = max(0, size - limit)
        try handle.seek(toOffset: UInt64(start))
        var data = try handle.read(upToCount: size - start) ?? Data()
        if start > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else { return (Data(), size) }
            let skipped = data.distance(from: data.startIndex, to: newline) + 1
            data = Data(data[data.index(after: newline)...])
            start += skipped
        }
        guard let last = data.lastIndex(of: 0x0A) else { return (Data(), start) }
        return (Data(data[...last]), start)
    }

    // MARK: - summary

    nonisolated static func oneLine(_ text: String, limit: Int = 200) -> String {
        let flat = text.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F || $0.value == 0x2028 || $0.value == 0x2029 ? " " : String($0) }.joined()
        let squeezed = flat.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return squeezed.count > limit ? String(squeezed.prefix(limit)) + "…" : squeezed
    }

    private static let stepOrder = ["screenshot", "windows", "ui-tree", "processes", "eventlog-application", "eventlog-system", "events", "jobs",
                                    "logs", "dumps", "doctor", "trace", "frames", "video", "summary"]

    /// The text of `summary.txt`. A fact whose step failed is reported as `<topic>: unknown (<step> failed)`.
    nonisolated static func diagnosticsSummary(vm: String, collected: Date, os: VMConfig.GuestOS, since: Int, processName: String?,
                                               _ state: DiagnosticsLog.State) -> String {
        var lines = ["VM \(vm), collected \(ISO8601DateFormatter().string(from: collected)), guest \(os.rawValue)"]
        let failed = Set(state.failures.map(\.step))
        func unknown(_ topic: String, _ step: String) { if failed.contains(step) { lines.append("\(topic): unknown (\(step) failed)") } }
        if let windows = state.windows {
            let stuck = windows.filter { $0["responding"]?.boolValue == false }
            if stuck.isEmpty { lines.append("windows not responding: none") }
            for window in stuck {
                let process = window["process"]?.stringValue.map { ", " + oneLine($0, limit: 60) } ?? ""
                lines.append("window not responding: \(window["id"]?.stringValue ?? "?") \(UITreeText.quoted(oneLine(window["title"]?.stringValue ?? "", limit: 120))) (pid \(window["pid"]?.intValue ?? 0)\(process))")
            }
        } else {
            unknown("windows not responding", "windows")
        }
        if let title = state.foreground {
            lines.append("foreground window: \(UITreeText.quoted(oneLine(title, limit: 120)))")
        } else if state.windows != nil {
            lines.append("foreground window: none")
        } else {
            unknown("foreground window", "windows")
        }
        if let dumps = state.dumps {
            if dumps.isEmpty { lines.append("crash dumps: none newer than \(since) minutes") }
            for dump in dumps {
                lines.append("crash dump \(oneLine(dump.file, limit: 120)): \(dump.bytes) bytes, \(oneLine(dump.time, limit: 40)), \(dump.outcome)")
            }
            if let older = state.olderDumps {
                lines.append("crash dumps older than \(since) minutes: \(older.count) left out, the newest from \(oneLine(older.newest, limit: 40))")
            }
        } else {
            unknown("crash dumps", "dumps")
        }
        for (name, stem) in [("Application", "eventlog-application"), ("System", "eventlog-system")] {
            guard let found = state.logCounts[name] else {
                unknown("event log \(name)", stem)
                continue
            }
            let count = "\(found.atLeast ? "at least " : "")\(found.count) \(found.count == 1 && !found.atLeast ? "entry" : "entries")"
            lines.append("event log \(name): \(count) of level error or worse in the last \(since) minutes" + (found.newest.map { "; newest: " + oneLine($0) } ?? ""))
        }
        if let jobs = state.failedJobs {
            if jobs.isEmpty { lines.append("jobs exited with a non-zero code: none") }
            for job in jobs { lines.append("job \(oneLine(job.job, limit: 40)) exited with code \(job.code)") }
        } else {
            unknown("jobs exited with a non-zero code", "jobs")
        }
        if !state.cutJobs.isEmpty {
            lines.append(oneLine("job files that hold only the end of a stream, at most \(DiagnosticsLimits.jobBytes) bytes: \(state.cutJobs.sorted().joined(separator: ", "))", limit: 400))
        }
        if let processName {
            let name = oneLine(processName, limit: 80)
            if let rows = state.processes {
                let pids = rows.compactMap { $0["pid"]?.intValue }
                lines.append(pids.isEmpty ? "process \(name): not running" : "process \(name): running, pid \(pids.prefix(5).map(String.init).joined(separator: ", "))")
            } else {
                unknown("process \(name)", "processes")
            }
        }
        if let recording = state.recording { lines.append("recording: \(oneLine(recording, limit: 400))") }
        if let frames = state.frames {
            lines.append("frames: \(frames.copied) of \(frames.referenced) copied")
        } else {
            unknown("frames", "frames")
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
