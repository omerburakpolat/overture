import Foundation
import Testing
@testable import ClaudeKit

/// Regression suite for the `strippedEnvPrefixes = ["CLAUDE"]` defect: a
/// prefix sweep meant to drop nested-session markers also dropped the config
/// dir, the cloud-provider switches and the OAuth token, breaking those users
/// and desynchronising the transcript reader from the CLI's writer.
@Suite struct ChildEnvironmentTests {
    /// Every variable Claude Code sets for its own children is removed, so a
    /// nested session never inherits our session identity (M0 finding #10).
    @Test func nestedSessionMarkersAreStripped() {
        let base = Dictionary(
            uniqueKeysWithValues: ClaudeChildEnvironment.nestedSessionMarkers
                .map { ($0.rawValue, "leak") })
        let environment = ClaudeChildEnvironment.make(base: base)
        #expect(environment.isEmpty)
    }

    @Test(arguments: [
        "CLAUDE_CONFIG_DIR",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
    ])
    func credentialRelevantVariablesSurvive(name: String) {
        let environment = ClaudeChildEnvironment.make(base: [name: "value"])
        #expect(environment[name] == "value")
    }

    /// The point of the fix: an exact name set, not a prefix. `CLAUDECODE`
    /// goes, `CLAUDE_CONFIG_DIR` stays — a prefix sweep cannot do both.
    @Test func strippingIsByExactNameNotPrefix() {
        let environment = ClaudeChildEnvironment.make(base: [
            "CLAUDECODE": "1",
            "CLAUDE_CONFIG_DIR": "/tmp/overture-config",
        ])
        #expect(environment["CLAUDECODE"] == nil)
        #expect(environment["CLAUDE_CONFIG_DIR"] == "/tmp/overture-config")
    }

    /// Overture's transcript reader and the CLI it spawns must agree on where
    /// the config directory is. Before the fix the child never saw
    /// `CLAUDE_CONFIG_DIR`, so the CLI wrote transcripts (and read
    /// credentials) somewhere Overture never looked.
    @Test func transcriptReaderAgreesWithTheChildEnvironment() {
        let childEnvironment = ClaudeChildEnvironment.make(
            base: ["CLAUDE_CONFIG_DIR": "/tmp/overture-config"])
        let root = TranscriptStore.configRoot(environment: childEnvironment)
        #expect(root.path == "/tmp/overture-config")
    }

    @Test func spawnMarkersAreApplied() {
        let environment = ClaudeChildEnvironment.make(
            base: ["PATH": "/usr/bin"],
            markers: ["OVERTURE": "1", "OVERTURE_CARD_ID": "abc"])
        #expect(environment["OVERTURE"] == "1")
        #expect(environment["OVERTURE_CARD_ID"] == "abc")
        #expect(environment["PATH"] == "/usr/bin")
    }

    /// Markers win over an inherited value of the same name, so a stale
    /// marker in the app's own environment can never mislabel a card.
    @Test func markersOverrideInheritedValues() {
        let environment = ClaudeChildEnvironment.make(
            base: ["OVERTURE_CARD_ID": "stale"],
            markers: ["OVERTURE_CARD_ID": "fresh"])
        #expect(environment["OVERTURE_CARD_ID"] == "fresh")
    }

    @Test func credentialVariablesPresentReportsNamesOnly() {
        let names = ClaudeChildEnvironment.credentialVariablesPresent(in: [
            "ANTHROPIC_API_KEY": "sk-ant-CANARY",
            "PATH": "/usr/bin",
        ])
        #expect(names == ["ANTHROPIC_API_KEY"])
        // The whole point of `EnvVarName`: a value can never ride along.
        #expect(!String(describing: names).contains("CANARY"))
    }

    /// An empty value is not a credential — an exported-but-blank variable
    /// must not raise a false "your agents will use this" warning.
    @Test func emptyCredentialVariablesAreNotReported() {
        let names = ClaudeChildEnvironment.credentialVariablesPresent(
            in: ["ANTHROPIC_API_KEY": ""])
        #expect(names.isEmpty)
    }
}
