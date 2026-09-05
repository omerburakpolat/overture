import Foundation
import Network
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
        let command = commandTemplate
            .replacingOccurrences(of: "{port}", with: String(port))
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

    private static func canConnect(port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: UInt16(port))!,
                using: .tcp)
            // resume-once guard: state handler can fire repeatedly.
            let resumed = Locked(false)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.exchange(true) == false {
                        connection.cancel()
                        continuation.resume(returning: true)
                    }
                case .failed, .cancelled:
                    if resumed.exchange(true) == false {
                        continuation.resume(returning: false)
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if resumed.exchange(true) == false {
                    connection.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
    }
}

/// Minimal lock for the connect probe's resume-once guard.
private final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func exchange(_ new: Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        let old = value
        value = new
        return old
    }
}
