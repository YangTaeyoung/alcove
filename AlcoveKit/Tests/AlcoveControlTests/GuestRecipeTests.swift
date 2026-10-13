import XCTest
@testable import AlcoveControl
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

private let hostNow = Date(timeIntervalSince1970: 1_800_000_000)

private func exitReply(_ m: JSON, code: Int = 0, stdout: String = "", stderr: String = "") -> JSON {
    agentReply(m, ["code": .int(Int64(code)), "stdout": .string(stdout), "stderr": .string(stderr), "timed_out": false])
}

private func probeJSON(utc: Date, user: String = "alcove", locked: Bool = false, free: Int64 = 40_000_000_000,
                       dns: Bool = true, scale: Int = 100) -> String {
    let text = ISO8601DateFormatter().string(from: utc)
    return "{\"user\":\"\(user)\",\"locked\":\(locked),\"freeBytes\":\(free),\"utc\":\"\(text)\",\"dns\":\(dns),\"scale\":\(scale)}\r\n"
}

final class GuestRecipeTests: XCTestCase {
    private func setup(os: VMConfig.GuestOS = .windows, state: VMController.State = .running, caps: [String]? = nil,
                       engine: String? = nil, connected: Bool = true,
                       _ handler: (@Sendable (JSON, FakeAgent) -> [JSON])? = nil) async throws -> (ControlHandler, FakeTarget, FakeAgent) {
        let agent = FakeAgent()
        if let caps { agent.caps = caps }
        agent.handler = handler
        _ = agent.start()
        addTeardownBlock { agent.stop() }
        let t = FakeTarget(name: "Win", state: state, png: makePNG(width: 800, height: 600))
        await t.setOS(os)
        if connected {
            let client = AgentClient()
            try await client.connect(port: agent.port, expectedToken: nil)
            await t.setAgent(client)
        }
        let now = hostNow
        let h = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test", engineDescription: engine, now: { now })
        return (h, t, agent)
    }

    private func failure(_ h: ControlHandler, _ op: String, _ params: JSON) async -> String {
        do { _ = try await h.handle(op: op, params: params); return "no error" } catch { return "\(error)" }
    }

    private func commands(_ agent: FakeAgent) -> [String] {
        agentRequests(agent, "exec.run").compactMap { $0["cmd"]?.stringValue }
    }

    // MARK: - recipe scripts

    func testQuoteEscapesSingleQuotes() {
        XCTAssertEqual(GuestRecipes.quote("it's", os: .windows), "'it''s'")
        XCTAssertEqual(GuestRecipes.quote("it's", os: .linux), "'it'\\''s'")
        XCTAssertEqual(GuestRecipes.quote("plain", os: .windows), "'plain'")
        XCTAssertEqual(GuestRecipes.quote("plain", os: .linux), "'plain'")
    }

    func testQuoteDoublesTypographicQuotesForPowerShell() {
        XCTAssertEqual(GuestRecipes.quote("a\u{2018}b\u{2019}c", os: .windows), "'a\u{2018}\u{2018}b\u{2019}\u{2019}c'")
    }

    func testQuoteEscapesQuoteFollowedByCombiningMark() {
        XCTAssertEqual(GuestRecipes.quote("x'\u{0301};evil", os: .windows), "'x''\u{0301};evil'")
        XCTAssertEqual(GuestRecipes.quote("x'\u{0301};evil", os: .linux), "'x'\\''\u{0301};evil'")
    }

    func testQuoteDoublesEachPowerShellQuoteScalar() {
        for scalar in ["'", "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}"] {
            XCTAssertEqual(GuestRecipes.quote("a\(scalar)b", os: .windows), "'a\(scalar)\(scalar)b'", scalar)
        }
    }

