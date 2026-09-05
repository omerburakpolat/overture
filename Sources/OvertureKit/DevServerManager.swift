import Foundation
import ProcessCore

/// Dev servers for the embedded preview pane (spec 02 §9). One server per
/// card (worktree mode — serving the branch's code) or per project
/// (single-dir). Servers never outlive the app; unlike agents, there is
/// nothing to resume.
public actor DevServerManager {
    public struct ServerHandle: Sendable, Equatable {
        public var key: UUID           // cardID (worktree) or projectID
        public var url: URL
        public var port: Int
    }

    public enum ServerError: Error, Sendable {
        case noCommandConfigured
        case launchFailed(String)
        case neverBecameReady(consoleTail: [String])
    }

    private struct Running {
        var subprocess: Subprocess
        var handle: ServerHandle
        var console: [String] = []
    }

    private var servers: [UUID: Running] = [:]
    private var nextSlot = 0
    private let readinessTimeout: Duration

    public init(readinessTimeout: Duration = .seconds(60)) {
        self.readinessTimeout = readinessTimeout
    }

    /// Starts (or returns) the server for `key`. The command is a template
    /// with a literal `{port}` placeholder (resolution #26); it runs via the
    /// user's login shell so toolchains resolve.
    public func start(key: UUID, commandTemplate: String, basePort: Int,
                      directory: URL) async throws -> ServerHandle {
        if let running = servers[key] { return running.handle }
        guard !commandTemplate.trimmingCharacters(in: .whitespaces).isEmpty
        else { throw ServerError.noCommandConfigured }

        let port = basePort + nextSlot
        nextSlot += 1
        // 2>&1: dev servers log readiness banners to stderr (python, vite);
        // the console strip must show them.
        let command = commandTemplate
            .replacingOccurrences(of: "{port}", with: String(port))
            + " 2>&1"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment
        environment["PORT"] = String(port)   // belt-and-braces for env readers

        let subprocess = Subprocess(configuration: .init(
            executable: URL(fileURLWithPath: shell),
            arguments: ["-lc", command],
            currentDirectory: directory,
            environment: environment))
        let handle = ServerHandle(
            key: key,
            url: URL(string: "http://localhost:\(port)")!,
            port: port)

        let lines: AsyncStream<String>
        do {
            lines = try await subprocess.start()
        } catch {
            throw ServerError.launchFailed(String(describing: error))
        }
        servers[key] = Running(subprocess: subprocess, handle: handle)
        Task { [weak self] in
            for await line in lines {
                await self?.appendConsole(key: key, line: line)
            }
            await self?.serverExited(key: key)
        }

        // Readiness: TCP connect probe (works for every stack; readyPattern
        // matching can refine this later).
        let deadline = ContinuousClock.now + readinessTimeout
        while ContinuousClock.now < deadline {
            if await Self.canConnect(port: port) { return handle }
            if servers[key] == nil {
                throw ServerError.neverBecameReady(
                    consoleTail: consoleTail(key: key))
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        await stop(key: key)
        throw ServerError.neverBecameReady(consoleTail: consoleTail(key: key))
    }

    public func handle(for key: UUID) -> ServerHandle? {
        servers[key]?.handle
    }

    /// Last console lines for the pane's collapsible strip.
    public func consoleTail(key: UUID, limit: Int = 40) -> [String] {
        Array((servers[key]?.console ?? []).suffix(limit))
    }

    public func stop(key: UUID) async {
        guard let running = servers.removeValue(forKey: key) else { return }
        _ = await running.subprocess.terminate(gracePeriod: .seconds(3))
    }

    public func stopAll() async {
        for key in Array(servers.keys) {
            await stop(key: key)
        }
    }

    // MARK: - Internals

    private func appendConsole(key: UUID, line: String) {
        servers[key]?.console.append(line)
        if let count = servers[key]?.console.count, count > 400 {
            servers[key]?.console.removeFirst(count - 400)
        }
    }

    private func serverExited(key: UUID) {
        servers[key] = nil
    }

    /// Any HTTP response (a 404 included) means the server is up; only a
    /// refused/failed connection means "not yet". Plain URLSession — the
    /// dev servers here are HTTP by definition, and this probe behaves
    /// identically on developer machines and CI runners.
    private static func canConnect(port: Int) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.httpMethod = "HEAD"
        return (try? await session.data(for: request)) != nil
    }
}
