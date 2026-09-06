import Foundation
import Testing
@testable import ClaudeKit

@Suite struct RedactionTests {
    @Test(arguments: [
        "Login failed: key sk-ant-api03-abcdefghijklmnop was rejected",
        "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig",
        "env ANTHROPIC_API_KEY=sk-ant-abcdefghijklmnop",
        "visit https://claude.com/oauth?code=abcdef123456&state=xyz",
    ])
    func secretsAreMasked(line: String) {
        let scrubbed = Redaction.scrub(line)
        for secret in ["sk-ant-api03-abcdefghijklmnop", "eyJhbGciOiJIUzI1NiJ9",
                       "sk-ant-abcdefghijklmnop", "code=abcdef123456"] {
            #expect(!scrubbed.contains(secret))
        }
    }

    /// The variable NAME survives, because the name is exactly what Overture
    /// reports to the user; only the value goes.
    @Test func variableNamesSurviveWhileValuesAreMasked() {
        let scrubbed = Redaction.scrub("ANTHROPIC_API_KEY=sk-ant-abcdefghijkl")
        #expect(scrubbed.contains("ANTHROPIC_API_KEY"))
        #expect(!scrubbed.contains("sk-ant-abcdefghijkl"))
    }

    /// Scrubbing must not turn a diagnostic into noise — ordinary CLI output
    /// has to survive intact or relaying stderr is pointless.
    @Test func ordinaryDiagnosticsSurviveIntact() {
        let line = "Claude Code not found on PATH. Install with brew."
        #expect(Redaction.scrub(line) == line)
    }

    @Test func homeDirectoryIsAbbreviated() {
        let path = NSHomeDirectory() + "/.claude/projects"
        #expect(Redaction.abbreviatingHome(path) == "~/.claude/projects")
        #expect(Redaction.abbreviatingHome("/opt/homebrew/bin/claude")
                == "/opt/homebrew/bin/claude")
    }
}