    func testRecipesAvailability() {
        typealias Row = (String, (VMConfig.GuestOS) -> String?, windows: Bool, linux: Bool)
        let table: [Row] = [
            ("clock", { GuestRecipes.setClock(unixSeconds: 1_800_000_000, os: $0) }, true, true),
            ("timeZone", { GuestRecipes.setTimeZone("UTC", os: $0) }, true, true),
            ("theme", { GuestRecipes.setTheme(dark: true, os: $0) }, true, false),
            ("locale", { GuestRecipes.setLocale("ko-KR", os: $0) }, true, false),
            ("keyboardLayouts", { GuestRecipes.setKeyboardLayouts(["en-US", "ko-KR"], os: $0) }, true, false),
            ("dpiScale", { GuestRecipes.setDPIScale(percent: 150, os: $0) }, true, false),
            ("doctorProbe", { GuestRecipes.doctorProbe(os: $0) }, true, true),
        ]
        for (name, make, windows, linux) in table {
            XCTAssertEqual(make(.windows) != nil, windows, "\(name) windows")
            XCTAssertEqual(make(.linux) != nil, linux, "\(name) linux")
            XCTAssertNil(make(.other), "\(name) other")
        }
    }

    func testClockRecipeCarriesSeconds() throws {
        let windows = try XCTUnwrap(GuestRecipes.setClock(unixSeconds: 1_800_000_123, os: .windows))
        XCTAssertTrue(windows.contains("1800000123"))
        XCTAssertTrue(windows.contains("Set-Date"))
        XCTAssertEqual(GuestRecipes.setClock(unixSeconds: 1_800_000_123, os: .linux), "date -u -s @1800000123")
    }

    func testRecipesQuoteInterpolatedValues() throws {
        let zone = try XCTUnwrap(GuestRecipes.setTimeZone("X'; Remove-Item C:\\ #", os: .windows))
        XCTAssertTrue(zone.contains("-Id 'X''; Remove-Item C:\\ #'"))
        let locale = try XCTUnwrap(GuestRecipes.setLocale("a'b", os: .windows))
        XCTAssertTrue(locale.contains("'a''b'"))
        let layouts = try XCTUnwrap(GuestRecipes.setKeyboardLayouts(["en-US", "x'y"], os: .windows))
        XCTAssertTrue(layouts.contains("'x''y'"))
        XCTAssertEqual(GuestRecipes.setTimeZone("A'B", os: .linux), "timedatectl set-timezone 'A'\\''B'")
    }

    func testDPIRecipeMapsPercentToScalingSteps() throws {
        let at100 = try XCTUnwrap(GuestRecipes.setDPIScale(percent: 100, os: .windows))
        let at150 = try XCTUnwrap(GuestRecipes.setDPIScale(percent: 150, os: .windows))
        XCTAssertTrue(at100.contains("0x009F, 0,"), at100)
        XCTAssertTrue(at150.contains("0x009F, 2,"), at150)
    }

    // MARK: - vm.set_environment

    func testSetEnvironmentRunsOneScriptPerSetting() async throws {
        let (h, _, agent) = try await setup { m, _ in
            guard m["op"]?.stringValue == "exec.run" else { return [] }
            let cmd = m["cmd"]?.stringValue ?? ""
            if cmd.contains("AppsUseLightTheme") { return [exitReply(m, code: 1, stderr: "access denied\n")] }
            return [exitReply(m, stdout: "done\n")]
        }
        let r = try await h.handle(op: "vm.set_environment", params: [
            "name": "Win", "theme": "dark", "dpiScale": 150, "locale": "ko-KR", "timeZone": "Tokyo Standard Time",
            "clock": "host", "keyboardLayouts": ["en-US", "ko-KR"],
        ])
        let rows = try XCTUnwrap(r["applied"]?.arrayValue)
        XCTAssertEqual(rows.compactMap { $0["setting"]?.stringValue }, ["clock", "timeZone", "locale", "keyboardLayouts", "theme", "dpiScale"])
        XCTAssertEqual(rows.compactMap { $0["ok"]?.boolValue }, [true, true, true, true, false, true])
        XCTAssertEqual(rows[0]["detail"]?.stringValue, "done")
        XCTAssertEqual(rows[4]["detail"]?.stringValue, "access denied")
        XCTAssertEqual(rows.compactMap { $0["takesEffect"]?.stringValue }, ["now", "now", "app restart", "now", "now", "sign-out"])
        let sent = commands(agent)
        XCTAssertEqual(sent.count, 6)
        XCTAssertTrue(sent[0].contains("Set-Date"))
        XCTAssertTrue(sent[1].contains("Set-TimeZone") && sent[1].contains("'Tokyo Standard Time'"))
        XCTAssertTrue(sent[2].contains("Set-Culture") && sent[2].contains("'ko-KR'"))
        XCTAssertTrue(sent[3].contains("Set-WinUserLanguageList"))
        XCTAssertTrue(sent[4].contains("AppsUseLightTheme"))
        XCTAssertTrue(sent[5].contains("0x009F"))
        XCTAssertEqual(agentRequests(agent, "exec.run").first?["timeout_ms"]?.intValue, 60_000)
    }

