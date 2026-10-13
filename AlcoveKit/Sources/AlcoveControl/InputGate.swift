/// A FIFO async mutex per VM name: bodies for one VM run one at a time in
/// arrival order; bodies for different VMs do not wait for each other.
actor InputGate {
    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func withLock<T: Sendable>(_ vm: String, _ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire(vm)
        defer { release(vm) }
        return try await body()
    }

    /// The number of callers queued behind the current holder for `vm`.
    func waiterCount(for vm: String) -> Int { waiters[vm]?.count ?? 0 }

    private func acquire(_ vm: String) async {
        guard held.contains(vm) else { held.insert(vm); return }
        await withCheckedContinuation { waiters[vm, default: []].append($0) }
    }

    /// Hands the lock to the longest-waiting caller, or frees it when nobody waits.
    private func release(_ vm: String) {
        guard var queue = waiters[vm], !queue.isEmpty else { held.remove(vm); return }
        let next = queue.removeFirst()
        waiters[vm] = queue.isEmpty ? nil : queue
        next.resume()
    }
}
