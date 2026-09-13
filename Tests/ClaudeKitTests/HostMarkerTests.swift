import Foundation
import Testing
@testable import ClaudeKit

/// A Claude Code host (the desktop app, the Agent SDK) sets these for the CLI
/// it embeds. If Overture is launched from inside such a session they must not
/// reach an agent — they claim a host is refreshing its login or managing its
/// provider when none is.
@Suite struct HostMarkerTests {
    @Test(arguments: [
        "CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH", "CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH",
        "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST", "CLAUDE_CODE_DESKTOP_APP_VERSION",
        "CLAUDE_CODE_EAGER_FLUSH", "CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES",
        "CLAUDE_CODE_ENABLE_ASK_USER_QUESTION_TOOL",
        "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING", "CLAUDE_CODE_REPORT_FINDINGS",
        "CLAUDE_PREVIEW_CLASSIFIER_FLOOR",
    ])
    func hostVariablesAreStripped(name: String) {
        #expect(ClaudeChildEnvironment.make(base: [name: "1"])[name] == nil)
    }

    /// Documented user settings that a host also happens to set survive:
    /// stripping them would silently undo a choice the user made.
    @Test(arguments: ["CLAUDE_CODE_DISABLE_CRON", "CLAUDE_CODE_DISABLE_TERMINAL_TITLE",
                      "CLAUDE_CODE_OAUTH_SCOPES", "ANTHROPIC_BASE_URL"])
    func documentedUserSettingsSurvive(name: String) {
        #expect(ClaudeChildEnvironment.make(base: [name: "1"])[name] == "1")
    }
}
