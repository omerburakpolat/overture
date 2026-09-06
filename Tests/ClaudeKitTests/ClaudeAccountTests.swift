import Foundation
import Testing
@testable import ClaudeKit

/// All fixtures here are synthetic. `CLAUDE.md` records that the recorded
/// session fixtures once carried a real account email; auth fixtures are
/// hand-written so that can't recur.
@Suite struct ClaudeAccountTests {
    /// The full shape measured on CLI v2.1.236.
    @Test func decodesTheFullSignedInShape() {
        let account = ClaudeAccount(json: """
        {"loggedIn": true, "authMethod": "claude.ai",
         "apiProvider": "firstParty", "email": "user@example.com",
         "orgId": "00000000-0000-0000-0000-000000000000",
         "orgName": "Example Org", "subscriptionType": "max"}
        """)
        #expect(account?.loggedIn == true)
        #expect(account?.authMethod == .claudeAI)
        #expect(account?.apiProvider == .firstParty)
        #expect(account?.email == "user@example.com")
        #expect(account?.orgName == "Example Org")
        #expect(account?.subscriptionType == "max")
        #expect(account?.isSubscription == true)
        #expect(account?.isIdentityless == false)
    }

    /// A `CLAUDE_CODE_OAUTH_TOKEN` session: logged in, but the CLI reports no
    /// identity at all. The UI must not render this as a bare "signed in".
    @Test func decodesTheIdentitylessOAuthTokenShape() {
        let account = ClaudeAccount(json: """
        {"loggedIn": true, "authMethod": "oauth_token",
         "apiProvider": "firstParty"}
        """)
        #expect(account?.loggedIn == true)
        #expect(account?.authMethod == .oauthToken)
        #expect(account?.email == nil)
        #expect(account?.isIdentityless == true)
        #expect(account?.isSubscription == false)
    }

    /// `apiKeySource` is how the CLI reveals an API-key override.
    @Test func decodesTheAPIKeySourceField() {
        let account = ClaudeAccount(json: """
        {"loggedIn": true, "authMethod": "claude.ai",
         "apiProvider": "firstParty", "apiKeySource": "ANTHROPIC_API_KEY",
         "email": "user@example.com", "subscriptionType": "max"}
        """)
        #expect(account?.apiKeySource == "ANTHROPIC_API_KEY")
    }

    @Test func decodesTheCloudProviderShape() {
        let account = ClaudeAccount(json: """
        {"loggedIn": true, "authMethod": "third_party", "apiProvider": "bedrock"}
        """)
        #expect(account?.apiProvider == .bedrock)
        #expect(account?.apiProvider.isFirstParty == false)
        #expect(account?.apiProvider.displayName == "Amazon Bedrock")
    }

    /// The CLI's vocabulary is not a documented contract. An unknown value
    /// must round-trip for display, never make decoding fail.
    @Test func unknownEnumeratedValuesRoundTripInsteadOfFailing() {
        let account = ClaudeAccount(json: """
        {"loggedIn": true, "authMethod": "quantum_sso", "apiProvider": "moonbase"}
        """)
        #expect(account != nil)
        #expect(account?.authMethod.rawValue == "quantum_sso")
        #expect(account?.authMethod.displayName == "quantum_sso")
        #expect(account?.apiProvider.displayName == "moonbase")
    }

    @Test func unknownExtraKeysAreIgnored() {
        let account = ClaudeAccount(json: """
        {"loggedIn": true, "authMethod": "claude.ai", "somethingNew": {"a": 1}}
        """)
        #expect(account?.loggedIn == true)
    }

    /// The distinction the whole `AuthState` model rests on: "signed out" is
    /// a successful decode, not a failure.
    @Test func loggedOutDecodesSuccessfully() {
        let account = ClaudeAccount(json: #"{"loggedIn": false}"#)
        #expect(account != nil)
        #expect(account?.loggedIn == false)
    }

    @Test func malformedOutputDecodesToNil() {
        #expect(ClaudeAccount(json: "not json") == nil)
        #expect(ClaudeAccount(json: "{}") == nil)          // no `loggedIn`
        #expect(ClaudeAccount(json: "") == nil)
    }

    @Test func policyRestrictsTheOfferedLoginMethods() {
        func account(_ policy: String) -> ClaudeAccount? {
            ClaudeAccount(json: """
            {"loggedIn": false, "forcedLoginMethod": "\(policy)"}
            """)
        }
        #expect(account("claudeai")?.permittedLoginModes == [.subscription])
        #expect(account("console")?.permittedLoginModes == [.console])
        // The CLI refuses `auth login` outright under a gateway policy.
        #expect(account("gateway")?.permittedLoginModes.isEmpty == true)
        #expect(account("gateway")?.policyExplanation != nil)
    }

    @Test func noPolicyOffersEveryMethod() {
        let account = ClaudeAccount(json: #"{"loggedIn": false}"#)
        #expect(account?.permittedLoginModes.count == AuthLogin.Mode.allCases.count)
        #expect(account?.policyExplanation == nil)
    }

    /// An unrecognised policy value must not silently become "no policy" and
    /// re-enable every button.
    @Test func unknownPolicyValueIsNotTreatedAsPermissive() {
        let account = ClaudeAccount(json: """
        {"loggedIn": false, "forcedLoginMethod": "future_method"}
        """)
        #expect(account?.forcedLoginMethod == nil)
    }
}
