import Foundation
import Testing
@testable import ClaudeKit

/// Parsing is a pure function over the CLI's stdout, so it is tested without
/// spawning anything. The sample lines below are the *actual bytes* observed
/// from `claude auth login --claudeai` v2.1.236 running over pipes with no
/// TTY, captured in a scratch `CLAUDE_CONFIG_DIR`.
@Suite struct AuthLoginParsingTests {
    private static let realURLLine = "If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile&code_challenge=bOqvRrHr&code_challenge_method=S256&state=LDK9G"

    @Test func recognisesTheBrowserOpeningLine() {
        #expect(AuthLogin.events(forStdout: "Opening browser to sign in\u{2026}")
                == [.opening])
    }

    /// The whole reason `.awaitingCode` rides along with the URL: the CLI's
    /// own "Paste code here if prompted > " prompt has no trailing newline,
    /// so it never arrives as a line and cannot be waited for.
    @Test func theURLLineAlsoSignalsThatACodeCanBePasted() throws {
        let events = AuthLogin.events(forStdout: Self.realURLLine)
        #expect(events.count == 2)
        guard case .authorizationURL(let url) = events.first else {
            Issue.record("expected .authorizationURL, got \(events)")
            return
        }
        #expect(url.host == "claude.com")
        #expect(events.last == .awaitingCode)
    }

    /// A tampered CLI must not be able to turn Overture into a one-click
    /// phishing launcher.
    @Test(arguments: [
        "If the browser didn't open, visit: https://evil.example.com/oauth",
        "If the browser didn't open, visit: http://claude.com/oauth",
        "visit: https://claude.com.attacker.net/oauth",
    ])
    func urlsOutsideTheAllowlistAreInertText(line: String) {
        let events = AuthLogin.events(forStdout: line)
        for event in events {
            if case .authorizationURL = event {
                Issue.record("accepted a URL it should not have: \(line)")
            }
        }
    }

    @Test func recognisesSuccess() {
        #expect(AuthLogin.events(forStdout: "Login successful.") == [.succeeded])
    }

    @Test func blankLinesProduceNothing() {
        #expect(AuthLogin.events(forStdout: "   ").isEmpty)
    }

    /// Login failures arrive only on stderr — which is why `Subprocess` grew
    /// an opt-in stderr stream. Without it a failed sign-in is a blank box.
    @Test func stderrCarriesTheFailureModes() {
        #expect(AuthLogin.event(forStderr:
            "Invalid code. Please make sure the full code was copied.")
            == .invalidCode("Invalid code. Please make sure the full code was copied."))
        guard case .failed(let text)? = AuthLogin.event(
            forStderr: "Login failed: something went wrong") else {
            Issue.record("expected .failed")
            return
        }
        #expect(text.contains("Login failed"))
        #expect(AuthLogin.event(forStderr: "  ") == nil)
    }

    /// Relayed output is scrubbed on the way in, so a secret the CLI happened
    /// to echo never reaches a type the UI renders.
    @Test func relayedOutputIsScrubbed() {
        let events = AuthLogin.events(
            forStdout: "note: ANTHROPIC_API_KEY=sk-ant-CANARYabcdefgh")
        #expect(!String(describing: events).contains("CANARY"))
        let failure = AuthLogin.event(
            forStderr: "Login failed: token sk-ant-CANARYabcdefgh rejected")
        #expect(!String(describing: failure).contains("CANARY"))
    }

    /// Each mode passes exactly one flag — the CLI rejects both together, so
    /// the type makes that unrepresentable.
    @Test func eachModeHasOneFlagAndNamesItself() {
        #expect(AuthLogin.Mode.subscription.flag == "--claudeai")
        #expect(AuthLogin.Mode.console.flag == "--console")
        for mode in AuthLogin.Mode.allCases {
            // Apple HIG: identify the method, never a generic "Sign In".
            #expect(mode.buttonTitle != "Sign In")
            #expect(mode.buttonTitle.hasPrefix("Sign In with"))
        }
    }
}