    func testSetEnvironmentReportsTimedOutScriptAsFailed() async throws {
        let (h, _, _) = try await setup { m, _ in
            m["op"]?.stringValue == "exec.run"
                ? [agentReply(m, ["code": 0, "stdout": "", "stderr": "", "timed_out": true])] : []
        }
        let r = try await h.handle(op: "vm.set_environment", params: ["name": "Win", "timeZone": "UTC"])
        XCTAssertEqual(r["applied"]?[0]?["ok"]?.boolValue, false)
    }

    func testSetEnvironmentUnsupportedOnLinux() async throws {
        let (h, _, agent) = try await setup(os: .linux) { m, _ in
            m["op"]?.stringValue == "exec.run" ? [exitReply(m)] : []
        }
        let r = try await h.handle(op: "vm.set_environment", params: ["name": "Win", "theme": "light", "timeZone": "Asia/Seoul", "clock": "2026-10-13T09:30:00Z"])
        let rows = try XCTUnwrap(r["applied"]?.arrayValue)
        XCTAssertEqual(rows.compactMap { $0["setting"]?.stringValue }, ["clock", "timeZone", "theme"])
        XCTAssertEqual(rows.compactMap { $0["ok"]?.boolValue }, [true, true, false])
        XCTAssertEqual(rows[2]["detail"]?.stringValue, "not supported on linux guests")
        XCTAssertEqual(rows.compactMap { $0["takesEffect"]?.stringValue }, ["now", "now", "now"])
        XCTAssertEqual(commands(agent), ["date -u -s @1791883800", "timedatectl set-timezone 'Asia/Seoul'"])
    }

    func testSetEnvironmentValidatesParameters() async throws {
        let (h, _, agent) = try await setup()
        let none = await failure(h, "vm.set_environment", ["name": "Win"])
        XCTAssertEqual(none, "pass at least one of theme, timeZone, clock, locale, keyboardLayouts, dpiScale")
        let theme = await failure(h, "vm.set_environment", ["name": "Win", "theme": "blue"])
        XCTAssertEqual(theme, "theme must be 'dark' or 'light'")
        for scale in [99, 501] {
            let message = await failure(h, "vm.set_environment", ["name": "Win", "dpiScale": .int(Int64(scale))])
            XCTAssertEqual(message, "dpiScale must be between 100 and 500")
        }
        let layouts = await failure(h, "vm.set_environment", ["name": "Win", "keyboardLayouts": []])
        XCTAssertEqual(layouts, "keyboardLayouts must be a non-empty list of language tags such as en-US")
        let zone = await failure(h, "vm.set_environment", ["name": "Win", "timeZone": 5])
        XCTAssertEqual(zone, "missing or invalid parameter 'timeZone'")
        XCTAssertEqual(commands(agent), [])
    }

