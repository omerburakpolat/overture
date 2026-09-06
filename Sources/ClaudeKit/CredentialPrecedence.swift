import Foundation

/// Works out which credential a `claude` child will actually authenticate
/// with, so Overture can tell the user rather than guess.
///
/// Anthropic documents seven credential sources in a fixed precedence order
/// (code.claude.com/docs/en/authentication). `claude auth status` reports some
/// of them and not others — measured on v2.1.236:
///
/// - `CLAUDE_CODE_USE_BEDROCK` → reported (`third_party` / `bedrock`)
/// - `ANTHROPIC_API_KEY` → reported, via `apiKeySource`
/// - `CLAUDE_CODE_OAUTH_TOKEN` → reported (`oauth_token`, identity dropped)
/// - `ANTHROPIC_AUTH_TOKEN` → **not reported**; status still says `claude.ai`
///
/// That last one is the gap this type exists to close. It matters because
/// Overture spawns every session headless (`-p`), and Anthropic documents
/// that in non-interactive mode an API key is *always* used when present —
/// there is no approval prompt to protect the user. A Max subscriber with a
/// stray key in this app's environment is silently paying per token.
public enum CredentialPrecedence {
    /// The seven documented sources, in precedence order.
    public enum Source: Sendable, Equatable {
        case cloudProvider(ClaudeAccount.APIProvider)   // 1
        case authTokenEnvironment                       // 2
        case apiKeyEnvironment                          // 3
        case apiKeyHelper                               // 4
        case oauthTokenEnvironment                      // 5
        case profile                                    // 6
        case storedLogin                                // 7
        case none

        public var level: Int {
            switch self {
            case .cloudProvider: 1
            case .authTokenEnvironment: 2
            case .apiKeyEnvironment: 3
            case .apiKeyHelper: 4
            case .oauthTokenEnvironment: 5
            case .profile: 6
            case .storedLogin: 7
            case .none: 8
            }
        }
    }

    /// How we know. `reportedByCLI` means `auth status` told us; `inferred`
    /// means we saw the variable name ourselves in the child environment and
    /// the CLI did not mention it.
    public enum Confidence: Sendable, Equatable {
        case reportedByCLI
        case inferredFromEnvironment
    }

    public struct Resolution: Sendable, Equatable {
        public var source: Source
        /// The variable NAMES that led to this conclusion. `EnvVarName` makes
        /// it impossible for a value to ride along.
        public var evidence: [EnvVarName]
        public var confidence: Confidence
        /// True when the credential that will actually bill differs from the
        /// account `auth status` reports. Drives the caution row in Settings,
        /// and gates dollar-denominated UI (resolution #13).
        public var overridesReportedLogin: Bool
        /// One plain sentence for the UI. Contains names, never values.
        public var explanation: String

        public var level: Int { source.level }
    }

