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
}
