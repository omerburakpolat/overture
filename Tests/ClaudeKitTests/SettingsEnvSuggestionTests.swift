import Foundation
import Testing
@testable import ClaudeKit

@Suite struct SettingsEnvSuggestionTests {
    private func env(_ snippet: String?) throws -> [String: String] {
        let text = try #require(snippet)
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try #require((object as? [String: [String: String]])?["env"])
    }

    /// The snippet must be JSON a user can paste straight in, and each switch
    /// brings the variables its provider's setup page says it needs.
    @Test func bedrockBringsItsRegion() throws {
        let env = try env(SettingsEnvSuggestion(names: ["CLAUDE_CODE_USE_BEDROCK"]).snippet)
        #expect(env["CLAUDE_CODE_USE_BEDROCK"] == "1")
        #expect(env["AWS_REGION"] != nil)
    }

    @Test func vertexBringsItsRegionAndProject() throws {
        let env = try env(SettingsEnvSuggestion(names: ["CLAUDE_CODE_USE_VERTEX"]).snippet)
        #expect(env["CLAUDE_CODE_USE_VERTEX"] == "1")
        #expect(env["CLOUD_ML_REGION"] != nil)
        #expect(env["ANTHROPIC_VERTEX_PROJECT_ID"] != nil)
    }

    @Test func foundryBringsItsResource() throws {
        let env = try env(SettingsEnvSuggestion(names: ["CLAUDE_CODE_USE_FOUNDRY"]).snippet)
        #expect(env["ANTHROPIC_FOUNDRY_RESOURCE"] != nil)
    }

    @Test func sharedVariablesAppearOnce() throws {
        let snippet = try #require(SettingsEnvSuggestion(
            names: ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_MANTLE"]).snippet)
        #expect(snippet.components(separatedBy: "AWS_REGION").count == 2)
        _ = try env(snippet)
    }

    /// The file is plain text; a key or token must never be suggested for it.
    @Test func secretsAreNeverSuggestedForTheFile() throws {
        let suggestion = SettingsEnvSuggestion(names: [
            "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN",
            "ANTHROPIC_FOUNDRY_API_KEY", "CLAUDE_CODE_USE_VERTEX",
        ])
        #expect(suggestion.secrets == ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN",
                                       "ANTHROPIC_FOUNDRY_API_KEY"])
        let snippet = try #require(suggestion.snippet)
        #expect(!snippet.contains("API_KEY"))
        #expect(!snippet.contains("TOKEN"))
    }

    @Test func onlySecretsMeansNoSnippet() {
        let suggestion = SettingsEnvSuggestion(names: ["ANTHROPIC_API_KEY"])
        #expect(suggestion.snippet == nil)
        #expect(suggestion.secrets == ["ANTHROPIC_API_KEY"])
    }

    /// It decides where settings.json lives, so it can't be set from inside one.
    @Test func theConfigDirectoryIsHandledSeparately() {
        let suggestion = SettingsEnvSuggestion(names: ["CLAUDE_CONFIG_DIR"])
        #expect(suggestion.configDirectory)
        #expect(suggestion.snippet == nil)
    }

    /// Only names cross from the shell, so values are placeholders.
    @Test func valuesAreAlwaysPlaceholders() throws {
        let env = try env(SettingsEnvSuggestion(names: ["ANTHROPIC_BASE_URL"]).snippet)
        #expect(env["ANTHROPIC_BASE_URL"]?.hasPrefix("<") == true)
    }

    /// Every secret the snippet refuses is also a name the shell probe watches,
    /// so it is reported rather than silently ignored.
    @Test func everySecretNameIsWatched() {
        for name in SettingsEnvSuggestion.secretNames {
            #expect(ClaudeChildEnvironment.credentialRelevant.contains(name),
                    Comment(rawValue: "\(name) is not watched"))
        }
    }
}