    /// `childEnvironment` **must** be the dictionary
    /// `ClaudeChildEnvironment.make()` produced for the spawns being
    /// described — not the app's own environment. Passing anything else makes
    /// the answer a guess about a process that will never exist.
    public static func resolve(account: ClaudeAccount,
                               childEnvironment: [String: String]) -> Resolution {
        func isSet(_ name: EnvVarName) -> Bool {
            guard let value = childEnvironment[name.rawValue] else { return false }
            return !value.isEmpty
        }

        // 1. A cloud provider outranks everything, and the CLI reports it.
        if !account.apiProvider.isFirstParty {
            let switches: [EnvVarName] = [
                "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
                "CLAUDE_CODE_USE_FOUNDRY",
            ]
            return Resolution(
                source: .cloudProvider(account.apiProvider),
                evidence: switches.filter(isSet),
                confidence: .reportedByCLI,
                // Not an override: the CLI already says `third_party`, so
                // nothing the user sees is contradicted.
                overridesReportedLogin: false,
                explanation: "Requests go to \(account.apiProvider.displayName).")
        }

        // 2. ANTHROPIC_AUTH_TOKEN. Anthropic documents this as outranking a
        // stored login, but measured behaviour disagrees on a first-party
        // setup: `auth status` does not report it, and a request made with a
        // deliberately bogus value still succeeded on the signed-in account.
        // It is therefore reported as information, not as an override —
        // a false "you are being billed differently" warning is worse than
        // no warning. Revisit if a gateway/proxy configuration proves it is
        // honoured there.
        if isSet("ANTHROPIC_AUTH_TOKEN"), account.apiKeySource == nil {
            return Resolution(
                source: .authTokenEnvironment,
                evidence: ["ANTHROPIC_AUTH_TOKEN"],
                confidence: .inferredFromEnvironment,
                overridesReportedLogin: false,
                explanation: "ANTHROPIC_AUTH_TOKEN is set in this app's "
                    + "environment. Anthropic documents it as taking "
                    + "precedence over a signed-in account, but Claude Code "
                    + "does not report it, so Overture cannot confirm which "
                    + "one a request will use.")
        }

        // 3. ANTHROPIC_API_KEY — the case that costs money silently.
        if account.apiKeySource == "ANTHROPIC_API_KEY" || isSet("ANTHROPIC_API_KEY") {
            let overrides = account.authMethod == .claudeAI
            return Resolution(
                source: .apiKeyEnvironment,
                evidence: ["ANTHROPIC_API_KEY"],
                confidence: account.apiKeySource == nil
                    ? .inferredFromEnvironment : .reportedByCLI,
                overridesReportedLogin: overrides,
                explanation: overrides
                    ? "Agents will use ANTHROPIC_API_KEY from this app's "
                        + "environment, not your signed-in account. Claude Code "
                        + "always prefers an API key in headless mode, and "
                        + "Overture runs every agent headless."
                    : "Agents will use ANTHROPIC_API_KEY from this app's environment.")
        }

        // 4. apiKeyHelper — a script the CLI runs. Overture never runs it.
        if account.apiKeySource == "apiKeyHelper"
            || account.authMethod == .apiKeyHelper {
            return Resolution(
                source: .apiKeyHelper,
                evidence: [],
                confidence: .reportedByCLI,
                overridesReportedLogin: account.authMethod == .claudeAI,
                explanation: "A configured apiKeyHelper script supplies the key. "
                    + "Overture never runs it.")
        }

        // 5. CLAUDE_CODE_OAUTH_TOKEN — reported, and it erases identity.
        if account.authMethod == .oauthToken || isSet("CLAUDE_CODE_OAUTH_TOKEN") {
            return Resolution(
                source: .oauthTokenEnvironment,
                evidence: ["CLAUDE_CODE_OAUTH_TOKEN"],
                confidence: account.authMethod == .oauthToken
                    ? .reportedByCLI : .inferredFromEnvironment,
                // Not an override: there is no reported login to contradict.
                overridesReportedLogin: false,
                explanation: "A long-lived OAuth token is in use, so Claude Code "
                    + "reports no account details for this session.")
        }

        // 6. Anthropic profile / Workload Identity Federation.
        let profileNames: [EnvVarName] = ["ANTHROPIC_PROFILE",
                                          "ANTHROPIC_FEDERATION_RULE_ID",
                                          "ANTHROPIC_ORGANIZATION_ID"]
        let profileEvidence = profileNames.filter(isSet)
        if !profileEvidence.isEmpty {
            return Resolution(
                source: .profile,
                evidence: profileEvidence,
                confidence: .inferredFromEnvironment,
                overridesReportedLogin: account.authMethod == .claudeAI,
                explanation: "An Anthropic profile or federation credential is "
                    + "configured in this app's environment.")
        }

        // 7. The stored login from `claude auth login`.
        guard account.loggedIn else {
            return Resolution(source: .none, evidence: [],
                              confidence: .reportedByCLI,
                              overridesReportedLogin: false,
                              explanation: "No credential is available.")
        }
        return Resolution(
            source: .storedLogin,
            evidence: [],
            confidence: .reportedByCLI,
            overridesReportedLogin: false,
            explanation: account.email.map { "Agents will use your signed-in account (\($0))." }
                ?? "Agents will use the account signed in to Claude Code.")
    }
}
