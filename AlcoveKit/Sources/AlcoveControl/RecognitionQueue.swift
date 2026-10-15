import Foundation
import Synchronization

/// Runs the readings of text (`ScreenText.read`) on a serial dispatch queue, in the order they were asked for:
/// one recognizer call runs at a time.
///
/// A caller that asks for the frame and languages of the reading that runs or of one that waits joins it and gets
/// what the recognizer of that reading returns; the recognizer a joining caller names is not used. A reading that
/// has lost every caller before its turn is not started; the running one ends and its result goes to the callers
/// that still wait.
///
/// The reading of a caller runs at user-initiated quality of service and the warm-up at utility. From the moment the
/// reading of a caller comes to wait behind the running warm-up, the thread of the warm-up has the priority of a
/// caller's reading until the warm-up ends.
final class RecognitionQueue: Sendable {
    typealias Recognizer = @Sendable (Frame, [String]) throws -> [TextMatch]
    typealias Outcome = Result<[TextMatch], Error>
    /// What a caller is told: the outcome of its reading, or nil when it left the queue first.
    private typealias Answer = @Sendable (Outcome?) -> Void

    /// The outcome for a caller whose reading had not begun when its turn limit passed, or that joined the reading
    /// running when it arrived and that reading had not ended by then.
    struct Busy: Error {
        /// How long the running reading had been running by then.
        let running: Duration
    }

    /// The queue of `vm.find_text`, of the text conditions of `vm.wait_for` and of the warm-up.
    static let shared = RecognitionQueue()

    private enum Work {
        case reading(Frame, languages: [String]?)
        /// `ScreenText.warmUp`; no caller joins it.
        case warmUp

        func isReading(of frame: Frame, languages: [String]?) -> Bool {
            guard case .reading(let own, let ownLanguages) = self else { return false }
            return ownLanguages == languages && own == frame
        }
    }

    private struct Waiter {
        let answer: Answer
        /// Called once the caller's reading is the running one.
        let began: (@Sendable () -> Void)?
        /// Whether the caller joined the reading that was running when it arrived.
        var joinedRunning = false
    }

    private struct Request {
        let work: Work
        let recognizer: Recognizer
        var waiters: [Int: Waiter]

        var isWarmUp: Bool {
            if case .warmUp = work { return true }
            return false
        }

        var qos: DispatchQoS { isWarmUp ? .utility : .userInitiated }

        func read() throws -> [TextMatch] {
            switch work {
            case .reading(let frame, let languages):
                return try ScreenText.read(frame, languages: languages, with: recognizer)
            case .warmUp:
                ScreenText.warmUp(with: recognizer)
                return []
            }
        }
    }

    private struct State {
        var lastCaller = 0
        /// Callers that have a number and have not joined a request yet.
        var arriving: Set<Int> = []
        var running: Request?
        var runningSince = ContinuousClock.now
        /// Whether the thread of the running warm-up has been given the priority of a caller's reading.
        var raised = false
        var waiting: [Request] = []

        mutating func start(_ request: Request?) {
            running = request
            runningSince = .now
            raised = false
        }

        /// Ends the running request and makes the first waiting one the running one; returns the callers of the
        /// ended one and the new running one.
        mutating func advance() -> (callers: [Waiter], next: Request?) {
            let callers = running.map { Array($0.waiters.values) } ?? []
            start(waiting.isEmpty ? nil : waiting.removeFirst())
            return (callers, running)
        }

        /// Whether the caller that now waits behind the running request is the first to wait behind a warm-up.
        mutating func raises() -> Bool {
            guard running?.isWarmUp == true, !raised else { return false }
            raised = true
            return true
        }

        /// Removes `caller` from the waiting request that holds it, and the request when it has no caller left.
        mutating func removeWaiting(_ caller: Int) -> Waiter? {
            for index in waiting.indices {
                guard let found = waiting[index].waiters.removeValue(forKey: caller) else { continue }
                if waiting[index].waiters.isEmpty { waiting.remove(at: index) }
                return found
            }
            return nil
        }
    }

    private enum Joined {
        case left
        case busy(Duration)
        case runs
        case waits(raise: Bool)
        case starts(Request)
    }

    private let state = Mutex(State())
    private let worker = DispatchQueue(label: "alcove.control.recognition")

    /// The readings in the queue: whether one runs, how many callers wait for it and how many others wait for
    /// their turn.
    var load: (running: Bool, callers: Int, waiting: Int) {
        state.withLock { ($0.running != nil, $0.running?.waiters.count ?? 0, $0.waiting.count) }
    }

