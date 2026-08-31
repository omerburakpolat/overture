import Foundation
import Testing
@testable import ClaudeKit

@Suite struct OnboardingParsingTests {
    @Test func versionParsesRealOutput() {
        #expect(SemanticVersion(parsing: "2.1.231 (Claude Code)")
                == SemanticVersion(2, 1, 231))
        #expect(SemanticVersion(parsing: "garbage") == nil)
        #expect(SemanticVersion(2, 1, 231) < SemanticVersion(2, 1, 246))
        #expect(SemanticVersion(2, 1, 231) < SemanticVersion(2, 2, 0))
        #expect(SemanticVersion(2, 9, 9) < SemanticVersion(3, 0, 0))
    }

    @Test func authStatusDecodesSubscription() {
        let auth = AuthStatus(json: """
        {"loggedIn": true, "authMethod": "claude.ai",
         "email": "user@example.com", "subscriptionType": "max"}
        """)
        #expect(auth?.loggedIn == true)
        #expect(auth?.isSubscription == true)
        #expect(auth?.email == "user@example.com")
    }

    @Test func authStatusAPIKeyHasNoSubscription() {
        let auth = AuthStatus(json: #"{"loggedIn": true}"#)
        #expect(auth?.isSubscription == false)
    }

    @Test func malformedAuthJSONIsNil() {
        #expect(AuthStatus(json: "not json") == nil)
        #expect(AuthStatus(json: "{}") == nil) // no loggedIn field
    }
}

/// Live: runs the real discovery + auth probe on this machine.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OVERTURE_LIVE_TESTS"] == "1"))
struct LiveOnboardingTests {
    @Test func fullProbeReachesReady() async {
        let outcome = await OnboardingCheck.run()
        guard case .ready(let readiness) = outcome else {
            Issue.record("expected .ready on the dev machine, got \(outcome)")
            return
        }
        #expect(readiness.auth.loggedIn)
        #expect(readiness.version >= OnboardingCheck.minimumTestedVersion)
    }
}
