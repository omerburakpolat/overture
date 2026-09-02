import Foundation
import ProcessCore

/// App-initiated sign-in that never touches credentials: Overture spawns the
/// user's own `claude auth login`, Anthropic's CLI + browser do everything,
/// and we just relay output (and forward the paste-back code if the flow
/// asks for one). See NOTICE — Overture must never proxy auth itself.
public actor AuthLogin {
    public enum Event: Sendable {
        case outputLine(String)
        case finished(loggedIn: Bool)
    }

    public enum Mode: String, Sendable {
        case subscription = "--claudeai"
        case console = "--console"
    }

    private var subprocess: Subprocess?

    public init() {}

    /// Starts `claude auth login`. Stream relays CLI output for the sheet;
    /// call `submit(_:)` to forward a confirmation code, `cancel()` to stop.
    public func start(claudeURL: URL,
                      mode: Mode = .subscription) async throws -> AsyncStream<Event> {
        let child = Subprocess(configuration: .init(
            executable: claudeURL,
            arguments: ["auth", "login", mode.rawValue],
            strippedEnvPrefixes: ClaudeCLI.strippedEnvPrefixes))
        subprocess = child
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        let lines = try await child.start()
        Task {
            for await line in lines {
                continuation.yield(.outputLine(line))
            }
            let exit = await child.waitForExit()
            continuation.yield(.finished(loggedIn: exit == .exited(code: 0)))
            continuation.finish()
        }
        return stream
    }

    /// Forwards user input (the OAuth confirmation code) to the CLI.
    public func submit(_ text: String) async {
        try? await subprocess?.writeLine(text)
    }

    public func cancel() async {
        _ = await subprocess?.terminate(gracePeriod: .seconds(1))
    }
}
