import Foundation
import ProcessCore

/// Builds `claude` invocations. The streaming recipe replicates
/// @anthropic-ai/claude-agent-sdk 0.3.251's spawn args (contract-of-record);
/// proven live in spikes/m0.
public enum ClaudeCLI {
    /// Permission posture of a session, per spec 01 §3.3 and resolution #10.
    public enum PermissionProfile: Sendable, Equatable {
        /// Interactive chat: Overture answers every un-allowlisted call.
        case askMe
        /// Plan column: read-only; writes and ExitPlanMode surface as
        /// `can_use_tool`.
        case plan
        /// Autonomous run: file edits auto-approved inside cwd; the rest
        /// surfaces. The project allowlist rides alongside.
        case autonomous
        /// Autonomous (full): everything except deny rules, ask rules, and
        /// critical deletes — which STILL surface. Opt-in per card.
        case fullAuto

        public var modeFlag: String {
            switch self {
            case .askMe: "default"      // "manual" is the CLI alias; init reports "default"
            case .plan: "plan"
            case .autonomous: "acceptEdits"
            case .fullAuto: "bypassPermissions"
            }
        }
    }

    public struct SessionSpec: Sendable {
        /// Session UUID. Minted by Overture on first runs (`--session-id`),
        /// so the transcript identity is known before the first byte.
        public var sessionID: UUID
        /// Resume instead of create.
        public var resume: Bool
        /// Fork on resume (new ID, copied history).
        public var fork: Bool
        public var profile: PermissionProfile
        public var model: String?
        public var effort: String?
        public var allowedTools: [String]
        public var disallowedTools: [String]
        public var maxBudgetUSD: Double?
        public var fallbackModel: String?
        /// Restrict the built-in tool set (`--tools`); nil = default set.
        public var tools: String?
        /// Empty string = ignore user/project settings (utility calls).
        public var settingSources: String?
        /// Skip every MCP server not explicitly configured — with none
        /// configured, no MCP at all. Product sessions leave this off
        /// (spec 01 §6); minimal-env/debug runs turn it on.
        public var strictMCPConfig: Bool

        public init(sessionID: UUID = UUID(),
                    resume: Bool = false,
                    fork: Bool = false,
                    profile: PermissionProfile,
                    model: String? = nil,
                    effort: String? = nil,
                    allowedTools: [String] = [],
                    disallowedTools: [String] = [],
                    maxBudgetUSD: Double? = nil,
                    fallbackModel: String? = nil,
                    tools: String? = nil,
                    settingSources: String? = nil,
                    strictMCPConfig: Bool = false) {
            self.sessionID = sessionID
            self.resume = resume
            self.fork = fork
            self.profile = profile
            self.model = model
            self.effort = effort
            self.allowedTools = allowedTools
            self.disallowedTools = disallowedTools
            self.maxBudgetUSD = maxBudgetUSD
            self.fallbackModel = fallbackModel
            self.tools = tools
            self.settingSources = settingSources
            self.strictMCPConfig = strictMCPConfig
        }
    }

    /// Streaming (persistent, bidirectional) invocation — one per live card
    /// session. Always includes the stdio permission prompt tool: even
    /// bypassPermissions routes ask-rules and critical deletes to the host.
    public static func streamingArguments(for spec: SessionSpec) -> [String] {
        var args = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--input-format", "stream-json",
            "--include-partial-messages",
            "--replay-user-messages",
            "--permission-prompt-tool", "stdio",
            "--permission-mode", spec.profile.modeFlag,
        ]
        if spec.resume {
            args += ["--resume", spec.sessionID.uuidString.lowercased()]
            if spec.fork { args.append("--fork-session") }
        } else {
            args += ["--session-id", spec.sessionID.uuidString.lowercased()]
        }
        if let model = spec.model { args += ["--model", model] }
        if let effort = spec.effort { args += ["--effort", effort] }
        if !spec.allowedTools.isEmpty {
            args += ["--allowedTools", spec.allowedTools.joined(separator: ",")]
        }
        if !spec.disallowedTools.isEmpty {
            args += ["--disallowedTools", spec.disallowedTools.joined(separator: ",")]
        }
        if let budget = spec.maxBudgetUSD {
            args += ["--max-budget-usd", String(budget)]
        }
        if let fallback = spec.fallbackModel {
            args += ["--fallback-model", fallback]
        }
        if let tools = spec.tools { args += ["--tools", tools] }
        if let sources = spec.settingSources {
            args += ["--setting-sources", sources]
        }
        if spec.strictMCPConfig {
            args.append("--strict-mcp-config")
        }
        return args
    }

    /// One-shot ticket-draft recipe (resolution #19): stateless, read-only,
    /// structured output, no settings, no transcript.
    public static func ticketDraftArguments(schema: String,
                                            model: String? = nil,
                                            maxBudgetUSD: Double = 0.5) -> [String] {
        var args = [
            "-p",
            "--output-format", "json",
            "--json-schema", schema,
            "--tools", "Read,Glob,Grep",
            "--no-session-persistence",
            "--setting-sources", "",
            "--max-budget-usd", String(maxBudgetUSD),
        ]
        if let model { args += ["--model", model] }
        return args
    }

    /// Env prefixes stripped from every claude child (M0 finding #10:
    /// nested-session context must not leak).
    public static let strippedEnvPrefixes = ["CLAUDE"]
}
