import Foundation

/// The *name* of an environment variable — never its value.
///
/// Overture reasons about which credential a `claude` child will use, and it
/// does that by name only: `SECURITY.md` promises the app never reads, stores
/// or transmits your credentials. Giving names their own type means a value
/// cannot be smuggled into a diagnostic string by accident — it is a compile
/// error, not something a reviewer has to catch.
public struct EnvVarName: RawRepresentable, Sendable, Hashable,
                          ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: StringLiteralType) { rawValue = value }

    public var description: String { rawValue }
}

/// Builds the environment every `claude` child inherits.
///
/// This is the single place the child environment is decided, so the
/// credential-precedence resolver and the spawner can never disagree about
/// what a session will actually authenticate as.
public enum ClaudeChildEnvironment {
    /// Variables Claude Code sets for *its own* children. Stripping these
    /// stops a nested session inheriting our session identity (M0 finding
    /// #10) — and that is the **only** reason Overture touches the `CLAUDE*`
    /// namespace.
    ///
    /// Exact names, never a prefix. A `CLAUDE`-prefix sweep also removes
    /// `CLAUDE_CONFIG_DIR` (which `TranscriptStore.configRoot` reads, and
    /// which keys the credential store), `CLAUDE_CODE_USE_BEDROCK` /
    /// `_USE_VERTEX` / `_USE_FOUNDRY`, and `CLAUDE_CODE_OAUTH_TOKEN` —
    /// silently breaking those users and desynchronising Overture's
    /// transcript reader from the CLI's writer.
    public static let nestedSessionMarkers: Set<EnvVarName> = [
        "CLAUDECODE",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_EXECPATH",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_HOST_SESSION_ID",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_PID",
        "CLAUDE_AGENT_SDK_VERSION",
        "CLAUDE_EFFORT",
    ]

    /// Variables that decide which credential a child authenticates with,
    /// in Anthropic's documented precedence order
    /// (code.claude.com/docs/en/authentication → "Authentication precedence").
    ///
    /// Referenced by name only: Overture never reads, copies, or logs their
    /// values. Used to explain precedence to the user, never to act on it.
    public static let credentialRelevant: [EnvVarName] = [
        // 1. Cloud provider selection.
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CODE_USE_FOUNDRY",
        // 2–3. Bearer token, then API key.
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_API_KEY",
        // 5. Long-lived OAuth token from `claude setup-token`, and the refresh
        //    token `claude auth login` can exchange instead of a browser.
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
        // 6. Anthropic profile / Workload Identity Federation.
        "ANTHROPIC_PROFILE",
        "ANTHROPIC_FEDERATION_RULE_ID",
        "ANTHROPIC_ORGANIZATION_ID",
        // Not a credential, but it redirects every request.
        "ANTHROPIC_BASE_URL",
        // Not a credential, but it selects *which* credential store is read.
        "CLAUDE_CONFIG_DIR",
    ]

    /// The environment for a `claude` child: the app's own environment, minus
    /// nested-session markers, plus Overture's spawn markers.
    ///
    /// Deliberately *not* the user's login-shell environment. A GUI-launched
    /// app inherits launchd's environment, so an `ANTHROPIC_API_KEY` exported
    /// from `.zshrc` is invisible here — and importing it wholesale would put
    /// the user's credentials in Overture's own memory, which is exactly what
    /// `SECURITY.md` promises does not happen. The divergence is reported to
    /// the user instead (see `ShellEnvironmentProbe`).
    public static func make(
        base: [String: String] = ProcessInfo.processInfo.environment,
        markers: [String: String] = [:]
    ) -> [String: String] {
        var environment = base
        for marker in nestedSessionMarkers {
            environment.removeValue(forKey: marker.rawValue)
        }
        for (key, value) in markers { environment[key] = value }
        return environment
    }

    /// Environment credentials that outrank a stored `claude auth login`
    /// (documented precedence levels 2, 3, 5 and 6). Cloud-provider switches
    /// are deliberately absent: they change where requests go, not which
    /// login is bypassed.
    public static let credentialOverrides: [EnvVarName] = [
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_API_KEY",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "ANTHROPIC_PROFILE",
        "ANTHROPIC_FEDERATION_RULE_ID",
        "ANTHROPIC_ORGANIZATION_ID",
    ]

    /// `environment` with every `credentialOverrides` name removed, used to ask
    /// the CLI which login sits underneath. Removes names; reads no value.
    public static func removingCredentialOverrides(
        from environment: [String: String]
    ) -> [String: String] {
        var stripped = environment
        for name in credentialOverrides {
            stripped.removeValue(forKey: name.rawValue)
        }
        return stripped
    }

    /// Names from `credentialRelevant` that are present in `environment`.
    /// Values are never read.
    public static func credentialVariablesPresent(
        in environment: [String: String]
    ) -> [EnvVarName] {
        credentialRelevant.filter { name in
            guard let value = environment[name.rawValue] else { return false }
            return !value.isEmpty
        }
    }
}
