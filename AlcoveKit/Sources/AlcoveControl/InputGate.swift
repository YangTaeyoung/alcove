/// A FIFO async mutex per VM name: holders for one VM follow each other in
/// arrival order; holders for different VMs do not wait for each other.
actor InputGate {
    /// How a queued caller stopped waiting.
    private enum Outcome { case granted, busy, cancelled }

    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Outcome, Never>
    }

    private var held: Set<String> = []
    private var waiters: [String: [Waiter]] = [:]
    private var nextID = 0

    /// Runs `body` while holding the lock of `vm`. The wait for the lock has no limit and does not end on cancellation.
    func withLock<T: Sendable>(_ vm: String, _ body: @Sendable () async throws -> T) async rethrows -> T {
        if held.contains(vm) {
            let id = takeID()
            _ = await withCheckedContinuation { waiters[vm, default: []].append(Waiter(id: id, continuation: $0)) }
        } else {
            held.insert(vm)
        }
        defer { release(vm) }
        return try await body()
    }

    /// The number of callers queued behind the current holder for `vm`.
    func waiterCount(for vm: String) -> Int { waiters[vm]?.count ?? 0 }

    /// Takes the lock of `vm`, waiting in the queue until `deadline` at most.
    ///
    /// Returns true once the caller holds the lock; it then calls `release` exactly once. Returns false when the
    /// deadline passed first. Throws `CancellationError`, without the lock, when the task was cancelled before it got it.
    func acquire(_ vm: String, until deadline: ContinuousClock.Instant) async throws -> Bool {
        try Task.checkCancellation()
        guard held.contains(vm) else { held.insert(vm); return true }
        guard ContinuousClock.now < deadline else { return false }
        let id = takeID()
        let timer = Task {
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            self.dismiss(id, from: vm, .busy)
        }
        defer { timer.cancel() }
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else {
                    waiters[vm, default: []].append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.dismiss(id, from: vm, .cancelled) }
        }
        switch outcome {
        case .granted: return true
        case .busy: return false
        case .cancelled: throw CancellationError()
        }
    }

    /// Hands the lock to the longest-waiting caller, or frees it when nobody waits.
    func release(_ vm: String) {
        guard var queue = waiters[vm], !queue.isEmpty else { held.remove(vm); return }
        let next = queue.removeFirst()
        waiters[vm] = queue.isEmpty ? nil : queue
        next.continuation.resume(returning: .granted)
    }

    private func takeID() -> Int {
        nextID += 1
        return nextID
    }

    /// Takes waiter `id` out of the queue of `vm` and resumes it with `outcome`; does nothing when it is no longer queued.
    private func dismiss(_ id: Int, from vm: String, _ outcome: Outcome) {
        guard var queue = waiters[vm], let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queue.remove(at: index)
        waiters[vm] = queue.isEmpty ? nil : queue
        waiter.continuation.resume(returning: outcome)
    }
}
