import Foundation
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP

/// Guest settings and health checks that run as scripts through the agent's `exec.run`.
extension ControlHandler {
    private static let settingOrder = ["clock", "timeZone", "locale", "keyboardLayouts", "theme", "dpiScale"]
    private static let recipeTimeoutMilliseconds = 60_000
    private static let minimumFreeBytes: Int64 = 2 * 1024 * 1024 * 1024
    private static let maximumClockSkew: TimeInterval = 5

    func guest(op: String, params: JSON) async throws -> JSON {
        switch op {
        case "vm.set_environment": return try await setEnvironment(params)
        case "vm.doctor": return try await doctor(params)
        case "vm.event_log": return try await eventLog(params)
        default: return try await crashDumps(op: op, params: params)
        }
    }

    // MARK: - vm.set_environment

    private func setEnvironment(_ params: JSON) async throws -> JSON {
        let requested = ControlHandler.settingOrder.filter { params[$0].map { $0 != .null } ?? false }
        guard !requested.isEmpty else {
            throw ControlError.failed("pass at least one of theme, timeZone, clock, locale, keyboardLayouts, dpiScale")
        }
        let (clock, timeZone, locale, layouts, dark, scale) = try validatedSettings(params)
        let t = try await running(params)
        let os = await t.guestOS()
        let agent = try await execAgent(t, op: "vm.set_environment")
        var rows: [JSON] = []
        for setting in requested {
            let script: String?
            var takesEffect = "now"
            switch setting {
            case "clock": script = clock.flatMap { GuestRecipes.setClock(unixSeconds: $0, os: os) }
            case "timeZone": script = timeZone.flatMap { GuestRecipes.setTimeZone($0, os: os) }
            case "locale":
                script = locale.flatMap { GuestRecipes.setLocale($0, os: os) }
                takesEffect = os == .windows ? "app restart" : "now"
            case "keyboardLayouts": script = layouts.flatMap { GuestRecipes.setKeyboardLayouts($0, os: os) }
            case "theme": script = dark.flatMap { GuestRecipes.setTheme(dark: $0, os: os) }
            default:
                script = scale.flatMap { GuestRecipes.setDPIScale(percent: $0, os: os) }
            }
            guard let script else {
                rows.append(["setting": .string(setting), "ok": false, "detail": .string(unsupportedDetail(os)), "takesEffect": "now"])
                continue
            }
            var result = await runRecipe(agent, script, vm: t.name, op: "vm.set_environment")
            if setting == "dpiScale", result.ok, let scale {
                let read = GuestRecipes.dpiScaleResult(requested: scale, output: result.stdout)
                result = (read.ok, read.detail, result.stdout)
            }
            rows.append(["setting": .string(setting), "ok": .bool(result.ok), "detail": .string(result.detail), "takesEffect": .string(takesEffect)])
        }
        return ["applied": .array(rows)]
    }

    private func unsupportedDetail(_ os: VMConfig.GuestOS) -> String {
        os == .other ? "not supported on this guest OS" : "not supported on \(os.rawValue) guests"
    }