    func testSetEnvironmentRefusesUnsafeValuesWithoutSendingCommands() async throws {
        let (h, _, agent) = try await setup()
        let zones = ["-Asia/Seoul", "", "UTC'; evil", "a\u{0301}", String(repeating: "a", count: 65)]
        for zone in zones {
            let message = await failure(h, "vm.set_environment", ["name": "Win", "timeZone": .string(zone)])
            XCTAssertTrue(message.hasPrefix("timeZone must be") || message.hasPrefix("missing or invalid"), "\(zone): \(message)")
        }
        for locale in ["-ko", "k", "ko KR", "ko-KR'; evil", String(repeating: "a", count: 36)] {
            let message = await failure(h, "vm.set_environment", ["name": "Win", "locale": .string(locale)])
            XCTAssertTrue(message.hasPrefix("locale must be a language tag"), "\(locale): \(message)")
        }
        for tag in ["-en", "e", "en US", "en'x"] {
            let message = await failure(h, "vm.set_environment", ["name": "Win", "keyboardLayouts": ["en-US", .string(tag)]])
            XCTAssertTrue(message.hasPrefix("keyboardLayouts entries must be language tags"), "\(tag): \(message)")
        }
        XCTAssertEqual(commands(agent), [])
    }

    func testSetEnvironmentAcceptsWindowsAndIANAZoneIDs() async throws {
        let (h, _, agent) = try await setup(os: .linux) { m, _ in
            m["op"]?.stringValue == "exec.run" ? [exitReply(m)] : []
        }
        for zone in ["America/Argentina/Buenos_Aires", "Etc/GMT+5", "(UTC+09:00) Seoul"] {
            _ = try await h.handle(op: "vm.set_environment", params: ["name": "Win", "timeZone": .string(zone)])
        }
        XCTAssertEqual(commands(agent).count, 3)
    }

    func testSetEnvironmentNeedsExecCapability() async throws {
        let (h, _, agent) = try await setup(caps: ["clipboard"])
        let message = await failure(h, "vm.set_environment", ["name": "Win", "theme": "dark"])
        XCTAssertTrue(message.contains("--allow-exec"), message)
        XCTAssertEqual(commands(agent), [])
    }

    func testSetEnvironmentNeedsRunningVM() async throws {
        let (h, _, _) = try await setup(state: .stopped)
        let message = await failure(h, "vm.set_environment", ["name": "Win", "theme": "dark"])
        XCTAssertEqual(message, "VM 'Win' is stopped; call vm.start first")
    }

    func testClockHostUsesHostTime() async throws {
        let (h, _, agent) = try await setup(os: .linux) { m, _ in
            m["op"]?.stringValue == "exec.run" ? [exitReply(m)] : []
        }
        _ = try await h.handle(op: "vm.set_environment", params: ["name": "Win", "clock": "host"])
        XCTAssertEqual(commands(agent), ["date -u -s @1800000000"])
    }

    func testClockAcceptsISO8601WithAndWithoutFraction() async throws {
        let (h, _, agent) = try await setup(os: .linux) { m, _ in
            m["op"]?.stringValue == "exec.run" ? [exitReply(m)] : []
        }
        _ = try await h.handle(op: "vm.set_environment", params: ["name": "Win", "clock": "2026-10-13T09:30:00Z"])
        _ = try await h.handle(op: "vm.set_environment", params: ["name": "Win", "clock": "2026-10-13T09:30:00.250Z"])
        XCTAssertEqual(commands(agent), ["date -u -s @1791883800", "date -u -s @1791883800"])
    }

    func testClockRejectsInvalidText() async throws {
        let (h, _, _) = try await setup()
        let message = await failure(h, "vm.set_environment", ["name": "Win", "clock": "yesterday"])
        XCTAssertEqual(message, "clock must be 'host' or an ISO 8601 time such as 2026-10-13T09:30:00Z")
    }

    // MARK: - vm.doctor

    private func checks(_ r: JSON) -> [JSON] { r["checks"]?.arrayValue ?? [] }

    private func check(_ r: JSON, _ id: String) -> JSON? { checks(r).first { $0["id"]?.stringValue == id } }

