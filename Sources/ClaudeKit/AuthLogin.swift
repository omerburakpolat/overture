import Foundation
import ProcessCore

/// App-initiated sign-in that never touches credentials: Overture spawns the
/// user's own `claude auth login`, Anthropic's CLI and the browser do
/// everything, and Overture relays what it needs to drive a native screen.
/// See NOTICE — Overture must never proxy auth itself.
///
/// `auth login` is a plain `readline` prompt, not a full-screen terminal UI,
/// so pipes are the right transport and no pseudo-terminal is needed. Its
/// output, verified on CLI v2.1.236 over pipes with no TTY:
///
///     Opening browser to sign in…\n
///     If the browser didn't open, visit: <URL>\n
///     Paste code here if prompted >          ← no trailing newline
///
/// That last line never arrives as a *line*, so it can't be waited for.
/// `.awaitingCode` is emitted alongside the URL instead — the state is
/// knowable from the line before, which is newline-terminated.
public actor AuthLogin {
    public enum Mode: Sendable, Equatable, CaseIterable {
        /// A Claude subscription (Pro, Max, Team, Enterprise).
        case subscription
        /// An Anthropic Console account, billed per token.
        case console

        var flag: String {
            switch self {
            case .subscription: "--claudeai"
            case .console: "--console"
            }
        }

        /// Apple HIG: "Always identify the authentication method you offer."
        public var buttonTitle: String {
            switch self {
            case .subscription: "Sign In with Claude"
            case .console: "Sign In with Anthropic Console"
            }
        }

        public var subtitle: String {
            switch self {
            case .subscription: "Your Claude Pro, Max, Team or Enterprise plan."
            case .console: "An Anthropic Console account, billed per token."
            }
        }
    }

    public enum Event: Sendable, Equatable {
        case opening
        case authorizationURL(URL)
        case awaitingCode
        /// Any other relayed stdout line.
        case message(String)
        case invalidCode(String)
        case failed(String)
        case succeeded
        case ended(SubprocessExit)
    }

    /// Hosts an authorization URL may point at. A tampered or
    /// man-in-the-middled CLI must not be able to turn Overture into a
    /// one-click phishing launcher, so anything else is rendered as inert
    /// text rather than an openable link.
    static let allowedHosts: Set<String> = [
        "claude.com", "claude.ai", "www.claude.com",
        "platform.claude.com", "console.anthropic.com",
    ]

    private var subprocess: Subprocess?

    public init() {}

    public func start(claudeURL: URL,
                      mode: Mode = .subscription,
                      environment: [String: String]
                        = ClaudeChildEnvironment.make()) async throws
        -> AsyncStream<Event> {
        let child = Subprocess(configuration: .init(
            executable: claudeURL,
            arguments: ["auth", "login", mode.flag],
            environment: environment,
            streamsStderr: true))
        subprocess = child

        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        let lines = try await child.start()
        let errorLines = await child.stderrLines()

        Task {
            async let stdoutDone: Void = {
                for await line in lines {
                    for event in Self.events(forStdout: line) {
                        continuation.yield(event)
                    }
                }
            }()
            async let stderrDone: Void = {
                for await line in errorLines {
                    if let event = Self.event(forStderr: line) {
                        continuation.yield(event)
                    }
                }
            }()
            _ = await (stdoutDone, stderrDone)
            continuation.yield(.ended(await child.waitForExit()))
            continuation.finish()
        }
        return stream
    }

    /// Forwards the pasted value verbatim. The CLI expects `code#state` and
    /// splits on `#`, rejecting anything without both halves — so Overture
    /// must not trim, split, or "helpfully" clean it up.
    public func submit(_ pasted: String) async throws {
        try await subprocess?.writeLine(pasted)
    }

    public func cancel() async {
        _ = await subprocess?.terminate(gracePeriod: .seconds(1))
    }

    // MARK: - Parsing (pure, so it is tested without spawning anything)

    static func events(forStdout line: String) -> [Event] {
        if line.contains("Opening browser to sign in") { return [.opening] }
        if let url = authorizationURL(in: line) {
            // The "Paste code here if prompted > " prompt has no trailing
            // newline and so never arrives as a line. This is the last
            // moment we can know the CLI is ready for it.
            return [.authorizationURL(url), .awaitingCode]
        }
        if line.contains("Login successful") { return [.succeeded] }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? [] : [.message(Redaction.scrub(trimmed))]
    }

    static func event(forStderr line: String) -> Event? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("Invalid code") {
            return .invalidCode(Redaction.scrub(trimmed))
        }
        return .failed(Redaction.scrub(trimmed))
    }

    /// Pulls an authorization URL out of a relayed line, but only for a host
    /// Anthropic actually signs in on.
    static func authorizationURL(in line: String) -> URL? {
        guard let range = line.range(of: "https://") else { return nil }
        let candidate = line[range.lowerBound...]
            .prefix { !$0.isWhitespace }
        guard let url = URL(string: String(candidate)),
              url.scheme == "https",
              let host = url.host,
              allowedHosts.contains(host) else { return nil }
        return url
    }
}