    /// The validated values of the settings in `params`: clock as Unix seconds, time zone, locale, keyboard layouts, dark theme, scale percent.
    private func validatedSettings(_ params: JSON) throws -> (Int?, String?, String?, [String]?, Bool?, Int?) {
        func present(_ key: String) -> JSON? { params[key].flatMap { $0 == .null ? nil : $0 } }
        func text(_ key: String) throws -> String? {
            guard let value = present(key) else { return nil }
            guard let s = value.stringValue, !s.isEmpty else { throw ControlError.missing(key) }
            return s
        }
        var dark: Bool?
        if let theme = present("theme") {
            switch theme.stringValue {
            case "dark": dark = true
            case "light": dark = false
            default: throw ControlError.failed("theme must be 'dark' or 'light'")
            }
        }
        var scale: Int?
        if let value = present("dpiScale") {
            guard let percent = value.intValue else { throw ControlError.missing("dpiScale") }
            guard (100...500).contains(percent) else { throw ControlError.failed("dpiScale must be between 100 and 500") }
            scale = percent
        }
        var layouts: [String]?
        if let value = present("keyboardLayouts") {
            guard let items = value.arrayValue else { throw ControlError.missing("keyboardLayouts") }
            let tags = items.compactMap(\.stringValue)
            guard !tags.isEmpty, tags.count == items.count else {
                throw ControlError.failed("keyboardLayouts must be a non-empty list of language tags such as en-US")
            }
            guard tags.allSatisfy(Self.isLanguageTag) else {
                throw ControlError.failed("keyboardLayouts entries must be language tags such as en-US (letters, digits and '-', 2 to 35 characters, not starting with '-')")
            }
            layouts = tags
        }
        var clock: Int?
        if let value = present("clock") {
            guard let s = value.stringValue else { throw ControlError.missing("clock") }
            clock = Int(try clockDate(s).timeIntervalSince1970.rounded(.down))
        }
        let timeZone = try text("timeZone")
        if let timeZone, !Self.isTimeZoneID(timeZone) {
            throw ControlError.failed("timeZone must be 1 to 64 characters: letters, digits, space and _ - + / ( ) . :, not starting with '-'")
        }
        let locale = try text("locale")
        if let locale, !Self.isLanguageTag(locale) {
            throw ControlError.failed("locale must be a language tag such as ko-KR (letters, digits and '-', 2 to 35 characters, not starting with '-')")
        }
        return (clock, timeZone, locale, layouts, dark, scale)
    }