    /// `ScreenText.read` of `frame` and `languages` with `recognizer`, once the readings asked for earlier have ended.
    /// Nil when the task was cancelled before the result arrived. `Busy` when the reading had not begun at `limit`, and
    /// when the caller joined the reading that was running when it arrived and that reading had not ended at `limit`;
    /// the caller has then left the queue. `began` is called once the reading is the running one.
    func recognize(_ frame: Frame, languages: [String]?, recognizer: @escaping Recognizer = WaitTiming.recognizer,
                   turnBy limit: ContinuousClock.Instant? = nil, began: (@Sendable () -> Void)? = nil) async -> Outcome? {
        let caller = arrive()
        let timer = limit.map { limit in
            Task {
                guard (try? await Task.sleep(until: limit, clock: ContinuousClock())) != nil else { return }
                self.giveUpTurn(caller)
            }
        }
        defer { timer?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.join(caller, .reading(frame, languages: languages), recognizer: recognizer, turnBy: limit, began: began) {
                    continuation.resume(returning: $0)
                }
            }
        } onCancel: {
            self.leave(caller)
        }
    }

    /// Puts the warm-up (`ScreenText.warmUp`) in the queue and returns.
    func warmUp() {
        join(arrive(), .warmUp, recognizer: WaitTiming.recognizer, turnBy: nil, began: nil) { _ in }
    }

    /// A number for a new caller.
    private func arrive() -> Int {
        state.withLock { state in
            state.lastCaller += 1
            state.arriving.insert(state.lastCaller)
            return state.lastCaller
        }
    }

    /// Adds `caller` to the request for the same frame and languages, or to a new one behind the others; the new
    /// one starts at once when none runs. A caller that has left gets nil, and one that would wait for its turn
    /// after `limit` gets `Busy`.
    private func join(_ caller: Int, _ work: Work, recognizer: @escaping Recognizer, turnBy limit: ContinuousClock.Instant?,
                      began: (@Sendable () -> Void)?, _ answer: @escaping Answer) {
        let waiter = Waiter(answer: answer, began: began)
        let joined: Joined = state.withLock { state in
            guard state.arriving.remove(caller) != nil else { return .left }
            let request = Request(work: work, recognizer: recognizer, waiters: [caller: waiter])
            guard let running = state.running else {
                state.start(request)
                return .starts(request)
            }
            if case .reading(let frame, let languages) = work {
                let now = ContinuousClock.now
                if let limit, now >= limit { return .busy(now - state.runningSince) }
                if running.work.isReading(of: frame, languages: languages) {
                    var joiner = waiter
                    joiner.joinedRunning = true
                    state.running?.waiters[caller] = joiner
                    return .runs
                }
                if let index = state.waiting.firstIndex(where: { $0.work.isReading(of: frame, languages: languages) }) {
                    state.waiting[index].waiters[caller] = waiter
                    return .waits(raise: state.raises())
                }
            }
            state.waiting.append(request)
            return .waits(raise: !request.isWarmUp && state.raises())
        }
        switch joined {
        case .left:
            answer(nil)
        case .busy(let running):
            answer(.failure(Busy(running: running)))
        case .runs:
            began?()
        case .waits(let raise):
            if raise { worker.async(qos: .userInitiated, flags: .enforceQoS) {} }
        case .starts(let request):
            began?()
            run(request)
        }
    }

    /// Takes `caller` out of the queue and answers it nil; a waiting request without callers is removed.
    private func leave(_ caller: Int) {
        let waiter: Waiter? = state.withLock { state in
            if state.arriving.remove(caller) != nil { return nil }
            if let found = state.running?.waiters.removeValue(forKey: caller) { return found }
            return state.removeWaiting(caller)
        }
        waiter?.answer(nil)
    }

    /// Takes `caller` out of the queue when its reading waits for its turn or it joined the reading that was running
    /// when it arrived, and answers it `Busy`.
    private func giveUpTurn(_ caller: Int) {
        let left: (Waiter, Duration)? = state.withLock { state in
            if state.running?.waiters[caller]?.joinedRunning == true, let waiter = state.running?.waiters.removeValue(forKey: caller) {
                return (waiter, ContinuousClock.now - state.runningSince)
            }
            guard let waiter = state.removeWaiting(caller) else { return nil }
            return (waiter, ContinuousClock.now - state.runningSince)
        }
        if let (waiter, running) = left { waiter.answer(.failure(Busy(running: running))) }
    }

    /// Runs `request`, which is the running one, on the worker thread unless it has no caller by then, answers
    /// its callers and starts the next.
    private func run(_ request: Request) {
        worker.async(qos: request.qos, flags: .enforceQoS) {
            if let ended = self.state.withLock({ $0.running?.waiters.isEmpty == false ? nil : $0.advance() }) {
                return self.proceed(ended.next)
            }
            let outcome = Outcome { try request.read() }
            let ended = self.state.withLock { $0.advance() }
            for waiter in ended.callers { waiter.answer(outcome) }
            self.proceed(ended.next)
        }
    }

    /// Tells the callers of `next`, which has become the running request, that it began, and runs it.
    private func proceed(_ next: Request?) {
        guard let next else { return }
        for waiter in next.waiters.values { waiter.began?() }
        run(next)
    }
}
