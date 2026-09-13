import Foundation

/// What to tell someone whose login shell sets variables Overture can't see.
///
/// Claude Code reads the `env` block of `~/.claude/settings.json` on every run
/// — however `claude` was launched, and ahead of the shell (measured: docs/
/// specs/06-m0-findings.md, M1 item 17; code.claude.com/docs/en/env-vars).
/// Moving a *non-secret* switch there makes Terminal and Overture agree without
/// Overture ever holding a value, which importing the shell would require.
///
/// Secrets stay out: that file is plain text. And Overture only shows the
/// instructions — it never writes the file (CLAUDE.md: never write to
/// `~/.claude`).
public struct SettingsEnvSuggestion: Sendable, Equatable {
    /// Switches and identifiers that belong in the settings `env` block.
    public var movable: [EnvVarName]
    /// Credentials, which belong behind `claude auth login` or an
    /// `apiKeyHelper` — never in a plain-text file.
    public var secrets: [EnvVarName]
    /// `CLAUDE_CONFIG_DIR` decides where `settings.json` lives, so it can't be
    /// set from inside one.
    public var configDirectory: Bool

    public static let secretNames: Set<EnvVarName> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
        "ANTHROPIC_FOUNDRY_API_KEY", "ANTHROPIC_FOUNDRY_AUTH_TOKEN",
    ]

    public init(names: [EnvVarName]) {
        movable = names.filter {
            !Self.secretNames.contains($0) && $0 != "CLAUDE_CONFIG_DIR"
        }
        secrets = names.filter { Self.secretNames.contains($0) }
        configDirectory = names.contains("CLAUDE_CONFIG_DIR")
    }

    /// A JSON snippet to merge into `~/.claude/settings.json`, or nil when
    /// nothing movable was found.
    ///
    /// Values are placeholders except for the on/off switches: Overture never
    /// learned the real ones, by design — only names cross from the shell.
    /// Each provider switch brings the variables its setup page says it needs
    /// (Bedrock and Mantle: `AWS_REGION`; Vertex: `CLOUD_ML_REGION` and
    /// `ANTHROPIC_VERTEX_PROJECT_ID`; Foundry: `ANTHROPIC_FOUNDRY_RESOURCE`).
    public var snippet: String? {
        guard !movable.isEmpty else { return nil }
        var entries: [(key: String, value: String)] = []
        func add(_ key: String, _ value: String) {
            if !entries.contains(where: { $0.key == key }) {
                entries.append((key, value))
            }
        }
        for name in movable {
            switch name.rawValue {
            case "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_MANTLE":
                add(name.rawValue, "1")
                add("AWS_REGION", "<your AWS region>")
            case "CLAUDE_CODE_USE_VERTEX":
                add(name.rawValue, "1")
                add("CLOUD_ML_REGION", "<your region>")
                add("ANTHROPIC_VERTEX_PROJECT_ID", "<your project ID>")
            case "CLAUDE_CODE_USE_FOUNDRY":
                add(name.rawValue, "1")
                add("ANTHROPIC_FOUNDRY_RESOURCE", "<your resource name>")
            default:
                add(name.rawValue, "<value from your shell profile>")
            }
        }
        let body = entries
            .map { "    \"\($0.key)\": \"\($0.value)\"" }
            .joined(separator: ",\n")
        return "{\n  \"env\": {\n\(body)\n  }\n}"
    }
}