    private static func isTimeZoneID(_ s: String) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 _-+/().:".unicodeScalars)
        return (1...64).contains(s.unicodeScalars.count) && !s.hasPrefix("-") && s.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isLanguageTag(_ s: String) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-".unicodeScalars)
        return (2...35).contains(s.unicodeScalars.count) && !s.hasPrefix("-") && s.unicodeScalars.allSatisfy(allowed.contains)
    }

    private func clockDate(_ text: String) throws -> Date {
        if text == "host" { return wallClock() }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = plain.date(from: text) ?? fractional.date(from: text) else {
            throw ControlError.failed("clock must be 'host' or an ISO 8601 time such as 2026-10-13T09:30:00Z")
        }
        return date
    }

    // MARK: - shared helpers

    /// The agent of `t`, checked for request/response support and the `exec` capability.
    private func execAgent(_ t: VMTarget, op: String) async throws -> AgentClient {
        let agent = try await tools(t)
        guard let hello = await agent.hello, hello.rpcVersion >= 2 else { throw ControlError.toolsTooOld(vm: t.name, op: op) }
        guard hello.capabilities.contains("exec") else {
            throw ControlError.failed("guest tools in '\(t.name)' do not allow running commands; start alcove-agent with --allow-exec")
        }
        return agent
    }

    /// The outcome of a recipe: `answered` tells whether the agent answered the request at all, `hasText` whether the
    /// script printed anything on the stream `detail` comes from, and `truncated` is the agent's flag that it kept only
    /// the tail of an output stream.
    struct RecipeOutput {
        var ok: Bool
        var detail: String
        var stdout: String
        var timedOut = false
        var truncated = false
        var answered = true
        var hasText = true
    }

    /// Runs `script` in the guest. `ok` means exit code 0 without a timeout; `detail` is trimmed stderr on failure, trimmed stdout otherwise.
    /// The guest gets 60 s for the script.
    func runRecipe(_ agent: AgentClient, _ script: String, vm: String, op: String) async -> (ok: Bool, detail: String, stdout: String) {
        let r = await runRecipeOutput(agent, script, vm: vm, op: op)
        return (r.ok, r.detail, r.stdout)
    }

    /// Runs `script` in the guest within `limit`; without one the guest gets 60 s and the host waits 15 s longer.
    func runRecipeOutput(_ agent: AgentClient, _ script: String, vm: String, op: String, limit: RecipeLimit? = nil) async -> RecipeOutput {
        let limit = limit ?? RecipeLimit(guestMilliseconds: ControlHandler.recipeTimeoutMilliseconds, marginSeconds: 15)
        do {
            let r = try await agent.call("exec.run", ["cmd": .string(script), "timeout_ms": .int(Int64(limit.guestMilliseconds))],
                                         timeout: .seconds(limit.hostSeconds))
            let code = r["code"]?.intValue ?? -1
            let timedOut = r["timed_out"]?.boolValue ?? false
            let truncated = r["truncated"]?.boolValue ?? false
            let out = (r["stdout"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let err = (r["stderr"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = code == 0 && !timedOut
            if ok { return RecipeOutput(ok: true, detail: out, stdout: out, truncated: truncated) }
            let detail = !err.isEmpty ? err : timedOut ? "timed out after \(limit.guestMilliseconds / 1000) s" : out.isEmpty ? "exit code \(code)" : out
            return RecipeOutput(ok: false, detail: detail, stdout: out, timedOut: timedOut, truncated: truncated, hasText: !err.isEmpty || !out.isEmpty)
        } catch {
            return RecipeOutput(ok: false, detail: agentFailure(error, vm: vm, op: op).description, stdout: "", answered: false)
        }
    }

    /// Sets the guest clock to the host's on behalf of `op`; false when the guest cannot run the recipe or it fails.
    func syncGuestClock(_ t: VMTarget, agent: AgentClient, op: String) async -> Bool {
        guard let hello = await agent.hello, hello.rpcVersion >= 2, hello.capabilities.contains("exec"),
              let script = GuestRecipes.setClock(unixSeconds: Int(wallClock().timeIntervalSince1970), os: await t.guestOS()) else { return false }
        return await runRecipe(agent, script, vm: t.name, op: op).ok
    }

    // MARK: - vm.doctor

    func check(_ id: String, _ ok: Bool, _ detail: String, hint: String? = nil) -> JSON {
        var row: [String: JSON] = ["id": .string(id), "ok": .bool(ok), "detail": .string(detail)]
        if let hint, !ok { row["hint"] = .string(hint) }
        return .object(row)
    }

    private func doctor(_ params: JSON) async throws -> JSON {
        let t = try await target(params)
        let state = await t.state()
        var rows: [JSON] = [engineCheck(), check("host", true, hostKind)]
        let running = state == .running
        rows.append(check("state", running, describe(state), hint: ControlHandler.stateHint(state)))
        guard running else { return ["checks": .array(rows)] }

        if let frame = try? await screenshot(t) {
            rows.append(check("display", true, "\(frame.width)x\(frame.height)"))
        } else {
            rows.append(check("display", false, "no frame available", hint: "wait for the guest to start drawing, then retry"))
        }

        guard let agent = await t.agent(timeout: .seconds(5)), let hello = await agent.hello else {
            if let refusal = await t.agentRefusal() {
                rows.append(check("tools", false, "the guest tools refused the connection: \(refusal)", hint: ControlHandler.refusalFix(refusal)))
            } else {
                rows.append(check("tools", false, "guest tools are not connected",
                                  hint: "install alcove-agent in the guest with scripts/test/install-agent.py"))
            }
            return ["checks": .array(rows)]
        }
        rows.append(check("tools", true, "alcove-agent \(hello.agentVersion)"))
        let rpc = hello.rpcVersion >= 2
        rows.append(check("rpc", rpc, "proto \(hello.rpcVersion)", hint: "update alcove-agent in the guest with scripts/test/install-agent.py"))
        let exec = hello.capabilities.contains("exec")
        rows.append(check("exec", exec, exec ? "enabled" : "disabled", hint: "start alcove-agent with --allow-exec"))
        guard rpc, exec else { return ["checks": .array(rows)] }

        let os = await t.guestOS()
        guard let script = GuestRecipes.doctorProbe(os: os) else {
            rows.append(check("probe", false, unsupportedDetail(os), hint: "this guest OS has no health probe"))
            return ["checks": .array(rows)]
        }
        let result = await runRecipe(agent, script, vm: t.name, op: "vm.doctor")
        let received = wallClock()
        guard result.ok, let probe = Self.probeJSON(result.stdout) else {
            rows.append(check("probe", false, result.ok ? "the guest probe printed no JSON object" : result.detail,
                              hint: "check that the guest shell works with vm.exec"))
            return ["checks": .array(rows)]
        }
        rows += probeRows(probe, received: received)
        rows.append(await proxyCheck(t, agent: agent, os: os))
        return ["checks": .array(rows)]
    }

    /// The `engine` row: the engine binary the host runs VMs with, not ok when that file is no longer there.
    private func engineCheck() -> JSON {
        guard let engine = engineDescription else { return check("engine", true, "managed by the Alcove app") }
        guard engine.hasPrefix("/"), !FileManager.default.isExecutableFile(atPath: engine) else { return check("engine", true, engine) }
        return check("engine", false, "\(engine) is not there or cannot be run",
                     hint: "build the engine with scripts/build-qemu.sh, then restart alcovectl serve")
    }

    /// The next step for a VM in `state` that is not running.
    static func stateHint(_ state: VMController.State) -> String {
        switch state {
        case .paused: return "call vm.resume"
        case .starting: return "wait until vm.status shows running, then retry"
        case .stopping, .suspending: return "wait until vm.status shows stopped, then call vm.start"
        case .running, .stopped, .failed: return "call vm.start"
        }
    }

    private static func probeJSON(_ output: String) -> JSON? {
        for line in output.split(whereSeparator: \.isNewline).reversed() where line.hasPrefix("{") {
            if let json = try? JSON.parse(Data(line.utf8)), json.objectValue != nil { return json }
        }
        return nil
    }

    private func probeRows(_ probe: JSON, received: Date) -> [JSON] {
        let notChecked = "not checked on this guest"
        var rows: [JSON]
        if let user = probe["user"]?.stringValue {
            if let locked = probe["locked"]?.boolValue {
                rows = [check("session", !locked, "\(user), \(locked ? "locked" : "unlocked")",
                              hint: "unlock the guest session; vm.type the password at the lock screen")]
            } else {
                rows = [check("session", true, "\(user), lock state \(notChecked)")]
            }
        } else {
            rows = [check("session", false, "the guest reported no user", hint: "sign in to the guest and retry")]
        }
        if let free = probe["freeBytes"]?.intValue {
            rows.append(check("disk", Int64(free) >= ControlHandler.minimumFreeBytes, "\(free) bytes free", hint: "free disk space in the guest"))
        } else {
            rows.append(check("disk", true, "free space \(notChecked)"))
        }
        if let text = probe["utc"]?.stringValue, let utc = ISO8601DateFormatter().date(from: text) {
            let skew = abs(received.timeIntervalSince(utc))
            rows.append(check("clock", skew <= ControlHandler.maximumClockSkew, "skew \(Int(skew.rounded())) s", hint: "vm.set_environment clock=host"))
        } else {
            rows.append(check("clock", false, "the guest reported no valid UTC time", hint: "vm.set_environment clock=host"))
        }
        if let dns = probe["dns"]?.boolValue {
            rows.append(check("network", dns, dns ? "example.com resolves" : "example.com does not resolve",
                              hint: "call vm.set_network up=true and check the guest DNS settings"))
        } else {
            rows.append(check("network", true, "name resolution \(notChecked)"))
        }
        if let scale = probe["scale"]?.intValue {
            rows.append(check("scale", true, "\(scale) %"))
        } else {
            rows.append(check("scale", true, notChecked))
        }
        return rows
    }

    // MARK: - vm.event_log

    private static let eventLogLevels = ["critical", "error", "warning", "info"]
    private static let maximumSinceMinutes = 5_256_000
    /// The most UTF-16 units of `provider` and of `contains`.
    private static let maximumFilterLength = 1000

    private func eventLog(_ params: JSON) async throws -> JSON {
        func text(_ key: String) throws -> String? {
            guard let value = params[key], value != .null else { return nil }
            guard let s = value.stringValue else { throw ControlError.missing(key) }
            return s
        }
        let log = try text("log") ?? "Application"
        guard Self.isLogName(log) else {
            throw ControlError.failed("log must be a plain log name such as Application, System or Microsoft-Windows-PowerShell/Operational")
        }
        let level = try text("level")
        if let level, !Self.eventLogLevels.contains(level) {
            throw ControlError.failed("level must be one of \(Self.eventLogLevels.joined(separator: ", "))")
        }
        let provider = try text("provider")
        if provider?.isEmpty == true { throw ControlError.failed("provider must not be empty; leave it out to read all providers") }
        let contains = try text("contains")
        if contains?.isEmpty == true { throw ControlError.failed("contains must not be empty; leave it out to read all entries") }
        for (key, value, shorter) in [("provider", provider, "pass the provider name as the entries show it"),
                                      ("contains", contains, "pass a shorter part of the message")] {
            guard let value else { continue }
            if value.unicodeScalars.contains("\0") { throw ControlError.failed("\(key) must not hold a NUL character; remove it") }
            if value.utf16.count > Self.maximumFilterLength {
                throw ControlError.failed("\(key) must be at most \(Self.maximumFilterLength) characters; \(shorter)")
            }
        }
        let since = try optional(params, "sinceMinutes", .integer)?.intValue ?? 60
        guard (1...Self.maximumSinceMinutes).contains(since) else {
            throw ControlError.failed("sinceMinutes must be between 1 and \(Self.maximumSinceMinutes)")
        }
        let max = try optional(params, "max", .integer)?.intValue ?? 50
        guard (1...500).contains(max) else {
            throw ControlError.failed("max must be between 1 and 500; pass a smaller number or narrow with level, provider or contains")
        }
        let t = try await running(params)
        let os = await t.guestOS()
        guard let script = GuestRecipes.eventLog(log: log, level: level, provider: provider, sinceMinutes: since,
                                                 contains: contains, max: max, os: os) else {
            throw ControlError.failed("the event log is not supported on this guest OS")
        }
        let agent = try await execAgent(t, op: "vm.event_log")
        let result = await runRecipeOutput(agent, script, vm: t.name, op: "vm.event_log")
        guard result.ok else {
            if result.timedOut {
                let seconds = ControlHandler.recipeTimeoutMilliseconds / 1000
                if contains != nil {
                    throw ControlError.failed("the guest did not finish reading the event log within \(seconds) s; contains is searched in every entry of the time window, so pass a smaller sinceMinutes, a level or a provider")
                }
                throw ControlError.failed("the guest took more than \(seconds) s to read the event log; narrow it with level, provider or a smaller sinceMinutes")
            }
            if os == .linux, result.detail.contains("unrecognized option") || result.detail.contains("invalid option") {
                throw ControlError.failed("journalctl in the guest is too old for these filters; read the logs with vm.exec instead")
            }
            throw ControlError.failed(result.detail)
        }
        var entries: [JSON]
        var truncated = result.truncated
        if os == .linux {
            entries = Array(Self.journalEntries(result.stdout).prefix(max))
        } else {
            guard let parsed = Self.eventEntries(result.stdout) else {
                if result.truncated {
                    throw ControlError.failed("the guest output was cut before the host read it; pass a smaller max or a narrower sinceMinutes")
                }
                throw ControlError.failed("the guest printed no event log JSON; run vm.doctor to check the guest shell")
            }
            entries = parsed.entries
            truncated = truncated || parsed.truncated
        }
        var reply: [String: JSON] = ["entries": .array(entries)]
        if truncated { reply["truncated"] = true }
        return .object(reply)
    }

    private static func isLogName(_ s: String) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 _-./".unicodeScalars)
        return (1...255).contains(s.unicodeScalars.count) && !s.hasPrefix("-") && s.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// `s` cut at `GuestRecipes.eventMessageLimit` UTF-16 units, one less where the cut would split a surrogate pair.
    static func cutMessage(_ s: String) -> String {
        guard s.utf16.count > GuestRecipes.eventMessageLimit else { return s }
        var units = 0
        var kept = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            units += scalar.utf16.count
            guard units <= GuestRecipes.eventMessageLimit else { break }
            kept.append(scalar)
        }
        return String(kept)
    }

    /// The entries of the Windows recipe output, newest `time` first and in the output's order within one time:
    /// a `{entries, truncated}` object, an array or one entry object; nil for text that is no JSON.
    private static func eventEntries(_ output: String) -> (entries: [JSON], truncated: Bool)? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return ([], false) }
        guard let json = try? JSON.parse(Data(trimmed.utf8)) else { return nil }
        var truncated = false
        let items: [JSON]
        if let array = json.arrayValue {
            items = array
        } else if let wrapped = json["entries"]?.arrayValue {
            items = wrapped
            truncated = json["truncated"]?.boolValue ?? false
        } else if json.objectValue != nil {
            items = [json]
        } else {
            return nil
        }
        let entries = items.filter { $0.objectValue != nil }.map { item -> JSON in
            ["time": .string(item["time"]?.stringValue ?? ""), "id": .int(Int64(item["id"]?.intValue ?? 0)),
             "level": .string(item["level"]?.stringValue ?? "info"), "provider": .string(item["provider"]?.stringValue ?? ""),
             "message": .string(cutMessage(item["message"]?.stringValue ?? ""))]
        }
        let newestFirst = entries.enumerated().sorted {
            let (a, b) = ($0.element["time"]?.stringValue ?? "", $1.element["time"]?.stringValue ?? "")
            return a == b ? $0.offset < $1.offset : a > b
        }.map(\.element)
        return (newestFirst, truncated)
    }

    /// The entries of `journalctl -o json` output, one JSON object per line in time order, newest first in the result; lines that are no JSON object are skipped.
    private static func journalEntries(_ output: String) -> [JSON] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func text(_ value: JSON?) -> String? {
            if let s = value?.stringValue { return s }
            if let bytes = value?.arrayValue { return String(decoding: bytes.compactMap { $0.intValue.map { UInt8(truncatingIfNeeded: $0) } }, as: UTF8.self) }
            return nil
        }
        var entries: [(micros: Double, entry: JSON)] = []
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("{") {
            guard let json = try? JSON.parse(Data(line.utf8)), json.objectValue != nil else { continue }
            let micros = Double(text(json["__REALTIME_TIMESTAMP"]) ?? "") ?? 0
            let priority = Int(text(json["PRIORITY"]) ?? "") ?? 6
            let level = priority <= 2 ? "critical" : priority == 3 ? "error" : priority == 4 ? "warning" : "info"
            let pid = Int(text(json["_PID"]) ?? "") ?? Int(text(json["SYSLOG_PID"]) ?? "") ?? 0
            entries.append((micros, ["time": .string(formatter.string(from: Date(timeIntervalSince1970: micros / 1_000_000))),
                                     "id": .int(Int64(pid)), "level": .string(level),
                                     "provider": .string(text(json["SYSLOG_IDENTIFIER"]) ?? text(json["_COMM"]) ?? ""),
                                     "message": .string(cutMessage(text(json["MESSAGE"]) ?? ""))]))
        }
        return entries.enumerated().sorted { ($0.element.micros, $1.offset) > ($1.element.micros, $0.offset) }.map(\.element.entry)
    }

    // MARK: - vm.crash_dumps.enable, disable, list

    static let windowsOnlyDumps = "crash dumps are only collected on Windows guests"

    private func crashDumps(op: String, params: JSON) async throws -> JSON {
        try await crashDumpsReply(op: op, params: params).result
    }

    /// The result of `vm.crash_dumps.enable`, `disable` or `list`, and for `list` the guest's clock when it listed the
    /// dumps, as the first row of the recipe reports it.
    func crashDumpsReply(op: String, params: JSON) async throws -> (result: JSON, guestNow: String?) {
        var exe = ""
        if op != "vm.crash_dumps.list" {
            exe = try string(params, "exe")
            guard Self.isWindowsFileName(exe, suffix: ".exe") else {
                throw ControlError.failed("exe must be an image name such as MyApp.exe: no folder, ends with .exe, no characters that a Windows file name cannot hold")
            }
        }
        let full = try optional(params, "full", .boolean)?.boolValue ?? false
        let t = try await running(params)
        let os = await t.guestOS()
        let script: String?
        switch op {
        case "vm.crash_dumps.enable": script = GuestRecipes.enableDumps(exe: exe, full: full, os: os)
        case "vm.crash_dumps.disable": script = GuestRecipes.disableDumps(exe: exe, os: os)
        default: script = GuestRecipes.listDumps(os: os)
        }
        guard let script else { throw ControlError.failed(Self.windowsOnlyDumps) }
        let agent = try await execAgent(t, op: op)
        let result = await runRecipe(agent, script, vm: t.name, op: op)
        guard result.ok else { throw ControlError.failed(result.detail) }
        switch op {
        case "vm.crash_dumps.enable":
            let reply = Self.lastJSONObject(result.stdout)
            return (["folder": .string(reply?["folder"]?.stringValue ?? GuestRecipes.dumpFolder),
                     "createdKey": .bool(reply?["createdKey"]?.boolValue ?? false)], nil)
        case "vm.crash_dumps.disable":
            return ([:], nil)
        default:
            guard let rows = Self.dumpItems(result.stdout) else {
                throw ControlError.failed("the guest printed no crash dump list; run vm.doctor to check the guest shell")
            }
            let dumps: JSON = ["dumps": .array(rows.map { item -> JSON in
                ["file": .string(item["file"]?.stringValue ?? ""), "exe": .string(item["exe"]?.stringValue ?? ""),
                 "bytes": .int(Int64(item["bytes"]?.intValue ?? 0)), "time": .string(item["time"]?.stringValue ?? "")]
            })]
            return (dumps, rows.first?["now"]?.stringValue)
        }
    }

    /// Whether `s` is a bare Windows file name ending in `suffix` (any case) with a non-empty stem and no character
    /// a Windows file name cannot hold, whose Unicode scalars before the first dot, without trailing spaces, are no
    /// reserved device name.
    static func isWindowsFileName(_ s: String, suffix: String) -> Bool {
        let invalid = Set("<>:\"/\\|?*".unicodeScalars)
        guard s.lowercased().hasSuffix(suffix), s.count > suffix.count, s.utf16.count <= 255 else { return false }
        guard s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && !invalid.contains($0) }) else { return false }
        var stem = Array(s.unicodeScalars.prefix { $0 != "." })
        while stem.last == " " { stem.removeLast() }
        return !reservedDeviceNames.contains(String(String.UnicodeScalarView(stem)).uppercased())
    }

    private static let reservedDeviceNames: Set<String> =
        Set(["CON", "PRN", "AUX", "NUL"] + ["COM", "LPT"].flatMap { port in (0...9).map { "\(port)\($0)" } + ["\u{B9}", "\u{B2}", "\u{B3}"].map { port + $0 } })

    /// The last line of `output` that is a JSON object.
    static func lastJSONObject(_ output: String) -> JSON? {
        for line in output.split(whereSeparator: \.isNewline).reversed() where line.hasPrefix("{") {
            if let json = try? JSON.parse(Data(line.utf8)), json.objectValue != nil { return json }
        }
        return nil
    }

    /// The dump rows of the recipe output: a JSON array or one row object; nil for any other text.
    private static func dumpItems(_ output: String) -> [JSON]? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let json = try? JSON.parse(Data(trimmed.utf8)) else { return nil }
        if let array = json.arrayValue { return array.filter { $0.objectValue != nil } }
        return json.objectValue != nil ? [json] : nil
    }
}
