import Foundation
import ProcessCore

/// First-run checks (resolution #12): binary → version → auth. Each step
/// degrades to a specific, actionable failure — never a generic error.
public enum OnboardingCheck {
    /// Minimum CLI version the protocol layer is tested against (M0 ran
    /// against 2.1.231). Newer versions warn, never block (spec 01 §7.1).
    public static let minimumTestedVersion = SemanticVersion(2, 1, 231)

    public enum Outcome: Sendable, Equatable {
        case binaryMissing(searched: [String])
        case versionUnreadable(output: String)
        case versionBelowMinimum(found: SemanticVersion)
        case notAuthenticated
        case ready(Readiness)
    }

    public struct Readiness: Sendable, Equatable {
        public var claudeURL: URL
        public var version: SemanticVersion
        /// Newer than tested — surface a soft warning, keep going.
        public var versionUntested: Bool
        public var auth: AuthStatus
    }

    public static func run(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> Outcome {
        // 1. Binary discovery: well-known paths, then login-shell PATH.
        var searched = HostEnvironment.claudeCandidatePaths
        var found = searched.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }.map(URL.init(fileURLWithPath:))
        if found == nil, let path = await HostEnvironment.loginShellPATH() {
            searched.append("$PATH")
            found = HostEnvironment.find(executable: "claude", path: path)
        }
        guard let claudeURL = found else {
            return .binaryMissing(searched: searched)
        }

        // 2. Version gate.
        guard let versionOutput = await capture(claudeURL, ["--version"]) else {
            return .versionUnreadable(output: "")
        }
        guard let version = SemanticVersion(parsing: versionOutput) else {
            return .versionUnreadable(output: versionOutput)
        }
        if version < minimumTestedVersion {
            return .versionBelowMinimum(found: version)
        }

        // 3. Auth probe (`claude auth status` outputs JSON by default).
        guard let authOutput = await capture(claudeURL, ["auth", "status", "--json"]),
              let auth = AuthStatus(json: authOutput), auth.loggedIn else {
            return .notAuthenticated
        }
        return .ready(.init(claudeURL: claudeURL,
                            version: version,
                            versionUntested: minimumTestedVersion < version,
                            auth: auth))
    }

    private static func capture(_ executable: URL,
                                _ arguments: [String]) async -> String? {
        let subprocess = Subprocess(configuration: .init(
            executable: executable, arguments: arguments,
            strippedEnvPrefixes: ClaudeCLI.strippedEnvPrefixes))
        guard let lines = try? await subprocess.start() else { return nil }
        var collected: [String] = []
        for await line in lines { collected.append(line) }
        guard case .exited(code: 0) = await subprocess.waitForExit() else {
            return nil
        }
        return collected.joined(separator: "\n")
    }
}

/// Decoded `claude auth status --json`. `subscriptionType` non-nil means
/// subscription billing — cost UI shows tokens first, dollars as estimates
/// (resolution #13).
public struct AuthStatus: Sendable, Equatable {
    public var loggedIn: Bool
    public var authMethod: String?     // "claude.ai" | "console" | …
    public var email: String?
    public var subscriptionType: String?  // "max" | "pro" | nil (API key)

    public var isSubscription: Bool { subscriptionType != nil }

    public init?(json: String) {
        guard let value = try? JSONDecoder().decode(
            JSONValue.self, from: Data(json.utf8)),
              let loggedIn = value["loggedIn"]?.boolValue else { return nil }
        self.loggedIn = loggedIn
        authMethod = value["authMethod"]?.stringValue
        email = value["email"]?.stringValue
        subscriptionType = value["subscriptionType"]?.stringValue
    }

    public init(loggedIn: Bool, authMethod: String? = nil,
                email: String? = nil, subscriptionType: String? = nil) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.email = email
        self.subscriptionType = subscriptionType
    }
}

public struct SemanticVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Accepts "2.1.231 (Claude Code)" and bare "2.1.231".
    public init?(parsing string: String) {
        let pattern = /(\d+)\.(\d+)\.(\d+)/
        guard let match = string.firstMatch(of: pattern),
              let major = Int(match.1), let minor = Int(match.2),
              let patch = Int(match.3) else { return nil }
        self.init(major, minor, patch)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}
