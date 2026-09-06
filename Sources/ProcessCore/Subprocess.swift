import Foundation

/// How a subprocess ended.
public enum SubprocessExit: Sendable, Equatable {
    case exited(code: Int32)
    case signalled(signal: Int32)
    case failedToLaunch(String)
}

/// One line-oriented child process: spawn, stream stdout lines, write stdin
/// lines, terminate with escalation. The only place in Overture that touches
/// `Foundation.Process` directly.
///
/// Invariants:
/// - stdout is consumed as UTF-8 lines with no length assumption (NDJSON
///   lines from `claude` can be multi-MB).
/// - stderr is retained as a bounded tail for diagnostics, never streamed.
/// - The reader runs off the caller's actor; lines are delivered through an
///   `AsyncStream` with unbounded buffering (producers coalesce upstream).
public actor Subprocess {
    public struct Configuration: Sendable {
        public var executable: URL
        public var arguments: [String]
        public var currentDirectory: URL?
        /// Environment for the child, verbatim. `nil` inherits the parent
        /// environment unchanged.
        ///
        /// There is deliberately no filtering hook here: callers that need to
        /// drop variables build the dictionary themselves, so exactly one
        /// place decides what a child inherits. For `claude` children that
        /// place is `ClaudeKit.ClaudeChildEnvironment.make(...)`.
        public var environment: [String: String]?

        /// When true, stderr lines are also delivered on `stderrLines()`.
        ///
        /// Off by default, and it must stay that way for the streaming
        /// session paths: their stdout carries NDJSON protocol traffic, and
        /// interleaving stderr into a second consumed stream is a needless
        /// way to introduce ordering bugs. Sign-in opts in because the CLI
        /// reports login failures *only* on stderr — without this a failed
        /// sign-in is a blank box.
        public var streamsStderr: Bool

        public init(executable: URL,
                    arguments: [String] = [],
                    currentDirectory: URL? = nil,
                    environment: [String: String]? = nil,
                    streamsStderr: Bool = false) {
            self.executable = executable
            self.arguments = arguments
            self.currentDirectory = currentDirectory
            self.environment = environment
            self.streamsStderr = streamsStderr
        }
    }

    public enum Failure: Error, Sendable {
        case notRunning
        case launchFailed(String)
        case stdinClosed
    }

    private let configuration: Configuration
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private var started = false
    private var stdinOpen = true
    private var stderrTail: [String] = []
    private let stderrTailLimit = 64

    private var lineContinuation: AsyncStream<String>.Continuation?
    private var stderrContinuation: AsyncStream<String>.Continuation?
    private var stderrStream: AsyncStream<String>?
    private var exitContinuations: [CheckedContinuation<SubprocessExit, Never>] = []
    private var timedExitContinuations: [UUID: CheckedContinuation<SubprocessExit?, Never>] = [:]
    private var exitResult: SubprocessExit?
    private var stdoutReader: PipeLineReader?
    private var stderrReader: PipeLineReader?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public var pid: Int32? { started ? process.processIdentifier : nil }

    /// Launches the child and returns the stream of stdout lines. The stream
    /// finishes when the child's stdout closes.
    public func start() throws -> AsyncStream<String> {
        precondition(!started, "Subprocess.start() called twice")
        started = true

        process.executableURL = configuration.executable
        process.arguments = configuration.arguments
        if let cwd = configuration.currentDirectory {
            process.currentDirectoryURL = cwd
        }
        process.environment = configuration.environment
            ?? ProcessInfo.processInfo.environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        lineContinuation = continuation

        process.terminationHandler = { [weak self] proc in
            let exit: SubprocessExit = proc.terminationReason == .uncaughtSignal
                ? .signalled(signal: proc.terminationStatus)
                : .exited(code: proc.terminationStatus)
            Task { [weak self] in await self?.finish(exit) }
        }

        do {
            try process.run()
        } catch {
            let exit = SubprocessExit.failedToLaunch(String(describing: error))
            Task { await self.finish(exit) }
            throw Failure.launchFailed(String(describing: error))
        }

        // Readers run on dispatch threads (readabilityHandler), NEVER the
        // Swift cooperative pool — blocking read(2) there can starve every
        // task in the process behind one long-lived child.
        stdoutReader = PipeLineReader(
            handle: stdoutPipe.fileHandleForReading,
            onLine: { line in continuation.yield(line) },
            onEOF: { [weak self] in
                Task { await self?.stdoutClosed() }
            })
        if configuration.streamsStderr {
            let (errStream, errContinuation) =
                AsyncStream.makeStream(of: String.self)
            stderrStream = errStream
            stderrContinuation = errContinuation
        }
        let errContinuation = stderrContinuation
        stderrReader = PipeLineReader(
            handle: stderrPipe.fileHandleForReading,
            onLine: { [weak self] line in
                errContinuation?.yield(line)
                Task { await self?.appendStderr(line) }
            },
            onEOF: { errContinuation?.finish() })

        return stream
    }

    /// Writes one line (a trailing newline is appended) to the child's stdin.
    public func writeLine(_ line: String) throws {
        guard started, exitResult == nil else { throw Failure.notRunning }
        guard stdinOpen else { throw Failure.stdinClosed }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            stdinOpen = false
            throw Failure.stdinClosed
        }
    }

    /// Closes stdin — the polite "no more input" signal.
    public func closeStdin() {
        guard stdinOpen else { return }
        stdinOpen = false
        try? stdinPipe.fileHandleForWriting.close()
    }

    /// Graceful escalation: close stdin, SIGINT, wait, SIGTERM, wait, SIGKILL.
    public func terminate(gracePeriod: Duration = .seconds(5)) async -> SubprocessExit {
        guard started else { return .exited(code: -1) }
        if let exitResult { return exitResult }
        closeStdin()
        process.interrupt() // SIGINT
        if let exit = await waitForExit(upTo: gracePeriod) { return exit }
        process.terminate() // SIGTERM
        if let exit = await waitForExit(upTo: gracePeriod) { return exit }
        kill(process.processIdentifier, SIGKILL)
        return await waitForExit()
    }

    /// Suspends until the child exits.
    public func waitForExit() async -> SubprocessExit {
        if let exitResult { return exitResult }
        return await withCheckedContinuation { exitContinuations.append($0) }
    }

    /// Suspends until the child exits or the timeout elapses (returns nil).
    /// NOTE: not a task group — a group would await its never-completing
    /// wait child at scope exit and deadlock until the process dies.
    public func waitForExit(upTo timeout: Duration) async -> SubprocessExit? {
        if let exitResult { return exitResult }
        let token = UUID()
        return await withCheckedContinuation { continuation in
            timedExitContinuations[token] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expireTimedWait(token: token)
            }
        }
    }

    private func expireTimedWait(token: UUID) {
        timedExitContinuations.removeValue(forKey: token)?
            .resume(returning: nil)
    }

    /// Stderr as lines. Empty and immediately finished unless the
    /// configuration set `streamsStderr`.
    public func stderrLines() -> AsyncStream<String> {
        stderrStream ?? AsyncStream { $0.finish() }
    }

    /// Last lines of stderr, for diagnostics on failure.
    public func stderrSnapshot() -> [String] { stderrTail }

    public var isRunning: Bool { started && exitResult == nil }

    // MARK: - Private

    private func stdoutClosed() {
        lineContinuation?.finish()
        lineContinuation = nil
    }

    private func appendStderr(_ line: String) {
        stderrTail.append(line)
        if stderrTail.count > stderrTailLimit {
            stderrTail.removeFirst(stderrTail.count - stderrTailLimit)
        }
    }

    private func finish(_ exit: SubprocessExit) {
        guard exitResult == nil else { return }
        exitResult = exit
        stdinOpen = false
        for continuation in exitContinuations {
            continuation.resume(returning: exit)
        }
        exitContinuations.removeAll()
        for (_, continuation) in timedExitContinuations {
            continuation.resume(returning: exit)
        }
        timedExitContinuations.removeAll()
    }
}
