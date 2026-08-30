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
        /// Environment for the child. `nil` inherits the parent environment.
        public var environment: [String: String]?
        /// Env var name prefixes stripped from the inherited/child env.
        /// Overture strips `CLAUDE` so nested sessions don't leak context.
        public var strippedEnvPrefixes: [String]

        public init(executable: URL,
                    arguments: [String] = [],
                    currentDirectory: URL? = nil,
                    environment: [String: String]? = nil,
                    strippedEnvPrefixes: [String] = []) {
            self.executable = executable
            self.arguments = arguments
            self.currentDirectory = currentDirectory
            self.environment = environment
            self.strippedEnvPrefixes = strippedEnvPrefixes
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
    private var exitContinuations: [CheckedContinuation<SubprocessExit, Never>] = []
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
        var env = configuration.environment ?? ProcessInfo.processInfo.environment
        for prefix in configuration.strippedEnvPrefixes {
            env = env.filter { !$0.key.hasPrefix(prefix) }
        }
        process.environment = env
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
        stderrReader = PipeLineReader(
            handle: stderrPipe.fileHandleForReading,
            onLine: { [weak self] line in
                Task { await self?.appendStderr(line) }
            },
            onEOF: {})

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

    /// Suspends until the child exits or the timeout elapses.
    public func waitForExit(upTo timeout: Duration) async -> SubprocessExit? {
        if let exitResult { return exitResult }
        return await withTaskGroup(of: SubprocessExit?.self) { group in
            group.addTask { await self.waitForExit() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
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
    }
}
