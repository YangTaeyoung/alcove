import XCTest
import AlcoveTestSupport

/// Asks `condition` again and again until it holds and returns true; after `limit` it records a failure that names
/// `what` and returns false.
func eventually(_ what: String, within limit: Duration = .seconds(20), file: StaticString = #filePath, line: UInt = #line,
                _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    if await condition() { return true }
    XCTFail("did not happen within \(limit): \(what)", file: file, line: line)
    return false
}

/// Runs `body` in a task of its own and returns true once it has finished; after `limit` it records a failure that
/// names `what` and returns false while `body` goes on.
func finishes(_ what: String, within limit: Duration = .seconds(20), file: StaticString = #filePath, line: UInt = #line,
              _ body: @escaping @Sendable () async -> Void) async -> Bool {
    let done = LockedBox(false)
    Task {
        await body()
        done.value = true
    }
    return await eventually(what, within: limit, file: file, line: line) { done.value }
}
