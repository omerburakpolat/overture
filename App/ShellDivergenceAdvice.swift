import SwiftUI
import AppKit
import OvertureDesign
import ClaudeKit

/// What to do when the login shell sets variables Overture can't see.
///
/// Overture deliberately doesn't import the shell environment (that would put
/// your credentials in its memory). Instead it points at the place both
/// Terminal and Overture already read: the `env` block of
/// `~/.claude/settings.json`. It shows the snippet; it never writes the file.
struct ShellDivergenceAdvice: View {
    let names: [EnvVarName]

    private var suggestion: SettingsEnvSuggestion {
        SettingsEnvSuggestion(names: names)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s200) {
            Text("Your login shell sets \(names.map(\.rawValue).joined(separator: ", ")), which Overture can't see, so `claude` in Terminal and agents in Overture may behave differently.")
                .font(DS.TypeStyle.cardMeta)
                .foregroundStyle(DS.Color.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let snippet = suggestion.snippet {
                Text("Put these in `~/.claude/settings.json` instead, and both will read the same values:")
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Color.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: snippet)
                    .font(DS.TypeStyle.code)
                    .textSelection(.enabled)
                    .padding(DS.Space.s200)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Color.Surface.sunken,
                                in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                    .accessibilityLabel("Settings snippet")
                Button("Copy Snippet") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                }
            }

            if !suggestion.secrets.isEmpty {
                Label("Keep \(suggestion.secrets.map(\.rawValue).joined(separator: ", ")) out of that file — it's plain text. Sign in with `claude auth login`, or configure an apiKeyHelper, instead.",
                      systemImage: DS.Icon.key)
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Color.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if suggestion.configDirectory {
                Text("`CLAUDE_CONFIG_DIR` can't go in a settings file, because it decides where that file is. To give Overture the same one, run `launchctl setenv CLAUDE_CONFIG_DIR <path>` — it lasts until you log out — and relaunch Overture.")
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Color.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
