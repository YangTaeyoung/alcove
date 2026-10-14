import Foundation
import AlcoveEngine
import AlcoveQMP

/// The HTTP(S) proxy of one VM capture, as the control handler uses it.
public protocol ProxyControlling: Sendable {
    /// Starts the proxy and returns the loopback port it listens on and the host path of its CA certificate.
    func start() async throws -> (port: Int, caPath: String)
    /// Runs one proxy operation and returns the fields of its answer without `id` and `ok`.
    func call(_ op: String, _ params: [String: JSON]) async throws -> JSON
    /// Ends the proxy and returns once it has ended.
    func stop() async
}

/// One `alcove-proxy` child process. Requests go to its standard input and answers come from its standard output,
/// one JSON object per line; an answer is matched to its request by `id`. All state lives on a private serial queue.
public final class ProxyProcess: ProxyControlling, @unchecked Sendable {
    public enum ProxyError: Error, Equatable, CustomStringConvertible, Sendable {
        /// No `alcove-proxy` program was found on the host.
        case notFound
        /// The proxy answered a request with `ok: false`.
        case remote(String)
        /// The child could not be started, ended, or gave no usable answer.
        case failed(String)

        public var description: String {
            switch self {
            case .notFound: return "alcove-proxy was not found; build it with scripts/test/all.sh or set ALCOVE_PROXY"
            case .remote(let message), .failed(let message): return message
            }
        }
    }

    /// The bounds of one proxy process.
    public struct Limits: Sendable {
        /// Longest wait for the ready line.
        public var ready: Duration
        /// Longest wait for the answer to one request.
        public var call: Duration
        /// Longest wait for the child to end after its input was closed, and again after SIGTERM, which SIGKILL follows.
        /// Also the longest wait for the exit of a child that closed its output.
        public var exit: Duration
        /// The most bytes of one line the child may send or be sent.
        public var lineBytes: Int

        public init(ready: Duration = .seconds(15), call: Duration = .seconds(30), exit: Duration = .seconds(3), lineBytes: Int = 16 << 20) {
            self.ready = ready
            self.call = call
            self.exit = exit
            self.lineBytes = lineBytes
        }
    }

    private enum Phase {
        case idle, starting, ready
        /// The child is gone or going; the text is what a request gets as its failure.
        case ended(String)
    }

    private struct PendingCall {
        let op: String
        let continuation: CheckedContinuation<JSON, Error>
    }

