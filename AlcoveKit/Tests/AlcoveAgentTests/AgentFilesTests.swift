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
        catch AgentClient.AgentError.remote(let text) { XCTAssertEqual(text, "digest mismatch after upload") }
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
        do {
            _ = try await client.pullFile(guestPath: "/data/out.bin", to: dir.appendingPathComponent("out.bin"), deadline: .now + .milliseconds(300))
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
        do {
            _ = try await client.pullFile(guestPath: "/data/out.bin", to: dir.appendingPathComponent("out.bin"), deadline: .now + .milliseconds(300))
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
        let root = try caseTree(["a.txt": "1", "A.txt": "2"])
        try XCTSkipUnless(FileManager.default.contentsOfDirectory(atPath: root.path).count == 2, "case-insensitive local volume")
        let fs = FakeFS()
        let (agent, client) = try await connected(fs)
        let before = agent.receivedCount()
        do { _ = try await client.syncDirectory(root, toGuestPath: "C:\\g", deleteExtras: false); XCTFail("expected error") }
        catch AgentClient.AgentError.remote(let text) {
            XCTAssertEqual(text, "'A.txt' and 'a.txt' differ only by case and cannot both exist in a Windows guest folder")
        }
        XCTAssertEqual(agent.receivedCount(), before)
        XCTAssertEqual(fs.paths(), [])
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
