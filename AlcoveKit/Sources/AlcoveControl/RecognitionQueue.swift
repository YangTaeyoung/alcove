import Foundation
import Synchronization

/// Runs the readings of text (`ScreenText.read`) one at a time on a thread of its own, in the order they were
/// asked for, so that one recognizer call runs at a time.
///
/// A caller that asks for the frame and languages of the reading that runs or of one that waits joins it. A reading
/// that waits and has lost every caller is removed without being started; the running one ends and its result
/// goes to the callers that still wait.
final class RecognitionQueue: Sendable {
    typealias Recognizer = @Sendable (Frame, [String]) throws -> [TextMatch]
    typealias Outcome = Result<[TextMatch], Error>

    /// The queue of `vm.find_text`, of the text conditions of `vm.wait_for` and of the warm-up.
    static let shared = RecognitionQueue()

    private struct Request {
        let frame: Frame
        let languages: [String]?
        let recognizer: Recognizer
        var waiters: [Int: CheckedContinuation<Outcome?, Never>]
    }

    private struct State {
        var lastCaller = 0
        /// Callers that have a number and have not joined a request yet.
        var arriving: Set<Int> = []
        var running: Request?
        var waiting: [Request] = []
    }

    private enum Joined {
        case left
        case waits
        case starts(Request)
    }

    private let state = Mutex(State())
    private let worker = DispatchQueue(label: "alcove.control.recognition", qos: .userInitiated)

    /// The readings in the queue: whether one runs, how many callers wait for it and how many others wait for
    /// their turn.
    var load: (running: Bool, callers: Int, waiting: Int) {
        state.withLock { ($0.running != nil, $0.running?.waiters.count ?? 0, $0.waiting.count) }
    }

    /// `ScreenText.read` of `frame` and `languages` with `recognizer`, once the readings asked for earlier have ended.
    /// Nil when `limit` passed or the task was cancelled before the result arrived.
    func recognize(_ frame: Frame, languages: [String]?, recognizer: @escaping Recognizer = WaitTiming.recognizer,
                   until limit: ContinuousClock.Instant? = nil) async -> Outcome? {
        let caller = state.withLock { state in
            state.lastCaller += 1
            state.arriving.insert(state.lastCaller)
            return state.lastCaller
        }
        let timer = limit.map { limit in
            Task {
                guard (try? await Task.sleep(until: limit, clock: ContinuousClock())) != nil else { return }
                self.leave(caller)
            }
        }
        defer { timer?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.join(caller, frame: frame, languages: languages, recognizer: recognizer, continuation)
            }
        } onCancel: {
            self.leave(caller)
        }
    }

    /// Adds `caller` to the request for the same frame and languages, or to a new one behind the others; the new
    /// one starts at once when none runs. A caller that has left gets nil.
    private func join(_ caller: Int, frame: Frame, languages: [String]?, recognizer: @escaping Recognizer,
                      _ continuation: CheckedContinuation<Outcome?, Never>) {
        let joined: Joined = state.withLock { state in
            guard state.arriving.remove(caller) != nil else { return .left }
            if let running = state.running, running.languages == languages, running.frame == frame {
                state.running?.waiters[caller] = continuation
                return .waits
            }
            if let index = state.waiting.firstIndex(where: { $0.languages == languages && $0.frame == frame }) {
                state.waiting[index].waiters[caller] = continuation
                return .waits
            }
            let request = Request(frame: frame, languages: languages, recognizer: recognizer, waiters: [caller: continuation])
            guard state.running == nil else {
                state.waiting.append(request)
                return .waits
            }
            state.running = request
            return .starts(request)
        }
        switch joined {
        case .left: continuation.resume(returning: nil)
        case .waits: break
        case .starts(let request): run(request)
        }
    }

    /// Takes `caller` out of the queue and answers it nil; a waiting request without callers is removed.
    private func leave(_ caller: Int) {
        let continuation: CheckedContinuation<Outcome?, Never>? = state.withLock { state in
            if state.arriving.remove(caller) != nil { return nil }
            if let found = state.running?.waiters.removeValue(forKey: caller) { return found }
            for index in state.waiting.indices {
                guard let found = state.waiting[index].waiters.removeValue(forKey: caller) else { continue }
                if state.waiting[index].waiters.isEmpty { state.waiting.remove(at: index) }
                return found
            }
            return nil
        }
        continuation?.resume(returning: nil)
    }

    /// Runs `request`, which is the running one, on the worker thread, answers its callers and starts the next.
    private func run(_ request: Request) {
        worker.async {
            let outcome = Outcome { try ScreenText.read(request.frame, languages: request.languages, with: request.recognizer) }
            let (callers, next) = self.state.withLock { state in
                let callers = state.running.map { Array($0.waiters.values) } ?? []
                state.running = state.waiting.isEmpty ? nil : state.waiting.removeFirst()
                return (callers, state.running)
            }
            for caller in callers { caller.resume(returning: outcome) }
            if let next { self.run(next) }
        }
    }
}
