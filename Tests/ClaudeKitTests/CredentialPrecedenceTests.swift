import Foundation
import Testing
@testable import ClaudeKit

@Suite struct CredentialPrecedenceTests {
    private func signedIn(
        method: ClaudeAccount.AuthMethod = .claudeAI,
        provider: ClaudeAccount.APIProvider = .firstParty,
        apiKeySource: EnvVarName? = nil
    ) -> ClaudeAccount {
        ClaudeAccount(loggedIn: true, authMethod: method, apiProvider: provider,
                      apiKeySource: apiKeySource, email: "user@example.com",
                      orgName: "Example Org", subscriptionType: "max")
    }

    /// Level 1. The CLI already reports `third_party`, so nothing the user
    /// sees is contradicted — it is not an override.
    @Test func cloudProviderWinsAndIsNotAnOverride() {
        let resolution = CredentialPrecedence.resolve(
            account: ClaudeAccount(loggedIn: true, authMethod: .thirdParty,
                                   apiProvider: .bedrock),
            childEnvironment: ["CLAUDE_CODE_USE_BEDROCK": "1"])
        #expect(resolution.level == 1)
        #expect(resolution.source == .cloudProvider(.bedrock))
        #expect(resolution.evidence == ["CLAUDE_CODE_USE_BEDROCK"])
        #expect(resolution.overridesReportedLogin == false)
        #expect(resolution.confidence == .reportedByCLI)
    }

    /// Level 2, the measured blind spot: `auth status` still reports
    /// `claude.ai`, so this can only be inferred from the variable's presence.
    @Test func authTokenIsInferredBecauseTheCLIDoesNotReportIt() {
        let resolution = CredentialPrecedence.resolve(
            account: signedIn(),
            childEnvironment: ["ANTHROPIC_AUTH_TOKEN": "secret"])
        #expect(resolution.level == 2)
        #expect(resolution.confidence == .inferredFromEnvironment)
        #expect(resolution.overridesReportedLogin == true)
    }

    /// Level 3 — the case that costs money silently. Overture spawns every
    /// session headless, where an API key is always preferred.
    @Test func apiKeyOverridesASubscriptionLogin() {
        let resolution = CredentialPrecedence.resolve(
            account: signedIn(apiKeySource: "ANTHROPIC_API_KEY"),
            childEnvironment: ["ANTHROPIC_API_KEY": "sk-ant-CANARY"])
        #expect(resolution.level == 3)
        #expect(resolution.source == .apiKeyEnvironment)
        #expect(resolution.overridesReportedLogin == true)
        #expect(resolution.confidence == .reportedByCLI)
        #expect(resolution.explanation.contains("headless"))
    }

    /// An API key with no subscription behind it is simply the credential —
    /// there is nothing to override, so no caution is warranted.
    @Test func apiKeyWithoutASubscriptionIsNotAnOverride() {
        let resolution = CredentialPrecedence.resolve(
            account: ClaudeAccount(loggedIn: true, authMethod: .apiKey,
                                   apiKeySource: "ANTHROPIC_API_KEY"),
            childEnvironment: ["ANTHROPIC_API_KEY": "sk-ant-CANARY"])
        #expect(resolution.level == 3)
        #expect(resolution.overridesReportedLogin == false)
    }

    @Test func apiKeyHelperIsReportedAndNeverRun() {
        let resolution = CredentialPrecedence.resolve(
            account: signedIn(apiKeySource: "apiKeyHelper"),
            childEnvironment: [:])
        #expect(resolution.level == 4)
        #expect(resolution.explanation.contains("never runs it"))
    }

    /// Level 5. Identity is unavailable rather than contradicted, so this is
    /// not flagged as an override.
    @Test func oauthTokenIsReportedAndNotAnOverride() {
        let resolution = CredentialPrecedence.resolve(
            account: ClaudeAccount(loggedIn: true, authMethod: .oauthToken),
            childEnvironment: ["CLAUDE_CODE_OAUTH_TOKEN": "token"])
        #expect(resolution.level == 5)
        #expect(resolution.overridesReportedLogin == false)
    }

    @Test func profileCredentialsAreDetected() {
        let resolution = CredentialPrecedence.resolve(
            account: signedIn(),
            childEnvironment: ["ANTHROPIC_PROFILE": "work"])
        #expect(resolution.level == 6)
        #expect(resolution.evidence == ["ANTHROPIC_PROFILE"])
    }

    /// Level 7, the ordinary case: a clean environment and a stored login.
    @Test func aCleanEnvironmentUsesTheStoredLogin() {
        let resolution = CredentialPrecedence.resolve(
            account: signedIn(), childEnvironment: ["PATH": "/usr/bin"])
        #expect(resolution.level == 7)
        #expect(resolution.source == .storedLogin)
        #expect(resolution.overridesReportedLogin == false)
        #expect(resolution.evidence.isEmpty)
    }

    @Test func signedOutResolvesToNoCredential() {
        let resolution = CredentialPrecedence.resolve(
            account: ClaudeAccount(loggedIn: false), childEnvironment: [:])
        #expect(resolution.source == .none)
    }

    /// An exported-but-blank variable is not a credential and must not raise
    /// a false "your agents will use this" warning.
    @Test func emptyVariablesDoNotCount() {
        let resolution = CredentialPrecedence.resolve(
            account: signedIn(), childEnvironment: ["ANTHROPIC_API_KEY": ""])
        #expect(resolution.level == 7)
    }

    /// The invariant `SECURITY.md` rests on: the resolver reasons about
    /// names, so a value can never reach a string the UI or a log will see.
    @Test func credentialValuesNeverAppearInTheResolution() {
        let canary = "sk-ant-CANARY-abcdefghijklmnop"
        for environment in [
            ["ANTHROPIC_API_KEY": canary],
            ["ANTHROPIC_AUTH_TOKEN": canary],
            ["CLAUDE_CODE_OAUTH_TOKEN": canary],
            ["ANTHROPIC_PROFILE": canary],
            ["CLAUDE_CODE_USE_BEDROCK": canary],
        ] {
            let resolution = CredentialPrecedence.resolve(
                account: signedIn(), childEnvironment: environment)
            #expect(!String(describing: resolution).contains("CANARY"),
                    "value leaked for \(environment.keys.first ?? "?")")
            #expect(!resolution.explanation.contains("CANARY"))
        }
    }
}