    /// `~/Library/Application Support/Alcove/proxy-ca`, where the proxy keeps its CA certificate and key.
    public static var defaultCADirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Alcove/proxy-ca")
    }

    private static let restart = "call vm.http.stop, then vm.http.start to capture again"
    /// The most bytes of the child's standard error that are kept: its end.
    static let errorTailBytes = 8192

    private let executable: String?
    private let caDirectory: URL
    private let limits: Limits
    private let queue = DispatchQueue(label: "alcove.proxy.process")

    private var phase = Phase.idle
    private var process: Process?
    private var hasExited = false
    private var stopping = false
    private var inputFD: Int32 = -1
    private var outputFD: Int32 = -1
    private var errorFD: Int32 = -1
    private var outputSource: DispatchSourceRead?
    private var errorSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writerArmed = false
    /// The request bytes not yet written to the child; `outboxSent` of them, from the front, are written.
    private var outbox = Data()
    private var outboxSent = 0
    private var line = Data()
    /// Whether the bytes up to the next newline belong to a line that went over `limits.lineBytes`.
    private var discarding = false
    private var errorTail = Data()
    private var fatalText: String?
    private var startWaiter: CheckedContinuation<(port: Int, caPath: String), Error>?
    private var pending: [Int: PendingCall] = [:]
    private var nextID = 1
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    /// `executable` is the path of `alcove-proxy`, nil when the host has none; `caDirectory` is passed as `--ca-dir`.
    public init(executable: String?, caDirectory: URL = ProxyProcess.defaultCADirectory, limits: Limits = Limits()) {
        self.executable = executable
        self.caDirectory = caDirectory
        self.limits = limits
    }

    deinit {
        outputSource?.cancel()
        errorSource?.cancel()
        closeInput()
        if let process, process.isRunning { process.terminate() }
    }

    /// The process id of the child; nil before it was started.
    var processIdentifier: Int32? { queue.sync { process?.processIdentifier } }

    /// The number of requests the proxy has taken so far.
    var requestCount: Int { queue.sync { nextID - 1 } }

    /// How far the buffer of request bytes and the buffer of the child's standard error reach into their storage:
    /// the end index of each.
    var bufferExtents: (requests: Int, errors: Int) { queue.sync { (outbox.endIndex, errorTail.endIndex) } }

    public func start() async throws -> (port: Int, caPath: String) {
        try await withCheckedThrowingContinuation { waiter in
            queue.async { self.launch(waiter) }
        }
    }

    public func call(_ op: String, _ params: [String: JSON]) async throws -> JSON {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<JSON, Error>) in
            queue.async { self.request(op, params, waiter) }
        }
    }

    /// Closes the child's input and waits `limits.exit` for it to end, then sends SIGTERM, then SIGKILL.
    public func stop() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { self.beginStop(done) }
        }
    }

    // MARK: - start

    private func launch(_ waiter: CheckedContinuation<(port: Int, caPath: String), Error>) {
        guard case .idle = phase else {
            waiter.resume(throwing: ProxyError.failed("this proxy was started before; \(ProxyProcess.restart)"))
            return
        }
        guard let executable, FileManager.default.isExecutableFile(atPath: executable) else {
            phase = .ended(ProxyError.notFound.description)
            waiter.resume(throwing: ProxyError.notFound)
            return
        }
        let pipes = [ProxyProcess.makePipe(), ProxyProcess.makePipe(), ProxyProcess.makePipe()]
        guard let input = pipes[0], let output = pipes[1], let errors = pipes[2] else {
            for pipe in pipes.compactMap({ $0 }) { Darwin.close(pipe.read); Darwin.close(pipe.write) }
            let text = "alcove-proxy could not be started (the host has no free file descriptors); close other programs and call vm.http.start again"
            phase = .ended(text)
            waiter.resume(throwing: ProxyError.failed(text))
            return
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["--ca-dir", caDirectory.path]
        child.standardInput = FileHandle(fileDescriptor: input.read, closeOnDealloc: false)
        child.standardOutput = FileHandle(fileDescriptor: output.write, closeOnDealloc: false)
        child.standardError = FileHandle(fileDescriptor: errors.write, closeOnDealloc: false)
        let queue = self.queue
        child.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            let signalled = ended.terminationReason == .uncaughtSignal
            queue.async { [weak self] in self?.childExited(status: status, signalled: signalled) }
        }
        do {
            try child.run()
        } catch {
            for fd in [input.read, input.write, output.read, output.write, errors.read, errors.write] { Darwin.close(fd) }
            let text = "alcove-proxy could not be started (\(error.localizedDescription)); check the file at \(executable) or build it again with scripts/test/all.sh"
            phase = .ended(text)
            waiter.resume(throwing: ProxyError.failed(text))
            return
        }
        for fd in [input.read, output.write, errors.write] { Darwin.close(fd) }
        for fd in [input.write, output.read, errors.read] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        _ = fcntl(input.write, F_SETNOSIGPIPE, 1)
        process = child
        inputFD = input.write
        outputFD = output.read
        errorFD = errors.read
        outputSource = readSource(output.read) { $0.readOutput() }
        errorSource = readSource(errors.read) { $0.readErrors() }
        phase = .starting
        startWaiter = waiter
        let seconds = ProxyProcess.seconds(limits.ready)
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, case .starting = self.phase else { return }
            self.failStart("alcove-proxy did not report its port within \(ProxyProcess.rounded(seconds)) s; run '\(executable) --ca-dir \(self.caDirectory.path)' to see why")
        }
    }

    /// A pipe whose two ends are closed in every process this one starts, except where they become its standard streams.
    private static func makePipe() -> (read: Int32, write: Int32)? {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (fds[0], fds[1])
    }

    /// A read source on `fd` that runs `handler` on the queue and closes `fd` once it is cancelled.
    private func readSource(_ fd: Int32, _ handler: @escaping (ProxyProcess) -> Void) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            if let self { handler(self) }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        return source
    }

    /// Fails the pending start with `text` and ends the child.
    private func failStart(_ text: String) {
        phase = .ended(text)
        startWaiter?.resume(throwing: ProxyError.failed(text))
        startWaiter = nil
        closeInput()
        if let process, !hasExited, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    // MARK: - requests

    private func request(_ op: String, _ params: [String: JSON], _ waiter: CheckedContinuation<JSON, Error>) {
        switch phase {
        case .ready: break
        case .ended(let text): waiter.resume(throwing: ProxyError.failed(text)); return
        case .idle, .starting:
            waiter.resume(throwing: ProxyError.failed("alcove-proxy is not ready; call vm.http.start first"))
            return
        }
        let id = nextID
        nextID += 1
        var message = params
        message["id"] = .int(Int64(id))
        message["op"] = .string(op)
        guard var data = try? JSON.object(message).serialized(), data.count < limits.lineBytes else {
            waiter.resume(throwing: ProxyError.failed("the request '\(op)' is larger than \(limits.lineBytes >> 20) MiB; send less data"))
            return
        }
        data.append(10)
        guard outbox.count - outboxSent + data.count <= 4 * limits.lineBytes else {
            waiter.resume(throwing: ProxyError.failed("alcove-proxy is not reading its requests; \(ProxyProcess.restart)"))
            return
        }
        pending[id] = PendingCall(op: op, continuation: waiter)
        let seconds = ProxyProcess.seconds(limits.call)
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, let call = self.pending.removeValue(forKey: id) else { return }
            call.continuation.resume(throwing: ProxyError.failed(
                "alcove-proxy did not answer \(call.op) within \(ProxyProcess.rounded(seconds)) s; \(ProxyProcess.restart)"))
        }
        outbox.append(data)
        flush()
    }

    /// Writes the unsent request bytes until the pipe is full. The buffer is emptied once all of it is written, and
    /// loses its written front once that is larger than what is left.
    private func flush() {
        while inputFD >= 0, outboxSent < outbox.count {
            let sent = outboxSent
            let written = outbox.withUnsafeBytes { write(inputFD, $0.baseAddress! + sent, $0.count - sent) }
            if written > 0 { outboxSent += written; continue }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if outboxSent > outbox.count - outboxSent {
                    outbox = Data(outbox.dropFirst(outboxSent))
                    outboxSent = 0
                }
                armWriter()
                return
            }
            break
        }
        outbox = Data()
        outboxSent = 0
        if writerArmed {
            writeSource?.suspend()
            writerArmed = false
        }
    }

    private func armWriter() {
        if writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: inputFD, queue: queue)
            source.setEventHandler { [weak self] in self?.flush() }
            writeSource = source
        }
        if !writerArmed {
            writeSource?.resume()
            writerArmed = true
        }
    }

    /// Closes the child's standard input; unsent requests are dropped.
    private func closeInput() {
        guard inputFD >= 0 else { return }
        let fd = inputFD
        inputFD = -1
        outbox = Data()
        outboxSent = 0
        guard let source = writeSource else {
            Darwin.close(fd)
            return
        }
        source.setCancelHandler { Darwin.close(fd) }
        if !writerArmed { source.resume() }
        source.cancel()
        writeSource = nil
        writerArmed = false
    }

    // MARK: - output

    private func readOutput() {
        guard let source = outputSource else { return }
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(outputFD, $0.baseAddress, $0.count) }
            if count > 0 {
                consume(chunk[0..<count])
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            source.cancel()
            outputSource = nil
            outputClosed()
            return
        }
    }

    /// The child's standard output ended. A child that has not exited `limits.exit` later counts as gone: waiting
    /// requests and later ones fail, and the child is ended.
    private func outputClosed() {
        guard !hasExited, !stopping else { return }
        queue.asyncAfter(deadline: .now() + ProxyProcess.seconds(limits.exit)) { [weak self] in
            guard let self, !self.hasExited, !self.stopping, let process = self.process else { return }
            let text = "alcove-proxy closed its output and gives no more answers; \(ProxyProcess.restart)"
            switch self.phase {
            case .starting: self.failStart(text)
            case .ready:
                self.phase = .ended(text)
                self.failPending(text)
                self.closeInput()
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            case .idle, .ended: break
            }
        }
    }

    private func readErrors() {
        guard let source = errorSource else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(errorFD, $0.baseAddress, $0.count) }
            if count > 0 {
                errorTail.append(contentsOf: chunk[0..<count])
                if errorTail.count > ProxyProcess.errorTailBytes { errorTail = Data(errorTail.suffix(ProxyProcess.errorTailBytes)) }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            source.cancel()
            errorSource = nil
            return
        }
    }

    /// Splits `bytes` into lines. A line longer than `limits.lineBytes` is dropped up to its newline and fails every
    /// waiting request.
    private func consume(_ bytes: ArraySlice<UInt8>) {
        var rest = bytes
        while let newline = rest.firstIndex(of: 10) {
            let head = rest[rest.startIndex..<newline]
            rest = rest[(newline + 1)...]
            if discarding {
                discarding = false
                continue
            }
            guard line.count + head.count <= limits.lineBytes else {
                line = Data()
                failOversized()
                continue
            }
            line.append(contentsOf: head)
            let complete = line
            line = Data()
            if !complete.isEmpty { handle(complete) }
        }
        guard !discarding, !rest.isEmpty else { return }
        guard line.count + rest.count <= limits.lineBytes else {
            line = Data()
            discarding = true
            failOversized()
            return
        }
        line.append(contentsOf: rest)
    }

    private func failOversized() {
        let text = "alcove-proxy sent an answer larger than \(limits.lineBytes >> 20) MiB; ask for less with limit, offset or length"
        failPending(text)
        if case .starting = phase { failStart(text) }
    }

    private func handle(_ line: Data) {
        guard let message = try? JSON.parse(line), case .object(var fields) = message else {
            if case .starting = phase { failStart(ProxyProcess.unreadableStart) }
            return
        }
        if case .starting = phase {
            guard fields["ev"]?.stringValue == "ready", let port = fields["port"]?.intValue, (1...65_535).contains(port),
                  let ca = fields["ca"]?.stringValue, !ca.isEmpty else {
                failStart(ProxyProcess.unreadableStart)
                return
            }
            phase = .ready
            startWaiter?.resume(returning: (port, ca))
            startWaiter = nil
            return
        }
        if fields["ev"]?.stringValue == "fatal" {
            fatalText = fields["error"]?.stringValue
            return
        }
        guard let id = fields["id"]?.intValue, let call = pending.removeValue(forKey: id) else { return }
        if fields["ok"]?.boolValue == true {
            fields["id"] = nil
            fields["ok"] = nil
            call.continuation.resume(returning: .object(fields))
        } else {
            let text = fields["error"]?.stringValue ?? "alcove-proxy refused \(call.op) without a reason; \(ProxyProcess.restart)"
            call.continuation.resume(throwing: ProxyError.remote(text))
        }
    }

    private static let unreadableStart = "alcove-proxy printed a first line Alcove cannot read; build it again with scripts/test/all.sh"

    private func failPending(_ text: String) {
        let calls = pending.values
        pending.removeAll()
        for call in calls { call.continuation.resume(throwing: ProxyError.failed(text)) }
    }

    // MARK: - end

    /// The last line the child wrote to its standard error, without the program name it starts with.
    private func lastErrorLine() -> String {
        let text = String(decoding: errorTail, as: UTF8.self)
        guard var last = text.split(whereSeparator: \.isNewline).last.map(String.init) else { return "" }
        if last.hasPrefix("alcove-proxy: ") { last.removeFirst("alcove-proxy: ".count) }
        return last.trimmingCharacters(in: .whitespaces)
    }

    private func childExited(status: Int32, signalled: Bool) {
        readOutput()
        readErrors()
        hasExited = true
        let how = signalled ? "was ended by signal \(status)" : "exited with status \(status)"
        let said = fatalText ?? lastErrorLine()
        switch phase {
        case .starting:
            let text = said.isEmpty
                ? "alcove-proxy \(how) before it was ready; run '\(executable ?? "alcove-proxy") --ca-dir \(caDirectory.path)' to see why"
                : "alcove-proxy did not start: \(said)"
            phase = .ended(text)
            startWaiter?.resume(throwing: ProxyError.failed(text))
            startWaiter = nil
        case .ready:
            phase = .ended("alcove-proxy is not running (it \(how)\(said.isEmpty ? "" : ": \(said)")); \(ProxyProcess.restart)")
        case .idle, .ended:
            break
        }
        if case .ended(let text) = phase { failPending(text) }
        outputSource?.cancel()
        outputSource = nil
        errorSource?.cancel()
        errorSource = nil
        closeInput()
        let waiters = exitWaiters
        exitWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func beginStop(_ done: CheckedContinuation<Void, Never>) {
        guard let process, !hasExited else {
            if case .idle = phase { phase = .ended("the capture was stopped; call vm.http.start to capture again") }
            done.resume()
            return
        }
        exitWaiters.append(done)
        guard !stopping else { return }
        stopping = true
        let text = "the capture was stopped; call vm.http.start to capture again"
        if case .starting = phase {
            startWaiter?.resume(throwing: ProxyError.failed(text))
            startWaiter = nil
        }
        phase = .ended(text)
        failPending(text)
        closeInput()
        let step = ProxyProcess.seconds(limits.exit)
        queue.asyncAfter(deadline: .now() + step) { [weak self] in
            guard let self, !self.hasExited, process.isRunning else { return }
            process.terminate()
        }
        queue.asyncAfter(deadline: .now() + step * 2) { [weak self] in
            guard let self, !self.hasExited, process.isRunning else { return }
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// `seconds` as text without a fraction when it has none.
    private static func rounded(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }
}
