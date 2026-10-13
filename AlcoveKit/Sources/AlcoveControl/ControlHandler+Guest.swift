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
        op == "vm.set_environment" ? try await setEnvironment(params) : try await doctor(params)
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
                takesEffect = os == .windows ? "sign-out" : "now"
            }
            guard let script else {
                rows.append(["setting": .string(setting), "ok": false, "detail": .string(unsupportedDetail(os)), "takesEffect": "now"])
                continue
            }
            let result = await runRecipe(agent, script, vm: t.name, op: "vm.set_environment")
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

    /// Runs `script` in the guest. `ok` means exit code 0 without a timeout; `detail` is trimmed stderr on failure, trimmed stdout otherwise.
    func runRecipe(_ agent: AgentClient, _ script: String, vm: String, op: String) async -> (ok: Bool, detail: String, stdout: String) {
        do {
            let r = try await agent.call("exec.run", ["cmd": .string(script), "timeout_ms": .int(Int64(ControlHandler.recipeTimeoutMilliseconds))],
                                         timeout: .seconds(ControlHandler.recipeTimeoutMilliseconds / 1000 + 15))
            let code = r["code"]?.intValue ?? -1
            let timedOut = r["timed_out"]?.boolValue ?? false
            let out = (r["stdout"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let err = (r["stderr"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = code == 0 && !timedOut
            if ok { return (true, out, out) }
            let detail = !err.isEmpty ? err : timedOut ? "timed out after \(ControlHandler.recipeTimeoutMilliseconds / 1000) s" : out.isEmpty ? "exit code \(code)" : out
            return (false, detail, out)
        } catch {
            return (false, agentFailure(error, vm: vm, op: op).description, "")
        }
    }

    /// Sets the guest clock to the host's after a restore; false when the guest cannot run the recipe or it fails.
    func syncGuestClock(_ t: VMTarget, agent: AgentClient) async -> Bool {
        guard let hello = await agent.hello, hello.rpcVersion >= 2, hello.capabilities.contains("exec"),
              let script = GuestRecipes.setClock(unixSeconds: Int(wallClock().timeIntervalSince1970), os: await t.guestOS()) else { return false }
        return await runRecipe(agent, script, vm: t.name, op: "vm.snapshot.restore").ok
    }

    // MARK: - vm.doctor

    private func check(_ id: String, _ ok: Bool, _ detail: String, hint: String? = nil) -> JSON {
        var row: [String: JSON] = ["id": .string(id), "ok": .bool(ok), "detail": .string(detail)]
        if let hint, !ok { row["hint"] = .string(hint) }
        return .object(row)
    }

    private func doctor(_ params: JSON) async throws -> JSON {
        let t = try await target(params)
        let state = await t.state()
        var rows: [JSON] = [
            check("engine", true, engineDescription ?? "managed by the Alcove app"),
            check("host", true, hostKind),
        ]
        let running = state == .running
        rows.append(check("state", running, describe(state), hint: state == .paused ? "call vm.resume" : "call vm.start"))
        guard running else { return ["checks": .array(rows)] }

        if let png = try? await screenshot(t), let size = PNGInfo.size(of: png) {
            rows.append(check("display", true, "\(size.width)x\(size.height)"))
        } else {
            rows.append(check("display", false, "no frame available", hint: "wait for the guest to start drawing, then retry"))
        }

        guard let agent = await t.agent(timeout: .seconds(5)), let hello = await agent.hello else {
            rows.append(check("tools", false, "guest tools are not connected",
                              hint: "install alcove-agent in the guest with scripts/test/install-agent.py"))
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
        return ["checks": .array(rows)]
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
            rows.append(check("disk", false, "the guest reported no free space", hint: "check the guest shell with vm.exec"))
        }
        if let text = probe["utc"]?.stringValue, let utc = ISO8601DateFormatter().date(from: text) {
            let skew = abs(received.timeIntervalSince(utc))
            rows.append(check("clock", skew <= ControlHandler.maximumClockSkew, "skew \(Int(skew.rounded())) s", hint: "vm.set_environment clock=host"))
        } else {
            rows.append(check("clock", false, "the guest reported no valid UTC time", hint: "vm.set_environment clock=host"))
        }
        let dns = probe["dns"]?.boolValue ?? false
        rows.append(check("network", dns, dns ? "example.com resolves" : "example.com does not resolve",
                          hint: "call vm.set_network up=true and check the guest DNS settings"))
        if let scale = probe["scale"]?.intValue {
            rows.append(check("scale", true, "\(scale) % (applied at sign-in)"))
        } else {
            rows.append(check("scale", true, notChecked))
        }
        return rows
    }
}
