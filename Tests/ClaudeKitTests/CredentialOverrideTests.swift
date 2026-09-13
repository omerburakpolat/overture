import Foundation
import Testing
@testable import ClaudeKit

@Suite struct StoredLoginOverrideTests {
    private let maxLogin = ClaudeAccount(loggedIn: true, authMethod: .claudeAI,
                                         email: "user@example.com",
                                         subscriptionType: "max")
    private let nobody = ClaudeAccount(loggedIn: false)

    @Test func anAuthTokenBypassingAStoredLoginIsAnOverride() {
        let resolution = CredentialPrecedence.resolve(
            account: maxLogin, childEnvironment: ["ANTHROPIC_AUTH_TOKEN": "t"],
            storedLogin: maxLogin)
        #expect(resolution.level == 2)
        #expect(resolution.overridesReportedLogin)
    }

    @Test func anAuthTokenWithNoLoginUnderneathIsNotAnOverride() {
        let resolution = CredentialPrecedence.resolve(
            account: maxLogin, childEnvironment: ["ANTHROPIC_AUTH_TOKEN": "t"],
            storedLogin: nobody)
        #expect(resolution.level == 2)
        #expect(resolution.overridesReportedLogin == false)
    }

    /// The shape measured in a clean environment: `api_key`, not `claude.ai`.
    @Test func theAPIKeyShapeWithALoginUnderneathIsAnOverride() {
        let resolution = CredentialPrecedence.resolve(
            account: ClaudeAccount(loggedIn: true, authMethod: .apiKey,
                                   apiKeySource: "ANTHROPIC_API_KEY"),
            childEnvironment: ["ANTHROPIC_API_KEY": "k"],
            storedLogin: maxLogin)
        #expect(resolution.level == 3)
        #expect(resolution.overridesReportedLogin)
        #expect(resolution.explanation.contains("headless"))
    }

    @Test func aLongLivedTokenBypassingAStoredLoginIsAnOverride() {
        let resolution = CredentialPrecedence.resolve(
            account: ClaudeAccount(loggedIn: true, authMethod: .oauthToken),
            childEnvironment: ["CLAUDE_CODE_OAUTH_TOKEN": "t"],
            storedLogin: maxLogin)
        #expect(resolution.level == 5)
        #expect(resolution.overridesReportedLogin)
    }

    /// The stored login's identity is for Settings to render, never for a
    /// sentence that might end up in a diagnostic.
    @Test func theStoredLoginsIdentityStaysOutOfTheExplanation() {
        for environment in [["ANTHROPIC_AUTH_TOKEN": "t"], ["ANTHROPIC_API_KEY": "k"],
                            ["CLAUDE_CODE_OAUTH_TOKEN": "t"], ["ANTHROPIC_PROFILE": "p"]] {
            let resolution = CredentialPrecedence.resolve(
                account: ClaudeAccount(loggedIn: true, authMethod: .apiKey),
                childEnvironment: environment, storedLogin: maxLogin)
            #expect(!resolution.explanation.contains("user@example.com"))
        }
    }
}

@Suite struct CredentialOverrideNamesTests {
    @Test func removingOverridesKeepsProviderSwitchesAndTheConfigDirectory() {
        let environment = ClaudeChildEnvironment.removingCredentialOverrides(from: [
            "ANTHROPIC_API_KEY": "k", "ANTHROPIC_AUTH_TOKEN": "t",
            "CLAUDE_CODE_OAUTH_TOKEN": "o", "ANTHROPIC_PROFILE": "p",
            "ANTHROPIC_FEDERATION_RULE_ID": "r", "ANTHROPIC_ORGANIZATION_ID": "g",
            "CLAUDE_CONFIG_DIR": "/tmp/c", "CLAUDE_CODE_USE_BEDROCK": "1",
            "ANTHROPIC_BASE_URL": "https://example.com", "PATH": "/usr/bin",
        ])
        #expect(Set(environment.keys) == ["CLAUDE_CONFIG_DIR", "CLAUDE_CODE_USE_BEDROCK",
                                          "ANTHROPIC_BASE_URL", "PATH"])
    }
}
