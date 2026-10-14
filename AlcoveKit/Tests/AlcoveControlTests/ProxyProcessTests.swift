import XCTest
@testable import AlcoveControl
import AlcoveQMP
import AlcoveTestSupport

/// The sentence `body` fails with; `no error` when it does not fail.
private func proxyFailure(_ body: @Sendable () async throws -> Void) async -> String {
    do { try await body(); return "no error" } catch { return "\(error)" }
}

/// Whether the process `pid` runs and was started by this process.
private func isChildOfThisProcess(_ pid: Int32) -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
    return info.kp_eproc.e_ppid == getpid()
}

/// `ProxyProcess` against stand-in scripts and against the `alcove-proxy` built from this repository.
final class ProxyProcessTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("proxy-process-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// An executable `/bin/sh` script with `body`, and the directory to pass as the CA directory. The script first
    /// writes its process id to `pid` in that directory; the teardown of the test sends SIGKILL to that process when
    /// it is still a child of the test process.
    private func standIn(_ body: String) throws -> (path: String, dir: URL) {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("stand-in.sh").path
        let script = "#!/bin/sh\necho $$ > \"$2/pid\"\n" + body + "\n"
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755]))
        let pidFile = dir.appendingPathComponent("pid")
        addTeardownBlock {
            guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), isChildOfThisProcess(pid) else { return }
            kill(pid, SIGKILL)
        }
        return (path, dir)
    }

    private static let ready = "printf '{\"ev\":\"ready\",\"port\":4321,\"ca\":\"/tmp/ca.pem\"}\\n'"
    /// Reads request lines and answers each with its `id`.
    private static let echo = """
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          case "$line" in
            *'"op":"bad"'*) printf '{"id":%s,"ok":false,"error":"no rule with id 9; run rule.list to see the ids"}\\n' "$id" ;;
            *) printf '{"id":%s,"ok":true,"seen":%s}\\n' "$id" "$id" ;;
          esac
        done
        """
    /// Sleeps for ten minutes at most, a second at a time.
    private static let idle = "i=0; while [ $i -lt 600 ]; do sleep 1; i=$((i+1)); done"

    private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// Stops `proxy` and returns whether `stop()` came back within 20 s; records a failure when it did not.
    private func stops(_ proxy: ProxyProcess, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        await finishes("stop() returns: the child has ended", file: file, line: line) { await proxy.stop() }
    }

    func testProxyProcessReadyAndCall() async throws {
        let script = try standIn("echo \"$1 $2\" > \"$2/args\"\n" + Self.ready + "\n" + Self.echo)
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir)
        let started = try await proxy.start()
        XCTAssertEqual(started.port, 4321)
        XCTAssertEqual(started.caPath, "/tmp/ca.pem")
        let args = try String(contentsOf: script.dir.appendingPathComponent("args"), encoding: .utf8)
        XCTAssertEqual(args, "--ca-dir \(script.dir.path)\n")

        let first = try await proxy.call("list", ["limit": 5])
        XCTAssertEqual(first, ["seen": 1])
        async let second = proxy.call("rule.list", [:])
        async let third = proxy.call("clear", [:])
        let answers = try await [second, third].compactMap { $0["seen"]?.intValue }.sorted()
        XCTAssertEqual(answers, [2, 3])

        let refused = await proxyFailure { _ = try await proxy.call("bad", [:]) }
        XCTAssertEqual(refused, "no rule with id 9; run rule.list to see the ids")
        let after = try await proxy.call("list", [:])
        XCTAssertEqual(after, ["seen": 5])

        let pid = try XCTUnwrap(proxy.processIdentifier)
        let stopped = await stops(proxy)
        XCTAssertTrue(stopped)
        XCTAssertFalse(isAlive(pid))
        let later = await proxyFailure { _ = try await proxy.call("list", [:]) }
        XCTAssertEqual(later, "the capture was stopped; call vm.http.start to capture again")
        await proxy.stop()
    }

    func testProxyProcessMatchesAnswersToRequestsByTheirID() async throws {
        let body = """
            \(Self.ready)
            IFS= read -r one
            IFS= read -r two
            printf '{"id":77,"ok":true,"which":"nobody"}\\n'
            printf '{"id":2,"ok":true,"which":"second"}\\n'
            printf '{"id":1,"ok":true,"which":"first"}\\n'
            printf '{"id":1,"ok":true,"which":"again"}\\n'
            \(Self.echo)
            """
        let script = try standIn(body)
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir)
        _ = try await proxy.start()
        async let first = proxy.call("list", [:])
        let taken = await eventually("the proxy takes the first request") { proxy.requestCount == 1 }
        XCTAssertTrue(taken)
        async let second = proxy.call("rule.list", [:])
        let answers = try await [first, second]
        XCTAssertEqual(answers, [["which": "first"], ["which": "second"]])
        let third = try await proxy.call("clear", [:])
        XCTAssertEqual(third, ["seen": 3])
        _ = await stops(proxy)
    }

    func testProxyProcessExitFailsPendingCalls() async throws {
        let script = try standIn(Self.ready + "\nIFS= read -r line\necho 'the proxy listener stopped: boom' >&2\nexit 3")
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir)
        _ = try await proxy.start()
        let expected = "alcove-proxy is not running (it exited with status 3: the proxy listener stopped: boom); call vm.http.stop, then vm.http.start to capture again"
        let pending = await proxyFailure { _ = try await proxy.call("list", [:]) }
        XCTAssertEqual(pending, expected)
        let later = await proxyFailure { _ = try await proxy.call("list", [:]) }
        XCTAssertEqual(later, expected)
        await proxy.stop()
    }

    func testProxyProcessFailsEveryPendingCallWhenTheChildExits() async throws {
        let script = try standIn(Self.ready + "\nIFS= read -r one\nIFS= read -r two\nexit 0")
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir)
        _ = try await proxy.start()
        async let first = proxyFailure { _ = try await proxy.call("list", [:]) }
        async let second = proxyFailure { _ = try await proxy.call("rule.list", [:]) }
        let texts = await [first, second]
        let expected = "alcove-proxy is not running (it exited with status 0); call vm.http.stop, then vm.http.start to capture again"
        XCTAssertEqual(texts, [expected, expected])
    }

    func testProxyProcessWithoutAProgram() async throws {
        let dir = try tempDir()
        for executable in [nil, dir.appendingPathComponent("missing").path] {
            let proxy = ProxyProcess(executable: executable, caDirectory: dir)
            let text = await proxyFailure { _ = try await proxy.start() }
            XCTAssertEqual(text, "alcove-proxy was not found; build it with scripts/test/all.sh or set ALCOVE_PROXY")
            let call = await proxyFailure { _ = try await proxy.call("list", [:]) }
            XCTAssertEqual(call, "alcove-proxy was not found; build it with scripts/test/all.sh or set ALCOVE_PROXY")
            await proxy.stop()
        }
    }

    func testProxyProcessThatExitsBeforeReadySaysWhy() async throws {
        let script = try standIn("echo 'alcove-proxy: cannot listen on 127.0.0.1:0: address in use' >&2\nexit 2")
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir)
        let text = await proxyFailure { _ = try await proxy.start() }
        XCTAssertEqual(text, "alcove-proxy did not start: cannot listen on 127.0.0.1:0: address in use")

        let silent = try standIn("exit 5")
        let quiet = ProxyProcess(executable: silent.path, caDirectory: silent.dir)
        let bare = await proxyFailure { _ = try await quiet.start() }
        XCTAssertEqual(bare, "alcove-proxy exited with status 5 before it was ready; run '\(silent.path) --ca-dir \(silent.dir.path)' to see why")
    }

    func testProxyProcessReadyTimeoutEndsTheChild() async throws {
        let script = try standIn("exec sleep 600")
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir, limits: .init(ready: .milliseconds(300)))
        let text = await proxyFailure { _ = try await proxy.start() }
        XCTAssertEqual(text, "alcove-proxy did not report its port within 0.3 s; run '\(script.path) --ca-dir \(script.dir.path)' to see why")
        let pid = try XCTUnwrap(proxy.processIdentifier)
        let stopped = await stops(proxy)
        XCTAssertTrue(stopped)
        XCTAssertFalse(isAlive(pid))
    }

    func testProxyProcessUnreadableFirstLine() async throws {
        let script = try standIn("echo 'listening'\nexec sleep 600")
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir)
        let text = await proxyFailure { _ = try await proxy.start() }
        XCTAssertEqual(text, "alcove-proxy printed a first line Alcove cannot read; build it again with scripts/test/all.sh")
        let pid = try XCTUnwrap(proxy.processIdentifier)
        let stopped = await stops(proxy)
        XCTAssertTrue(stopped)
        XCTAssertFalse(isAlive(pid))
    }

    func testProxyProcessCallTimeout() async throws {
        let script = try standIn(Self.ready + "\nexec sleep 600")
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir, limits: .init(call: .milliseconds(200), exit: .milliseconds(100)))
        _ = try await proxy.start()
        let text = await proxyFailure { _ = try await proxy.call("list", [:]) }
        XCTAssertEqual(text, "alcove-proxy did not answer list within 0.2 s; call vm.http.stop, then vm.http.start to capture again")
        _ = await stops(proxy)
    }

    func testProxyProcessStopEndsAChildThatIgnoresItsInputAndSIGTERM() async throws {
        let script = try standIn("trap '' TERM\n" + Self.ready + "\n" + Self.idle)
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir, limits: .init(exit: .milliseconds(100)))
        _ = try await proxy.start()
        let pid = try XCTUnwrap(proxy.processIdentifier)
        XCTAssertTrue(isAlive(pid))
        let stopped = await finishes("stop() returns: a child that ignores its input and SIGTERM gets SIGKILL") { await proxy.stop() }
        XCTAssertTrue(stopped)
        XCTAssertFalse(isAlive(pid))
    }

    func testProxyProcessStopFailsPendingCalls() async throws {
        let script = try standIn(Self.ready + "\nIFS= read -r line\necho got > \"$2/got\"\nwhile IFS= read -r more; do :; done")
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir)
        _ = try await proxy.start()
        async let pending = proxyFailure { _ = try await proxy.call("list", [:]) }
        let marker = script.dir.appendingPathComponent("got").path
        let read = await eventually("the child reads the request") { FileManager.default.fileExists(atPath: marker) }
        XCTAssertTrue(read)
        _ = await stops(proxy)
        let text = await pending
        XCTAssertEqual(text, "the capture was stopped; call vm.http.start to capture again")
    }

    func testProxyProcessReleasedWithoutStopEndsTheChild() async throws {
        let script = try standIn(Self.ready + "\n" + Self.echo)
        var proxy: ProxyProcess? = ProxyProcess(executable: script.path, caDirectory: script.dir)
        _ = try await proxy?.start()
        let pid = try XCTUnwrap(proxy?.processIdentifier)
        proxy = nil
        let ended = await eventually("the child of a released proxy ends") {
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)
            return kill(pid, 0) != 0
        }
        XCTAssertTrue(ended)
    }

    func testProxyProcessAChildThatClosesItsOutputCountsAsGone() async throws {
        let script = try standIn(Self.ready + "\nexec >&-\n" + Self.idle)
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir, limits: .init(exit: .milliseconds(100)))
        _ = try await proxy.start()
        let pid = try XCTUnwrap(proxy.processIdentifier)
        let expected = "alcove-proxy closed its output and gives no more answers; call vm.http.stop, then vm.http.start to capture again"
        let pending = await proxyFailure { _ = try await proxy.call("list", [:]) }
        XCTAssertEqual(pending, expected)
        let later = await proxyFailure { _ = try await proxy.call("list", [:]) }
        XCTAssertEqual(later, expected)
        let ended = await eventually("the child that closed its output is ended") { kill(pid, 0) != 0 }
        XCTAssertTrue(ended)
        _ = await stops(proxy)
    }

    func testProxyProcessNamesWhatEndedAChildThatExitedOnItsOwn() async throws {
        let script = try standIn(Self.ready + "\nIFS= read -r line\necho 'the proxy listener stopped: boom' >&2\nexit 3")
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir)
        let before = await proxy.exitReason()
        XCTAssertNil(before)
        _ = try await proxy.start()
        let running = await proxy.exitReason()
        XCTAssertNil(running)
        _ = await proxyFailure { _ = try await proxy.call("list", [:]) }
        let reason = await proxy.exitReason()
        XCTAssertEqual(reason, "alcove-proxy exited with status 3: the proxy listener stopped: boom")
        await proxy.stop()
        let afterStop = await proxy.exitReason()
        XCTAssertEqual(afterStop, "alcove-proxy exited with status 3: the proxy listener stopped: boom")
    }

    func testProxyProcessNamesAClosedOutputAsWhatEndedIt() async throws {
        let script = try standIn(Self.ready + "\nexec >&-\n" + Self.idle)
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir, limits: .init(exit: .milliseconds(100)))
        _ = try await proxy.start()
        let named = await eventually("the proxy names its closed output") { await proxy.exitReason() != nil }
        XCTAssertTrue(named)
        let reason = await proxy.exitReason()
        XCTAssertEqual(reason, "alcove-proxy closed its output and gives no more answers")
        _ = await stops(proxy)
    }

    func testProxyProcessStoppedByItsOwnerHasNoExitReason() async throws {
        let script = try standIn(Self.ready + "\n" + Self.echo)
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir)
        _ = try await proxy.start()
        _ = await stops(proxy)
        let reason = await proxy.exitReason()
        XCTAssertNil(reason)
    }

    func testProxyProcessKeepsNoBytesItHasSent() async throws {
        let answer = #"{ if (match($0, /"id":[0-9]+/)) { printf "{\"id\":%s,\"ok\":true}\n", substr($0, RSTART + 5, RLENGTH - 5); fflush() } }"#
        let script = try standIn(Self.ready + "\nexec awk '\(answer)'")
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir)
        _ = try await proxy.start()
        let piece = String(repeating: "x", count: 1 << 20)
        for _ in 0..<64 {
            let answered = try await proxy.call("rule.add", ["action": ["body": .string(piece)]])
            XCTAssertEqual(answered, [:])
        }
        XCTAssertEqual(proxy.bufferExtents.requests, 0)
        _ = await stops(proxy)
    }

    func testProxyProcessKeepsOnlyTheEndOfTheChildsErrors() async throws {
        let script = try standIn(Self.ready + "\nIFS= read -r line\nhead -c 4000000 /dev/zero | tr '\\0' 'e' >&2\necho >&2\necho 'the last words' >&2\nexit 4")
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir)
        _ = try await proxy.start()
        let text = await proxyFailure { _ = try await proxy.call("list", [:]) }
        XCTAssertEqual(text, "alcove-proxy is not running (it exited with status 4: the last words); call vm.http.stop, then vm.http.start to capture again")
        XCTAssertLessThanOrEqual(proxy.bufferExtents.errors, 8192)
        XCTAssertEqual(ProxyProcess.errorTailBytes, 8192)
    }

    func testProxyProcessRefusesRequestsAChildDoesNotRead() async throws {
        let script = try standIn(Self.ready + "\n" + Self.idle)
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir,
                                 limits: .init(call: .milliseconds(100), exit: .milliseconds(100), lineBytes: 1 << 20))
        _ = try await proxy.start()
        let piece = String(repeating: "x", count: 900_000)
        var texts: [String] = []
        for _ in 0..<8 { texts.append(await proxyFailure { _ = try await proxy.call("rule.add", ["action": ["body": .string(piece)]]) }) }
        XCTAssertEqual(texts.first, "alcove-proxy did not answer rule.add within 0.1 s; call vm.http.stop, then vm.http.start to capture again")
        XCTAssertEqual(texts.last, "alcove-proxy is not reading its requests; call vm.http.stop, then vm.http.start to capture again")
        XCTAssertLessThanOrEqual(proxy.bufferExtents.requests, 4 << 20)
        _ = await stops(proxy)
    }

    func testProxyProcessLongAnswerAndOversizedAnswer() async throws {
        let body = """
            \(Self.ready)
            while IFS= read -r line; do
              id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
              case "$line" in
                *'"op":"big"'*) printf '{"id":%s,"ok":true,"body":"' "$id"; head -c 300000 /dev/zero | tr '\\0' 'x'; printf '"}\\n' ;;
                *'"op":"huge"'*) printf '{"id":%s,"ok":true,"body":"' "$id"; head -c 2000000 /dev/zero | tr '\\0' 'x'; printf '"}\\n' ;;
                *) printf '{"id":%s,"ok":true}\\n' "$id" ;;
              esac
            done
            """
        let script = try standIn(body)
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir, limits: .init(lineBytes: 1 << 20))
        _ = try await proxy.start()
        let big = try await proxy.call("big", [:])
        XCTAssertEqual(big["body"]?.stringValue?.count, 300_000)
        let huge = await proxyFailure { _ = try await proxy.call("huge", [:]) }
        XCTAssertEqual(huge, "alcove-proxy sent an answer larger than 1 MiB; ask for less with limit, offset or length")
        let after = try await proxy.call("list", [:])
        XCTAssertEqual(after, [:])
        let request = await proxyFailure { _ = try await proxy.call("rule.add", ["action": ["body": .string(String(repeating: "y", count: 1 << 20))]]) }
        XCTAssertEqual(request, "the request 'rule.add' is larger than 1 MiB; send less data")
        _ = await stops(proxy)
    }

    func testProxyProcessFailsACallWhoseAnswerOutgrowsTheLimitBeforeItsLineEnds() async throws {
        let script = try standIn(Self.ready + "\nIFS= read -r line\nprintf '{\"id\":1,\"ok\":true,\"body\":\"'\nhead -c 2000000 /dev/zero | tr '\\0' 'x'\nexec sleep 600")
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir, limits: .init(exit: .milliseconds(100), lineBytes: 1 << 20))
        _ = try await proxy.start()
        let text = await proxyFailure { _ = try await proxy.call("get", ["exchange": 1, "part": "response"]) }
        XCTAssertEqual(text, "alcove-proxy sent an answer larger than 1 MiB; ask for less with limit, offset or length")
        _ = await stops(proxy)
    }

    func testProxyProcessAgainstTheRealBinary() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = try tempDir()
        let binary = dir.appendingPathComponent("alcove-proxy").path
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["go", "build", "-o", binary, "./cmd/alcove-proxy"]
        build.currentDirectoryURL = repo.appendingPathComponent("guest-tools")
        let output = Pipe()
        build.standardOutput = output
        build.standardError = output
        do { try build.run() } catch { throw XCTSkip("go is not installed: \(error.localizedDescription)") }
        let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        build.waitUntilExit()
        if build.terminationStatus == 127 { throw XCTSkip("go is not installed: \(log)") }
        XCTAssertEqual(build.terminationStatus, 0, log)

        let caDir = dir.appendingPathComponent("ca")
        let proxy = ProxyProcess(executable: binary, caDirectory: caDir)
        addTeardownBlock {
            if let pid = proxy.processIdentifier, isChildOfThisProcess(pid) { kill(pid, SIGKILL) }
        }
        let started = try await proxy.start()
        XCTAssertTrue((1...65_535).contains(started.port))
        XCTAssertEqual(URL(fileURLWithPath: started.caPath).resolvingSymlinksInPath().path, caDir.appendingPathComponent("ca.pem").resolvingSymlinksInPath().path)
        let pem = try String(contentsOfFile: started.caPath, encoding: .utf8)
        XCTAssertNotNil(ControlHandler.certificateThumbprint(pem: pem))
        let key = try FileManager.default.attributesOfItem(atPath: caDir.appendingPathComponent("ca.key").path)
        XCTAssertEqual((key[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let configured = try await proxy.call("config", ["hosts": ["api.example.com"], "secrets": false, "bodies": true])
        XCTAssertEqual(configured, [:])
        let empty = try await proxy.call("list", ["limit": 1])
        XCTAssertEqual(empty["exchanges"], [])
        XCTAssertEqual(empty["next"]?.intValue, 0)
        XCTAssertEqual(empty["pending"], [])

        let canned = String(repeating: "z", count: 300_000)
        let added = try await proxy.call("rule.add", ["match": ["host": "api.example.com", "path": "/v1/*"],
                                                      "action": ["status": 503, "body": .string(canned), "times": 2]])
        let rule = try XCTUnwrap(added["rule"]?.intValue)
        let listed = try await proxy.call("rule.list", [:])
        let rows = try XCTUnwrap(listed["rules"]?.arrayValue)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["id"]?.intValue, rule)
        XCTAssertEqual(rows[0]["hits"]?.intValue, 0)
        XCTAssertEqual(rows[0]["remaining"]?.intValue, 2)
        XCTAssertEqual(rows[0]["match"]?["host"]?.stringValue, "api.example.com")
        XCTAssertEqual(rows[0]["action"]?["body"]?.stringValue?.count, 300_000)

        let noExchange = await proxyFailure { _ = try await proxy.call("get", ["exchange": 9, "part": "response"]) }
        XCTAssertEqual(noExchange, "no exchange with id 9; the store keeps the newest 2000 exchanges and 'clear' removes them all")
        let unknown = await proxyFailure { _ = try await proxy.call("nope", [:]) }
        XCTAssertEqual(unknown, "unknown op 'nope'")
        _ = try await proxy.call("rule.remove", ["rule": .int(Int64(rule))])
        _ = try await proxy.call("rule.clear", [:])
        _ = try await proxy.call("clear", [:])
        XCTAssertEqual(proxy.bufferExtents.requests, 0)

        let pid = try XCTUnwrap(proxy.processIdentifier)
        let stopped = await stops(proxy)
        XCTAssertTrue(stopped)
        XCTAssertFalse(isAlive(pid))
    }
}