    func testDoctorWhenStopped() async throws {
        let (h, _, _) = try await setup(state: .stopped, engine: "/opt/qemu/bin/qemu-system-aarch64")
        let r = try await h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(checks(r).compactMap { $0["id"]?.stringValue }, ["engine", "host", "state"])
        XCTAssertEqual(check(r, "engine")?["ok"]?.boolValue, true)
        XCTAssertEqual(check(r, "engine")?["detail"]?.stringValue, "/opt/qemu/bin/qemu-system-aarch64")
        XCTAssertEqual(check(r, "host")?["detail"]?.stringValue, "test")
        XCTAssertEqual(check(r, "state")?["ok"]?.boolValue, false)
        XCTAssertEqual(check(r, "state")?["detail"]?.stringValue, "stopped")
        XCTAssertTrue(check(r, "state")?["hint"]?.stringValue?.contains("vm.start") == true)
    }

    func testDoctorEngineManagedByAppWhenUnknown() async throws {
        let (h, _, _) = try await setup(state: .stopped)
        let r = try await h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(r, "engine")?["ok"]?.boolValue, true)
        XCTAssertEqual(check(r, "engine")?["detail"]?.stringValue, "managed by the Alcove app")
    }

    func testDoctorParsesProbe() async throws {
        let skewed = hostNow.addingTimeInterval(9)
        let (h, _, agent) = try await setup { m, _ in
            m["op"]?.stringValue == "exec.run" ? [exitReply(m, stdout: probeJSON(utc: skewed, scale: 125))] : []
        }
        let r = try await h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(checks(r).compactMap { $0["id"]?.stringValue },
                       ["engine", "host", "state", "display", "tools", "rpc", "exec", "session", "disk", "clock", "network", "scale"])
        XCTAssertEqual(check(r, "state")?["ok"]?.boolValue, true)
        XCTAssertEqual(check(r, "display")?["detail"]?.stringValue, "800x600")
        XCTAssertEqual(check(r, "tools")?["ok"]?.boolValue, true)
        XCTAssertEqual(check(r, "rpc")?["ok"]?.boolValue, true)
        XCTAssertEqual(check(r, "exec")?["ok"]?.boolValue, true)
        XCTAssertEqual(check(r, "session")?["ok"]?.boolValue, true)
        XCTAssertEqual(check(r, "session")?["detail"]?.stringValue, "alcove, unlocked")
        XCTAssertEqual(check(r, "disk")?["ok"]?.boolValue, true)
        XCTAssertEqual(check(r, "disk")?["detail"]?.stringValue, "40000000000 bytes free")
        XCTAssertEqual(check(r, "clock")?["ok"]?.boolValue, false)
        XCTAssertEqual(check(r, "clock")?["hint"]?.stringValue, "vm.set_environment clock=host")
        XCTAssertEqual(check(r, "network")?["ok"]?.boolValue, true)
        XCTAssertEqual(check(r, "scale")?["detail"]?.stringValue, "125 % (applied at sign-in)")
        XCTAssertEqual(commands(agent).count, 1)
        XCTAssertEqual(commands(agent).first, GuestRecipes.doctorProbe(os: .windows))
    }

    func testDoctorFlagsLockedSessionLowDiskAndNoDNS() async throws {
        let (h, _, _) = try await setup { m, _ in
            m["op"]?.stringValue == "exec.run"
                ? [exitReply(m, stdout: probeJSON(utc: hostNow, locked: true, free: 1_000_000_000, dns: false))] : []
        }
        let r = try await h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(r, "session")?["ok"]?.boolValue, false)
        XCTAssertEqual(check(r, "session")?["detail"]?.stringValue, "alcove, locked")
        XCTAssertEqual(check(r, "disk")?["ok"]?.boolValue, false)
        XCTAssertEqual(check(r, "clock")?["ok"]?.boolValue, true)
        XCTAssertEqual(check(r, "network")?["ok"]?.boolValue, false)
        for id in ["session", "disk", "network"] {
            XCTAssertNotNil(check(r, id)?["hint"]?.stringValue, id)
        }
    }

    func testDoctorClockToleratesSmallSkew() async throws {
        let (h, _, _) = try await setup { m, _ in
            m["op"]?.stringValue == "exec.run"
                ? [exitReply(m, stdout: probeJSON(utc: hostNow.addingTimeInterval(-5)))] : []
        }
        let r = try await h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(r, "clock")?["ok"]?.boolValue, true)
        XCTAssertNil(check(r, "clock")?["hint"])
    }

    func testDoctorReportsOnlyWhatTheProbeMeasured() async throws {
        let text = ISO8601DateFormatter().string(from: hostNow)
        let (h, _, _) = try await setup(os: .linux) { m, _ in
            m["op"]?.stringValue == "exec.run"
                ? [exitReply(m, stdout: "{\"user\":\"root\",\"freeBytes\":5000000000,\"utc\":\"\(text)\",\"dns\":true}\n")] : []
        }
        let r = try await h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(r, "session")?["ok"]?.boolValue, true)
        XCTAssertEqual(check(r, "session")?["detail"]?.stringValue, "root, lock state not checked on this guest")
        XCTAssertEqual(check(r, "scale")?["ok"]?.boolValue, true)
        XCTAssertEqual(check(r, "scale")?["detail"]?.stringValue, "not checked on this guest")
    }

    func testDoctorSessionNeedsUser() async throws {
        let (h, _, _) = try await setup { m, _ in
            m["op"]?.stringValue == "exec.run" ? [exitReply(m, stdout: "{\"dns\":true}\n")] : []
        }
        let r = try await h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(r, "session")?["ok"]?.boolValue, false)
        XCTAssertNotNil(check(r, "session")?["hint"]?.stringValue)
        XCTAssertEqual(check(r, "disk")?["ok"]?.boolValue, false)
        XCTAssertEqual(check(r, "clock")?["ok"]?.boolValue, false)
    }

    func testEveryFailingDoctorRowHasAHint() async throws {
        var results: [(String, JSON)] = []
        let probeOK: @Sendable (JSON, FakeAgent) -> [JSON] = { m, _ in
            m["op"]?.stringValue == "exec.run" ? [exitReply(m, stdout: probeJSON(utc: hostNow)) ] : []
        }
        let (stopped, _, _) = try await setup(state: .stopped)
        results.append(("stopped", try await stopped.handle(op: "vm.doctor", params: ["name": "Win"])))
        let (paused, _, _) = try await setup(state: .paused)
        results.append(("paused", try await paused.handle(op: "vm.doctor", params: ["name": "Win"])))
        let (noTools, _, _) = try await setup(connected: false)
        results.append(("no tools", try await noTools.handle(op: "vm.doctor", params: ["name": "Win"])))
        let (noExec, _, _) = try await setup(caps: ["clipboard"])
        results.append(("no exec", try await noExec.handle(op: "vm.doctor", params: ["name": "Win"])))
        let (other, _, _) = try await setup(os: .other, probeOK)
        results.append(("other", try await other.handle(op: "vm.doctor", params: ["name": "Win"])))
        let (garbage, _, _) = try await setup { m, _ in
            m["op"]?.stringValue == "exec.run" ? [exitReply(m, stdout: "not json")] : []
        }
        results.append(("bad output", try await garbage.handle(op: "vm.doctor", params: ["name": "Win"])))
        let (skewed, _, _) = try await setup { m, _ in
            m["op"]?.stringValue == "exec.run" ? [exitReply(m, stdout: probeJSON(utc: hostNow.addingTimeInterval(60), locked: true, free: 1, dns: false))] : []
        }
        results.append(("skewed", try await skewed.handle(op: "vm.doctor", params: ["name": "Win"])))
        for (name, r) in results {
            XCTAssertTrue(checks(r).contains { $0["ok"]?.boolValue == false }, "\(name) has a failing row")
            for row in checks(r) where row["ok"]?.boolValue == false {
                XCTAssertNotNil(row["hint"]?.stringValue, "\(name): \(row["id"]?.stringValue ?? "?")")
            }
        }
    }

    func testDoctorReportsProbeFailure() async throws {
        let (h, _, _) = try await setup { m, _ in
            m["op"]?.stringValue == "exec.run" ? [exitReply(m, code: 1, stderr: "boom\n")] : []
        }
        let r = try await h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(checks(r).last?["id"]?.stringValue, "probe")
        XCTAssertEqual(checks(r).last?["ok"]?.boolValue, false)
        XCTAssertEqual(checks(r).last?["detail"]?.stringValue, "boom")
    }

    func testDoctorWithoutAgent() async throws {
        let (h, _, _) = try await setup(connected: false)
        let r = try await h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(checks(r).compactMap { $0["id"]?.stringValue }, ["engine", "host", "state", "display", "tools"])
        XCTAssertEqual(check(r, "tools")?["ok"]?.boolValue, false)
        XCTAssertTrue(check(r, "tools")?["hint"]?.stringValue?.contains("scripts/test/install-agent.py") == true)
    }

    func testDoctorWithoutExecCapability() async throws {
        let (h, _, agent) = try await setup(caps: ["clipboard"])
        let r = try await h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(checks(r).compactMap { $0["id"]?.stringValue },
                       ["engine", "host", "state", "display", "tools", "rpc", "exec"])
        XCTAssertEqual(check(r, "exec")?["ok"]?.boolValue, false)
        XCTAssertTrue(check(r, "exec")?["hint"]?.stringValue?.contains("--allow-exec") == true)
        XCTAssertEqual(commands(agent), [])
    }

    func testDoctorWithOldAgentProtocol() async throws {
        let agent = FakeAgent()
        agent.proto = 1
        let (h, _) = try await handlerWithAgent(agent, in: self)
        let r = try await h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(r, "rpc")?["ok"]?.boolValue, false)
        XCTAssertEqual(checks(r).last?["id"]?.stringValue, "exec")
        XCTAssertEqual(commands(agent), [])
    }

    func testDoctorOnLinuxRunsTheLinuxProbe() async throws {
        let (h, _, agent) = try await setup(os: .linux) { m, _ in
            m["op"]?.stringValue == "exec.run" ? [exitReply(m, stdout: probeJSON(utc: hostNow, scale: 100))] : []
        }
        let r = try await h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(r, "clock")?["ok"]?.boolValue, true)
        XCTAssertEqual(commands(agent), [GuestRecipes.doctorProbe(os: .linux)])
    }

    // MARK: - snapshot restore

    func testRestoreSyncsClock() async throws {
        let (h, t, agent) = try await setup { m, _ in
            m["op"]?.stringValue == "exec.run" ? [exitReply(m)] : []
        }
        await t.setSnapshotList([VMController.SnapshotInfo(name: "clean", vmStateSize: 1, date: hostNow)])
        let r = try await h.handle(op: "vm.snapshot.restore", params: ["name": "Win", "snapshot": "clean", "waitTools": 0])
        XCTAssertEqual(r["tools"]?.boolValue, true)
        XCTAssertEqual(r["clockSynced"]?.boolValue, true)
        XCTAssertEqual(commands(agent), [GuestRecipes.setClock(unixSeconds: 1_800_000_000, os: .windows)])
    }

    func testRestoreWithoutToolsDoesNotSyncClock() async throws {
        let (h, t, _) = try await setup(connected: false)
        await t.setSnapshotList([VMController.SnapshotInfo(name: "clean", vmStateSize: 1, date: hostNow)])
        let r = try await h.handle(op: "vm.snapshot.restore", params: ["name": "Win", "snapshot": "clean", "waitTools": 0])
        XCTAssertEqual(r["tools"]?.boolValue, false)
        XCTAssertEqual(r["clockSynced"]?.boolValue, false)
    }

    func testRestoreReportsFailedClockSync() async throws {
        let (h, t, _) = try await setup { m, _ in
            m["op"]?.stringValue == "exec.run" ? [exitReply(m, code: 1, stderr: "denied")] : []
        }
        await t.setSnapshotList([VMController.SnapshotInfo(name: "clean", vmStateSize: 1, date: hostNow)])
        let r = try await h.handle(op: "vm.snapshot.restore", params: ["name": "Win", "snapshot": "clean", "waitTools": 0])
        XCTAssertEqual(r["tools"]?.boolValue, true)
        XCTAssertEqual(r["clockSynced"]?.boolValue, false)
    }
}
