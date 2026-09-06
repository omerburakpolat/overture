import Foundation
import ProcessCore

/// Decoded `claude auth status --json`.
///
/// Measured field set on CLI v2.1.236: `loggedIn`, `authMethod`,
/// `apiProvider`, `forcedLoginMethod?`, `apiKeySource?`, `email?`, `orgId?`,
/// `orgName?`, `subscriptionType?`.
///
/// The identity fields are emitted **only** when `authMethod` is `claude.ai`.
/// A `CLAUDE_CODE_OAUTH_TOKEN` session reports `oauth_token` with no email,
/// org or plan at all — "signed in, no identity" is a real state, not a
/// decoding failure, and the UI has to say so rather than showing a bare
/// "signed in".
public struct ClaudeAccount: Sendable, Equatable {
    /// How the CLI authenticated. A `RawRepresentable` struct rather than an
    /// enum with an `.other` case: the CLI's vocabulary is not a documented
    /// contract, and an unknown value must round-trip for display rather than
    /// being fatal (CLAUDE.md: "tolerant decoding").
    public struct AuthMethod: RawRepresentable, Sendable, Equatable, Hashable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }

        public static let claudeAI = Self("claude.ai")
        public static let console = Self("console")
        public static let apiKey = Self("api_key")
        public static let apiKeyHelper = Self("api_key_helper")
        public static let oauthToken = Self("oauth_token")
        public static let thirdParty = Self("third_party")
        public static let none = Self("none")

        /// Names the method the way the user would recognise it (Apple HIG:
        /// "Always identify the authentication method you offer"). An
        /// unrecognised value shows verbatim rather than as "Unknown".
        public var displayName: String {
            switch self {
            case .claudeAI: "Claude account"
            case .console: "Anthropic Console"
            case .apiKey: "API key"
            case .apiKeyHelper: "API key helper"
            case .oauthToken: "Long-lived OAuth token"
            case .thirdParty: "Third-party provider"
            case .none: "Not signed in"
            default: rawValue
            }
        }
    }

    /// Which service actually serves the requests.
    public struct APIProvider: RawRepresentable, Sendable, Equatable, Hashable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }

        public static let firstParty = Self("firstParty")
        public static let bedrock = Self("bedrock")
        public static let vertex = Self("vertex")
        public static let foundry = Self("foundry")
        public static let gateway = Self("gateway")

        public var displayName: String {
            switch self {
            case .firstParty: "Anthropic"
            case .bedrock: "Amazon Bedrock"
            case .vertex: "Google Cloud"
            case .foundry: "Microsoft Foundry"
            case .gateway: "Claude apps gateway"
            default: rawValue
            }
        }

        public var isFirstParty: Bool { self == .firstParty }
    }

    /// An organisation policy pinning which login method is allowed. The CLI
    /// resolves this from managed settings and reports it here — Overture
    /// never reads the managed-settings files itself.
    public enum ForcedLoginMethod: String, Sendable, Equatable {
        case claudeai, console, gateway
    }

    public var loggedIn: Bool
    public var authMethod: AuthMethod
    public var apiProvider: APIProvider
    public var forcedLoginMethod: ForcedLoginMethod?
    /// Where an API key came from, by NAME — e.g. `ANTHROPIC_API_KEY` or
    /// `apiKeyHelper`. The value is never read.
    public var apiKeySource: EnvVarName?
    public var email: String?
    /// Decoded so the shape is understood, but never displayed or logged: an
    /// opaque identifier with no user value and every reason to stay out of
    /// screenshots.
    public var orgID: String?
    public var orgName: String?
    public var subscriptionType: String?

    public init(loggedIn: Bool,
                authMethod: AuthMethod = .none,
                apiProvider: APIProvider = .firstParty,
                forcedLoginMethod: ForcedLoginMethod? = nil,
                apiKeySource: EnvVarName? = nil,
                email: String? = nil,
                orgID: String? = nil,
                orgName: String? = nil,
                subscriptionType: String? = nil) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.apiProvider = apiProvider
        self.forcedLoginMethod = forcedLoginMethod
        self.apiKeySource = apiKeySource
        self.email = email
        self.orgID = orgID
        self.orgName = orgName
        self.subscriptionType = subscriptionType
    }

    /// Returns nil only when the output is not JSON or carries no `loggedIn`.
    /// `{"loggedIn": false}` decodes successfully — that is how "signed out"
    /// stays distinguishable from "the probe broke".
    public init?(json: String) {
        guard let value = try? JSONDecoder().decode(
                JSONValue.self, from: Data(json.utf8)),
              let loggedIn = value["loggedIn"]?.boolValue else { return nil }
        self.init(
            loggedIn: loggedIn,
            authMethod: value["authMethod"]?.stringValue
                .map(AuthMethod.init(rawValue:)) ?? .none,
            apiProvider: value["apiProvider"]?.stringValue
                .map(APIProvider.init(rawValue:)) ?? .firstParty,
            forcedLoginMethod: value["forcedLoginMethod"]?.stringValue
                .flatMap(ForcedLoginMethod.init(rawValue:)),
            apiKeySource: value["apiKeySource"]?.stringValue
                .map(EnvVarName.init(rawValue:)),
            email: value["email"]?.stringValue,
            orgID: value["orgId"]?.stringValue,
            orgName: value["orgName"]?.stringValue,
            subscriptionType: value["subscriptionType"]?.stringValue)
    }

    /// True when a per-token bill is not what the user is paying. Note this
    /// is *not* sufficient to gate dollar UI on its own — an
    /// `ANTHROPIC_API_KEY` in the child environment overrides the
    /// subscription and makes dollars real again. See `CredentialPrecedence`.
    public var isSubscription: Bool { subscriptionType != nil }

    /// True when the CLI reported a login but no identity to go with it —
    /// the `oauth_token` case. The UI must not render this as a bare
    /// "signed in".
    public var isIdentityless: Bool { loggedIn && email == nil }

    /// Sign-in methods policy permits, so the UI can offer only what will
    /// actually work (Apple HIG: "Refer only to authentication methods that
    /// are available in the current context").
    ///
    /// Empty for `.gateway`: the CLI refuses `auth login` outright and
    /// directs the user to an interactive `/login`.
    public var permittedLoginModes: [AuthLogin.Mode] {
        switch forcedLoginMethod {
        case .claudeai: [.subscription]
        case .console: [.console]
        case .gateway: []
        case nil: AuthLogin.Mode.allCases
        }
    }

    /// One sentence explaining a policy restriction, for display next to the
    /// sign-in buttons. Nil when no policy applies.
    public var policyExplanation: String? {
        switch forcedLoginMethod {
        case .claudeai:
            "Your organization requires signing in with a Claude account."
        case .console:
            "Your organization requires signing in with an Anthropic Console account."
        case .gateway:
            "Your organization signs in through a Claude apps gateway. "
            + "Run `claude` in a terminal and use /login."
        case nil:
            nil
        }
    }
}
