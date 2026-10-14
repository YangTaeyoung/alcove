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

    func testDPIStepIndexIsTheNearestOfferedPercentage() {
        XCTAssertEqual(GuestRecipes.dpiStepIndex(percent: 100), 0)
        XCTAssertEqual(GuestRecipes.dpiStepIndex(percent: 112), 0)
        XCTAssertEqual(GuestRecipes.dpiStepIndex(percent: 113), 1)
        XCTAssertEqual(GuestRecipes.dpiStepIndex(percent: 150), 2)
        XCTAssertEqual(GuestRecipes.dpiStepIndex(percent: 275), 6)
        XCTAssertEqual(GuestRecipes.dpiStepIndex(percent: 500), 11)
    }

    func testDPIRecipeCountsTheStepFromTheRecommendedScale() throws {
        let at100 = try XCTUnwrap(GuestRecipes.setDPIScale(percent: 100, os: .windows))
        let at150 = try XCTUnwrap(GuestRecipes.setDPIScale(percent: 150, os: .windows))
        XCTAssertTrue(at150.contains("DisplayConfigGetDeviceInfo"), at150)
        XCTAssertTrue(at150.contains("$recommended = -$range[0]"), at150)
        XCTAssertTrue(at100.contains("0x009F, 0 - $recommended,"), at100)
        XCTAssertTrue(at150.contains("0x009F, 2 - $recommended,"), at150)
        XCTAssertTrue(at150.contains("$steps = 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500\n"), at150)
    }

    func testDPIRecipePrintsTheScaleANewProcessReads() throws {
        let script = try XCTUnwrap(GuestRecipes.setDPIScale(percent: 150, os: .windows))
        XCTAssertTrue(script.contains("powershell.exe -NoProfile -NonInteractive -EncodedCommand"), script)
        XCTAssertTrue(script.contains("SetProcessDPIAware"), script)
        XCTAssertTrue(script.contains("GetDpiForSystem"), script)
        XCTAssertTrue(script.contains("$applied = [int]([int]$dpi * 100 / 96)"), script)
        XCTAssertTrue(script.hasSuffix("| ConvertTo-Json -Compress"), script)
        XCTAssertFalse(script.contains("'scale: 150 %'"), script)
    }

    func testDPIRecipeStoresTheAppliedStepOnlyWhenTheRequestIsAboveTheDisplaysRange() throws {
        let script = try XCTUnwrap(GuestRecipes.setDPIScale(percent: 150, os: .windows))
        XCTAssertTrue(script.contains("$index = [Array]::IndexOf($steps, $applied)"), script)
        XCTAssertTrue(script.contains("if ($index -ge 0 -and 2 -gt $range[2] - $range[0]) { [void][Alcove.Dpi]::SystemParametersInfo(0x009F, $index - $recommended, [IntPtr]::Zero, 3) }"), script)
        XCTAssertFalse(script.contains("$index -ne"), script)
    }

    func testDPIRecipeThrowsTheSentencesTheProtocolQuotes() throws {
        let script = try XCTUnwrap(GuestRecipes.setDPIScale(percent: 150, os: .windows))
        XCTAssertTrue(script.contains("throw 'the guest did not report the scale range of its display; sign in to the guest desktop and set dpiScale again'"), script)
        XCTAssertTrue(script.contains("throw 'Windows refused the display scale; sign in to the guest desktop and set dpiScale again'"), script)
    }

    func testDPIScaleResultIsOkWhenTheRequestedScaleWasApplied() {
        let r = GuestRecipes.dpiScaleResult(requested: 125, output: "{\"applied\":125,\"recommended\":100,\"offered\":[100,125]}")
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.detail, "scale: 125 %")
    }

    func testDPIScaleResultNamesTheLargestOfferedScaleForARequestAboveIt() {
        let r = GuestRecipes.dpiScaleResult(requested: 150, output: "{\"applied\":125,\"recommended\":100,\"offered\":[100,125]}")
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.detail, "scale: 125 % was applied, not 150 %; the largest scale the guest offers at its resolution is 125 %; "
                       + "request it, or set a larger resolution with vm.set_resolution first")
    }

    func testDPIScaleResultNamesTheOfferedScalesAroundARequestBetweenThem() {
        let r = GuestRecipes.dpiScaleResult(requested: 130, output: "noise\r\n{\"applied\":125,\"recommended\":150,\"offered\":[100,125,150,175]}\r\n")
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.detail, "scale: 125 % was applied, not 130 %; the nearest scales the guest offers are 125 % and 150 %; request one of them")
    }

    func testDPIScaleResultNamesTheNearestOfferedScaleForARequestThatIsNoStepAndAboveTheOfferedOnes() {
        let r = GuestRecipes.dpiScaleResult(requested: 130, output: "{\"applied\":125,\"recommended\":100,\"offered\":[100,125]}")
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.detail, "scale: 125 % was applied, not 130 %; the nearest scale the guest offers is 125 %; request it")
    }

    func testDPIScaleResultReportsAnOfferedScaleThatWasNotApplied() {
        let r = GuestRecipes.dpiScaleResult(requested: 150, output: "{\"applied\":100,\"recommended\":100,\"offered\":[100,125,150]}")
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.detail, "scale: 100 % was applied, not 150 %; the guest offers 150 % and did not apply it; "
                       + "read the scale row of vm.doctor and set dpiScale again")
    }

    func testDPIScaleResultWithoutAnOfferedListNamesOnlyTheAppliedScale() {
        let r = GuestRecipes.dpiScaleResult(requested: 150, output: "{\"applied\":125}")
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.detail, "scale: 125 % was applied, not 150 %; request 125, or read the scale row of vm.doctor")
    }

    func testDPIScaleResultReportsOutputWithoutAScale() {
        let r = GuestRecipes.dpiScaleResult(requested: 150, output: "done")
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.detail, "the guest did not report the scale it applied; read the scale row of vm.doctor")
    }

    func testDoctorScaleProbeReadsTheSystemDPI() throws {
        let probe = try XCTUnwrap(GuestRecipes.doctorProbe(os: .windows))
        XCTAssertTrue(probe.contains("SetProcessDPIAware"), probe)
        XCTAssertTrue(probe.contains("GetDpiForSystem"), probe)
    }

    // MARK: - vm.set_environment

    func testSetEnvironmentRunsOneScriptPerSetting() async throws {
        let (h, _, agent) = try await setup { m, _ in
            guard m["op"]?.stringValue == "exec.run" else { return [] }
            let cmd = m["cmd"]?.stringValue ?? ""
            if cmd.contains("AppsUseLightTheme") { return [exitReply(m, code: 1, stderr: "access denied\n")] }
            if cmd.contains("0x009F") { return [exitReply(m, stdout: "{\"applied\":150,\"recommended\":100,\"offered\":[100,125,150,175]}\r\n")] }
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
        XCTAssertEqual(rows[5]["detail"]?.stringValue, "scale: 150 %")
        XCTAssertEqual(rows.compactMap { $0["takesEffect"]?.stringValue }, ["now", "now", "app restart", "now", "now", "now"])
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

    func testSetEnvironmentFailsTheScaleRowWhenAnotherScaleWasApplied() async throws {
        let (h, _, _) = try await setup { m, _ in
            m["op"]?.stringValue == "exec.run"
                ? [exitReply(m, stdout: "{\"applied\":125,\"recommended\":100,\"offered\":[100,125]}\r\n")] : []
        }
        let r = try await h.handle(op: "vm.set_environment", params: ["name": "Win", "dpiScale": 200])
        let row = try XCTUnwrap(r["applied"]?[0])
        XCTAssertEqual(row["ok"]?.boolValue, false)
        XCTAssertEqual(row["detail"]?.stringValue, "scale: 125 % was applied, not 200 %; the largest scale the guest offers at its resolution is 125 %; "
                       + "request it, or set a larger resolution with vm.set_resolution first")
        XCTAssertEqual(row["takesEffect"]?.stringValue, "now")
    }

    func testSetEnvironmentKeepsTheScriptErrorOfAFailedScaleRecipe() async throws {
        let (h, _, _) = try await setup { m, _ in
            m["op"]?.stringValue == "exec.run" ? [exitReply(m, code: 1, stdout: "{\"applied\":125}", stderr: "no display\n")] : []
        }
        let r = try await h.handle(op: "vm.set_environment", params: ["name": "Win", "dpiScale": 125])
        XCTAssertEqual(r["applied"]?[0]?["ok"]?.boolValue, false)
        XCTAssertEqual(r["applied"]?[0]?["detail"]?.stringValue, "no display")
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
                       ["engine", "host", "state", "display", "tools", "rpc", "exec", "session", "disk", "clock", "network", "scale", "proxy"])
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
        XCTAssertEqual(check(r, "scale")?["detail"]?.stringValue, "125 %")
        XCTAssertEqual(check(r, "proxy")?["detail"]?.stringValue, "no system proxy")
        XCTAssertEqual(commands(agent), [GuestRecipes.doctorProbe(os: .windows), GuestRecipes.readSystemProxy(os: .windows)])
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
        XCTAssertEqual(commands(agent), [GuestRecipes.doctorProbe(os: .linux), GuestRecipes.readSystemProxy(os: .linux)])
        XCTAssertEqual(check(r, "proxy")?["ok"]?.boolValue, true)
    }

    // MARK: - start of a suspended session

    func testStartOfASuspendedSessionSyncsTheClock() async throws {
        let (h, t, agent) = try await setup(state: .stopped) { m, _ in
            m["op"]?.stringValue == "exec.run" ? [exitReply(m)] : []
        }
        await t.setSuspended(true)
        let r = try await h.handle(op: "vm.start", params: ["name": "Win", "waitTools": 0])
        XCTAssertEqual(r["state"]?.stringValue, "running")
        XCTAssertEqual(r["ephemeral"]?.boolValue, false)
        XCTAssertEqual(r["resumed"]?.boolValue, true)
        XCTAssertEqual(r["tools"]?.boolValue, true)
        XCTAssertEqual(r["clockSynced"]?.boolValue, true)
        XCTAssertEqual(commands(agent), [GuestRecipes.setClock(unixSeconds: 1_800_000_000, os: .windows)])
    }

    func testStartOfASuspendedSessionWithoutToolsDoesNotSyncTheClock() async throws {
        let (h, t, _) = try await setup(state: .stopped, connected: false)
        await t.setSuspended(true)
        let r = try await h.handle(op: "vm.start", params: ["name": "Win", "waitTools": 0])
        XCTAssertEqual(r["resumed"]?.boolValue, true)
        XCTAssertEqual(r["tools"]?.boolValue, false)
        XCTAssertEqual(r["clockSynced"]?.boolValue, false)
    }

    func testStartOfASuspendedSessionOfAGuestWithoutAClockRecipeDoesNotWait() async throws {
        let (h, t, agent) = try await setup(os: .other, state: .stopped)
        await t.setSuspended(true)
        let r = try await h.handle(op: "vm.start", params: ["name": "Win"])
        XCTAssertEqual(r["resumed"]?.boolValue, true)
        XCTAssertEqual(r["tools"]?.boolValue, true)
        XCTAssertEqual(r["clockSynced"]?.boolValue, false)
        let timeouts = await t.agentTimeouts
        XCTAssertEqual(timeouts, [.zero])
        XCTAssertEqual(commands(agent), [])
    }

    func testStartOfAStoppedVMRunsNoGuestCommand() async throws {
        let (h, _, agent) = try await setup(state: .stopped) { m, _ in
            m["op"]?.stringValue == "exec.run" ? [exitReply(m)] : []
        }
        let r = try await h.handle(op: "vm.start", params: ["name": "Win"])
        XCTAssertEqual(r["state"]?.stringValue, "running")
        XCTAssertNil(r["resumed"])
        XCTAssertNil(r["tools"])
        XCTAssertNil(r["clockSynced"])
        XCTAssertEqual(commands(agent), [])
    }

    func testStartOfARunningVMWithASavedSessionFileRunsNoGuestCommand() async throws {
        let (h, t, agent) = try await setup { m, _ in
            m["op"]?.stringValue == "exec.run" ? [exitReply(m)] : []
        }
        await t.setSuspended(true)
        let r = try await h.handle(op: "vm.start", params: ["name": "Win"])
        XCTAssertNil(r["resumed"])
        XCTAssertEqual(commands(agent), [])
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
