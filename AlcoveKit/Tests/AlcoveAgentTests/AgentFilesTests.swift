import XCTest
@testable import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

final class AgentFilesTests: XCTestCase {
    private func randomData(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    private func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentfiles-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func connected(_ fs: FakeFS) async throws -> (FakeAgent, AgentClient) {
        let agent = FakeAgent().start()
        addTeardownBlock { agent.stop() }
        fs.install(on: agent)
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        return (agent, client)
    }

    func testPushFileToGuestPath() async throws {
        let fs = FakeFS()
        let (_, client) = try await connected(fs)
        let local = try tempDir().appendingPathComponent("blob.bin")
        let payload = randomData(700_000)
        try payload.write(to: local)

        let r = try await client.pushFile(local, toGuestPath: "/data/in/blob.bin", overwrite: false)
        XCTAssertEqual(fs["/data/in/blob.bin"], payload)
        XCTAssertNil(fs["/data/in/blob.bin.alcove-part"])
        XCTAssertEqual(r.guestPath, "/data/in/blob.bin")
        XCTAssertEqual(r.bytes, 700_000)
        XCTAssertEqual(r.sha256, SHA256Digest.hex(of: payload))

        do { _ = try await client.pushFile(local, toGuestPath: "/data/in/blob.bin", overwrite: false); XCTFail("expected refusal") }
        catch AgentClient.AgentError.remote(let text) { XCTAssertEqual(text, "'/data/in/blob.bin' exists in the guest; pass overwrite") }

        let replacement = randomData(1000)
        try replacement.write(to: local)
        _ = try await client.pushFile(local, toGuestPath: "/data/in/blob.bin", overwrite: true)
        XCTAssertEqual(fs["/data/in/blob.bin"], replacement)
    }

    func testPushDigestMismatch() async throws {
        let fs = FakeFS()
        fs.corruptWrites = true
        let (_, client) = try await connected(fs)
        let local = try tempDir().appendingPathComponent("blob.bin")
        try randomData(5000).write(to: local)
        do { _ = try await client.pushFile(local, toGuestPath: "/data/blob.bin", overwrite: false); XCTFail("expected mismatch") }
        catch AgentClient.AgentError.remote(let text) { XCTAssertEqual(text, "the copy of '/data/blob.bin' in the guest does not match the host file after the upload; push the file again") }
        XCTAssertEqual(fs.paths(), [])
    }

    func testPullFile() async throws {
        let fs = FakeFS()
        let payload = randomData(700_000)
        fs["/data/out.bin"] = payload
        let (_, client) = try await connected(fs)
        let dest = try tempDir().appendingPathComponent("out.bin")
        let r = try await client.pullFile(guestPath: "/data/out.bin", to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), payload)
        XCTAssertEqual(r.sha256, SHA256Digest.hex(of: payload))
        XCTAssertEqual(r.bytes, 700_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path + ".alcove-part"))
    }

    func testPullOntoAHostFolderIsRefusedBeforeAnyRequestAndKeepsTheFolder() async throws {
        let fs = FakeFS()
        fs["C:\\out\\log.txt"] = randomData(1000)
        let (agent, client) = try await connected(fs)
        let folder = try tempDir()
        try Data("keep".utf8).write(to: folder.appendingPathComponent("inside.txt"))
        do {
            _ = try await client.pullFile(guestPath: "C:\\out\\log.txt", to: folder)
            XCTFail("expected a refusal")
        } catch AgentClient.AgentError.remote(let text) {
            XCTAssertEqual(text, "'\(folder.path)' is a folder on the host; pass the path of the file to create, such as \(folder.path)/log.txt")
        }
        XCTAssertEqual(try hostFiles(folder), ["inside.txt"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("inside.txt")), Data("keep".utf8))
        XCTAssertEqual(agent.received.filter { $0["t"]?.stringValue == "req" }.count, 0)
    }

    func testPullKeepsAFolderCreatedAtTheDestinationDuringThePull() async throws {
        let fs = FakeFS()
        fs["/data/out.bin"] = randomData(1000)
        let (agent, client) = try await connected(fs)
        let dir = try tempDir()
        let dest = dir.appendingPathComponent("out.bin")
        let inner = agent.handler
        agent.handler = { m, a in
            if m["op"]?.stringValue == "fs.read", !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
                try? Data("keep".utf8).write(to: dest.appendingPathComponent("inside.txt"))
            }
            return inner?(m, a) ?? []
        }
        do {
            _ = try await client.pullFile(guestPath: "/data/out.bin", to: dest)
            XCTFail("expected a failure")
        } catch AgentClient.AgentError.remote(let text) {
            XCTAssertTrue(text.hasPrefix("'\(dest.path)' could not be replaced: "), text)
            XCTAssertTrue(text.hasSuffix("; pass the path of a file that is not a folder"), text)
        }
        XCTAssertEqual(try hostFiles(dir), ["out.bin"])
        XCTAssertEqual(try hostFiles(dest), ["inside.txt"])
    }

    func testPullKeepsAFolderNamedLikeItsPartFile() async throws {
        let fs = FakeFS()
        fs["/data/out.bin"] = randomData(1000)
        let (_, client) = try await connected(fs)
        let dir = try tempDir()
        let dest = dir.appendingPathComponent("out.bin")
        let part = dir.appendingPathComponent("out.bin.alcove-part")
        try FileManager.default.createDirectory(at: part, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: part.appendingPathComponent("inside.txt"))
        do { _ = try await client.pullFile(guestPath: "/data/out.bin", to: dest); XCTFail("expected a refusal") }
        catch AgentClient.AgentError.remote(let text) {
            XCTAssertEqual(text, "'\(part.path)' is a folder on the host, and the pull writes its partial copy there; move that folder away or pull to another path")
        }
        XCTAssertEqual(try Data(contentsOf: part.appendingPathComponent("inside.txt")), Data("kept".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testPullReplacesAnExistingFile() async throws {
        let fs = FakeFS()
        let payload = randomData(1000)
        fs["/data/out.bin"] = payload
        let (_, client) = try await connected(fs)
        let dir = try tempDir()
        let dest = dir.appendingPathComponent("out.bin")
        try Data("earlier".utf8).write(to: dest)
        _ = try await client.pullFile(guestPath: "/data/out.bin", to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), payload)
        XCTAssertEqual(try hostFiles(dir), ["out.bin"])
    }

    /// A connected agent over `fs` that leaves the `held`-th `fs.read` request (counted from 1) unanswered and keeps its reply.
    private func connectedHoldingRead(_ fs: FakeFS, held: Int) async throws -> (FakeAgent, AgentClient, LockedBox<JSON?>) {
        let (agent, client) = try await connected(fs)
        let inner = agent.handler
        let reads = LockedBox(0)
        let kept = LockedBox<JSON?>(nil)
        agent.handler = { m, a in
            let replies = inner?(m, a) ?? []
            guard m["op"]?.stringValue == "fs.read" else { return replies }
            reads.value += 1
            guard reads.value == held else { return replies }
            kept.value = replies.first
            return []
        }
        return (agent, client, kept)
    }

    /// Returns once `condition` holds; fails the test when it does not hold within 20 s.
    private func waitFor(_ condition: () -> Bool) async {
        let limit = ContinuousClock.now + .seconds(20)
        while !condition() {
            if ContinuousClock.now >= limit { XCTFail("the awaited state was not reached within 20 s"); return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func hostFiles(_ dir: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() }

    func testPullCancelledBetweenPiecesLeavesNoHostFile() async throws {
        let fs = FakeFS()
        fs["/data/out.bin"] = randomData(700_000)
        let (agent, client, kept) = try await connectedHoldingRead(fs, held: 2)
        let dir = try tempDir()
        let dest = dir.appendingPathComponent("out.bin")
        let pull = Task { try await client.pullFile(guestPath: "/data/out.bin", to: dest) }
        await waitFor { kept.value != nil }
        pull.cancel()
        agent.sendLine(kept.value!)
        do { _ = try await pull.value; XCTFail("expected a cancelled pull") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(try hostFiles(dir), [])
        XCTAssertEqual(agent.received.filter { $0["op"]?.stringValue == "fs.read" }.count, 2)
    }

    func testPullCancelledDuringTheLastPieceLeavesNoHostFile() async throws {
        let fs = FakeFS()
        fs["/data/out.bin"] = randomData(700_000)
        let (agent, client, kept) = try await connectedHoldingRead(fs, held: 3)
        let dir = try tempDir()
        let dest = dir.appendingPathComponent("out.bin")
        let pull = Task { try await client.pullFile(guestPath: "/data/out.bin", to: dest) }
        await waitFor { kept.value != nil }
        XCTAssertEqual(kept.value?["eof"]?.boolValue, true)
        pull.cancel()
        agent.sendLine(kept.value!)
        do { _ = try await pull.value; XCTFail("expected a cancelled pull") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(try hostFiles(dir), [])
    }

    func testCancelledPullKeepsAnExistingDestinationFile() async throws {
        let fs = FakeFS()
        fs["/data/out.bin"] = randomData(1000)
        let (agent, client, kept) = try await connectedHoldingRead(fs, held: 1)
        let dir = try tempDir()
        let dest = dir.appendingPathComponent("out.bin")
        try Data("earlier".utf8).write(to: dest)
        let pull = Task { try await client.pullFile(guestPath: "/data/out.bin", to: dest) }
        await waitFor { kept.value != nil }
        pull.cancel()
        agent.sendLine(kept.value!)
        _ = try? await pull.value
        XCTAssertEqual(try hostFiles(dir), ["out.bin"])
        XCTAssertEqual(try Data(contentsOf: dest), Data("earlier".utf8))
    }

    func testPullWithADeadlineEndsWhenAPieceIsNotAnswered() async throws {
        let fs = FakeFS()
        fs["/data/out.bin"] = randomData(700_000)
        let (agent, client, _) = try await connectedHoldingRead(fs, held: 2)
        let dir = try tempDir()
        let origin = ContinuousClock.now
        let readings = LockedBox(0)
        let clock: @Sendable () -> ContinuousClock.Instant = {
            readings.value += 1
            return readings.value <= 2 ? origin : origin + .seconds(3600) - .milliseconds(20)
        }
        do {
            _ = try await client.pullFile(guestPath: "/data/out.bin", to: dir.appendingPathComponent("out.bin"),
                                          deadline: origin + .seconds(3600), now: clock)
            XCTFail("expected a timeout")
        } catch AgentClient.AgentError.timeout(let op) { XCTAssertEqual(op, "fs.read") }
        XCTAssertEqual(try hostFiles(dir), [])
        XCTAssertEqual(agent.received.filter { $0["op"]?.stringValue == "fs.read" }.count, 2)
    }

    func testPullWithADeadlineEndsWhenTheStatIsNotAnswered() async throws {
        let agent = FakeAgent().start()
        addTeardownBlock { agent.stop() }
        agent.handler = { _, _ in [] }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        let dir = try tempDir()
        let origin = ContinuousClock.now
        do {
            _ = try await client.pullFile(guestPath: "/data/out.bin", to: dir.appendingPathComponent("out.bin"),
                                          deadline: origin + .milliseconds(20), now: { origin })
            XCTFail("expected a timeout")
        } catch AgentClient.AgentError.timeout(let op) { XCTAssertEqual(op, "fs.stat") }
        XCTAssertEqual(try hostFiles(dir), [])
    }

    func testPullAfterItsDeadlineSendsNothing() async throws {
        let fs = FakeFS()
        fs["/data/out.bin"] = randomData(1000)
        let (agent, client) = try await connected(fs)
        let dir = try tempDir()
        do {
            _ = try await client.pullFile(guestPath: "/data/out.bin", to: dir.appendingPathComponent("out.bin"), deadline: .now - .seconds(1))
            XCTFail("expected a timeout")
        } catch AgentClient.AgentError.timeout(let op) { XCTAssertEqual(op, "fs.stat") }
        XCTAssertEqual(agent.received.filter { $0["t"]?.stringValue == "req" }.count, 0)
        XCTAssertEqual(try hostFiles(dir), [])
    }

    func testPullWithADeadlineAheadCopiesTheFile() async throws {
        let fs = FakeFS()
        let payload = randomData(300_000)
        fs["/data/out.bin"] = payload
        let (_, client) = try await connected(fs)
        let dest = try tempDir().appendingPathComponent("out.bin")
        let r = try await client.pullFile(guestPath: "/data/out.bin", to: dest, deadline: .now + .seconds(600), maxBytes: 300_000)
        XCTAssertEqual(r.bytes, 300_000)
        XCTAssertEqual(try Data(contentsOf: dest), payload)
    }

    func testPullRefusesAFileWithMoreThanMaxBytesBeforeReadingIt() async throws {
        let fs = FakeFS()
        fs["/data/out.bin"] = randomData(1000)
        let (agent, client) = try await connected(fs)
        let dir = try tempDir()
        do {
            _ = try await client.pullFile(guestPath: "/data/out.bin", to: dir.appendingPathComponent("out.bin"), maxBytes: 999)
            XCTFail("expected a refusal")
        } catch let error as TransferTooLarge {
            XCTAssertEqual(error, TransferTooLarge(guestPath: "/data/out.bin", bytes: 1000, limit: 999))
        }
        XCTAssertEqual(agent.received.filter { $0["op"]?.stringValue == "fs.read" }.count, 0)
        XCTAssertEqual(try hostFiles(dir), [])
    }

    func testPullStopsWhenTheFileHoldsMoreThanMaxBytesAfterItWasMeasured() async throws {
        let fs = FakeFS()
        fs["/data/out.bin"] = randomData(1000)
        let (agent, client) = try await connected(fs)
        let inner = agent.handler
        agent.handler = { m, a in
            if m["op"]?.stringValue == "fs.read" { fs["/data/out.bin"] = Data(repeating: 1, count: 600_000) }
            return inner?(m, a) ?? []
        }
        let dir = try tempDir()
        do {
            _ = try await client.pullFile(guestPath: "/data/out.bin", to: dir.appendingPathComponent("out.bin"), maxBytes: 300_000)
            XCTFail("expected a refusal")
        } catch let error as TransferTooLarge {
            XCTAssertEqual(error.limit, 300_000)
        }
        XCTAssertEqual(agent.received.filter { $0["op"]?.stringValue == "fs.read" }.count, 2)
        XCTAssertEqual(try hostFiles(dir), [])
    }

    private func makeTree() throws -> (URL, Data, Data, Data) {
        let root = try tempDir()
        let a = Data("same".utf8), b = Data("new contents".utf8), k = Data("한글".utf8)
        try a.write(to: root.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try b.write(to: root.appendingPathComponent("sub/b.bin"))
        try k.write(to: root.appendingPathComponent("한글 파일.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: root.appendingPathComponent("a.txt"))
        return (root, a, b, k)
    }

    func testSyncDirectory() async throws {
        for deleteExtras in [true, false] {
            let (root, a, b, k) = try makeTree()
            let fs = FakeFS()
            fs["/g/in/a.txt"] = a
            fs["/g/in/sub/b.bin"] = Data("old".utf8)
            fs["/g/in/old.txt"] = Data("x".utf8)
            let (_, client) = try await connected(fs)
            let r = try await client.syncDirectory(root, toGuestPath: "/g/in", deleteExtras: deleteExtras)
            XCTAssertEqual(r.sent, ["sub/b.bin", "한글 파일.txt"])
            XCTAssertEqual(r.skipped, 1)
            XCTAssertEqual(r.deleted, deleteExtras ? ["old.txt"] : [])
            XCTAssertEqual(r.bytes, b.count + k.count)
            XCTAssertEqual(fs["/g/in/sub/b.bin"], b)
            XCTAssertEqual(fs["/g/in/한글 파일.txt"], k)
            XCTAssertEqual(fs["/g/in/old.txt"] == nil, deleteExtras)
            XCTAssertNil(fs["/g/in/link.txt"])
        }
    }

    func testSyncIntoMissingGuestDirectory() async throws {
        let (root, _, _, _) = try makeTree()
        let fs = FakeFS()
        let (_, client) = try await connected(fs)
        let r = try await client.syncDirectory(root, toGuestPath: "/g/new", deleteExtras: true)
        XCTAssertEqual(r.sent, ["a.txt", "sub/b.bin", "한글 파일.txt"])
        XCTAssertEqual(r.deleted, [])
    }

    func testSyncUsesBackslashForWindowsPaths() async throws {
        let (root, _, _, _) = try makeTree()
        let fs = FakeFS()
        let (_, client) = try await connected(fs)
        _ = try await client.syncDirectory(root, toGuestPath: "C:\\e2e\\in", deleteExtras: false)
        XCTAssertTrue(fs.written().contains("C:\\e2e\\in\\sub\\b.bin.alcove-part"))
        XCTAssertNotNil(fs["C:\\e2e\\in\\sub\\b.bin"])
    }

    private func caseTree(_ files: [String: String]) throws -> URL {
        let root = try tempDir()
        for (name, text) in files {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return root
    }

    func testSyncWindowsCaseDifferenceWithSameContentKeepsFile() async throws {
        let root = try caseTree(["README.txt": "same"])
        let fs = FakeFS()
        fs.caseInsensitive = true
        fs["C:\\g\\Readme.txt"] = Data("same".utf8)
        let (_, client) = try await connected(fs)
        let r = try await client.syncDirectory(root, toGuestPath: "C:\\g", deleteExtras: true)
        XCTAssertEqual(r.sent, [])
        XCTAssertEqual(r.skipped, 1)
        XCTAssertEqual(r.deleted, [])
        XCTAssertEqual(fs["C:\\g\\README.txt"], Data("same".utf8))
    }

    func testSyncWindowsCaseDifferenceWithNewContentUploadsAndKeepsFile() async throws {
        let root = try caseTree(["README.txt": "new text"])
        let fs = FakeFS()
        fs.caseInsensitive = true
        fs["C:\\g\\Readme.txt"] = Data("old".utf8)
        let (_, client) = try await connected(fs)
        let r = try await client.syncDirectory(root, toGuestPath: "C:\\g", deleteExtras: true)
        XCTAssertEqual(r.sent, ["README.txt"])
        XCTAssertEqual(r.deleted, [])
        XCTAssertEqual(fs["C:\\g\\README.txt"], Data("new text".utf8))
    }

    func testSyncWindowsNestedDirectoryCaseDifference() async throws {
        let root = try caseTree(["Docs/a.txt": "one"])
        let fs = FakeFS()
        fs.caseInsensitive = true
        fs["C:\\g\\docs\\a.txt"] = Data("one".utf8)
        let (_, client) = try await connected(fs)
        let r = try await client.syncDirectory(root, toGuestPath: "C:\\g", deleteExtras: true)
        XCTAssertEqual(r.sent, [])
        XCTAssertEqual(r.skipped, 1)
        XCTAssertEqual(r.deleted, [])
        XCTAssertEqual(fs["C:\\g\\Docs\\a.txt"], Data("one".utf8))
    }

    func testSyncWindowsRejectsLocalNamesDifferingOnlyByCase() async throws {
        let root = try caseTree(["a.txt": "1"])
        let listing = listSyncFiles
        listSyncFiles = { dir in [("A.txt", dir.appendingPathComponent("A.txt")), ("a.txt", dir.appendingPathComponent("a.txt"))] }
        defer { listSyncFiles = listing }
        XCTAssertThrowsError(try AgentClient.checkSyncSource(root, toGuestPath: "C:\\g")) { error in
            XCTAssertEqual(error as? AgentClient.AgentError,
                           .remote("'A.txt' and 'a.txt' differ only by case and cannot both exist in a Windows guest folder"))
        }
        let fs = FakeFS()
        let (agent, client) = try await connected(fs)
        do { _ = try await client.syncDirectory(root, toGuestPath: "C:\\g", deleteExtras: false); XCTFail("expected error") }
        catch AgentClient.AgentError.remote(let text) {
            XCTAssertEqual(text, "'A.txt' and 'a.txt' differ only by case and cannot both exist in a Windows guest folder")
        }
        XCTAssertFalse(agent.received.contains { $0["t"]?.stringValue == "req" })
        XCTAssertEqual(fs.paths(), [])
    }

    func testSyncSendsAFileOfTheSameSizeWithOtherContent() async throws {
        let root = try caseTree(["a.txt": "new", "b.txt": "same"])
        let fs = FakeFS()
        fs["/g/a.txt"] = Data("old".utf8)
        fs["/g/b.txt"] = Data("same".utf8)
        let (_, client) = try await connected(fs)
        let r = try await client.syncDirectory(root, toGuestPath: "/g", deleteExtras: false)
        XCTAssertEqual(r.sent, ["a.txt"])
        XCTAssertEqual(r.skipped, 1)
        XCTAssertEqual(r.bytes, 3)
        XCTAssertEqual(fs["/g/a.txt"], Data("new".utf8))
    }

    func testSyncNonWindowsPathKeepsCaseSensitiveNames() async throws {
        let root = try caseTree(["A.txt": "upper"])
        try XCTSkipUnless(FileManager.default.contentsOfDirectory(atPath: root.path) == ["A.txt"])
        let fs = FakeFS()
        fs["/g/a.txt"] = Data("upper".utf8)
        let (_, client) = try await connected(fs)
        let r = try await client.syncDirectory(root, toGuestPath: "/g", deleteExtras: true)
        XCTAssertEqual(r.sent, ["A.txt"])
        XCTAssertEqual(r.deleted, ["a.txt"])
        XCTAssertEqual(fs["/g/A.txt"], Data("upper".utf8))
        XCTAssertNil(fs["/g/a.txt"])
    }

    func testJoinGuestPathPutsOneSeparatorAfterARoot() {
        XCTAssertEqual(joinGuestPath("/", "x/y"), "/x/y")
        XCTAssertEqual(joinGuestPath("/g//", "x"), "/g/x")
        XCTAssertEqual(joinGuestPath("C:\\", "x/y"), "C:\\x\\y")
        XCTAssertEqual(joinGuestPath("C:\\g", "x"), "C:\\g\\x")
    }

    func testWindowsCaseConflictFindsNamesDifferingOnlyByCase() {
        XCTAssertNil(windowsCaseConflict(in: ["a.txt", "b.txt", "sub/a.txt"]))
        let pair = windowsCaseConflict(in: ["A.txt", "b.txt", "a.txt"])
        XCTAssertEqual(pair?.0, "A.txt")
        XCTAssertEqual(pair?.1, "a.txt")
    }

    func testPushRefusesDestinationCreatedBeforeRename() async throws {
        let fs = FakeFS()
        let (agent, client) = try await connected(fs)
        let inner = agent.handler
        agent.handler = { m, a in
            if m["op"]?.stringValue == "fs.rename" { fs["/data/blob.bin"] = Data("original".utf8) }
            return inner?(m, a) ?? []
        }
        let local = try tempDir().appendingPathComponent("blob.bin")
        try randomData(3000).write(to: local)
        do { _ = try await client.pushFile(local, toGuestPath: "/data/blob.bin", overwrite: false); XCTFail("expected refusal") }
        catch AgentClient.AgentError.remote(let text) { XCTAssertEqual(text, "'/data/blob.bin' exists in the guest; pass overwrite") }
        XCTAssertEqual(fs["/data/blob.bin"], Data("original".utf8))
        XCTAssertNil(fs["/data/blob.bin.alcove-part"])
        XCTAssertEqual(fs.paths(), ["/data/blob.bin"])
    }

    func testAPushRenameRefusedForAnotherReasonKeepsTheAgentSentence() async throws {
        let fs = FakeFS()
        let (agent, client) = try await connected(fs)
        let inner = agent.handler
        let refusal = "cannot rename '/data/exists/blob.bin.alcove-part' to '/data/exists/blob.bin': Access is denied."
        agent.handler = { m, a in
            if m["op"]?.stringValue == "fs.rename" { return [["t": "res", "id": m["id"] ?? .null, "ok": false, "error": .string(refusal)]] }
            return inner?(m, a) ?? []
        }
        let local = try tempDir().appendingPathComponent("blob.bin")
        try randomData(3000).write(to: local)
        do { _ = try await client.pushFile(local, toGuestPath: "/data/exists/blob.bin", overwrite: false); XCTFail("expected refusal") }
        catch AgentClient.AgentError.remote(let text) { XCTAssertEqual(text, refusal) }
        XCTAssertEqual(fs.paths(), [])
    }

    func testACancelledPushRemovesItsPartFile() async throws {
        let fs = FakeFS()
        let (agent, client) = try await connected(fs)
        let inner = agent.handler
        let writes = LockedBox(0)
        let kept = LockedBox<JSON?>(nil)
        agent.handler = { m, a in
            if m["op"]?.stringValue == "fs.write" {
                writes.value += 1
                if writes.value == 2 {
                    kept.value = inner?(m, a).first
                    return []
                }
            }
            return inner?(m, a) ?? []
        }
        let local = try tempDir().appendingPathComponent("blob.bin")
        try randomData(600_000).write(to: local)
        let push = Task { try await client.pushFile(local, toGuestPath: "/data/blob.bin", overwrite: false) }
        await waitFor { kept.value != nil }
        push.cancel()
        agent.sendLine(kept.value!)
        do { _ = try await push.value; XCTFail("expected a cancelled push") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(fs.paths(), [])
        XCTAssertEqual(agent.received.last?["op"]?.stringValue, "fs.delete")
    }

    func testPushRemovesPartFileWhenAWriteFails() async throws {
        let fs = FakeFS()
        let (agent, client) = try await connected(fs)
        let inner = agent.handler
        let writes = LockedBox(0)
        agent.handler = { m, a in
            if m["op"]?.stringValue == "fs.write" {
                writes.value += 1
                if writes.value == 2 { return [["t": "res", "id": m["id"] ?? .null, "ok": false, "error": "disk full"]] }
            }
            return inner?(m, a) ?? []
        }
        let local = try tempDir().appendingPathComponent("blob.bin")
        try randomData(600_000).write(to: local)
        do { _ = try await client.pushFile(local, toGuestPath: "/data/blob.bin", overwrite: false); XCTFail("expected failure") }
        catch AgentClient.AgentError.remote(let text) { XCTAssertEqual(text, "disk full") }
        XCTAssertEqual(fs.paths(), [])
    }
}
