import Foundation

/// Scrubs secrets out of text that came from a `claude` child before it can
/// reach a UI string, a log line, or a diagnostics blob.
///
/// `SECURITY.md` promises Overture never transmits or stores your
/// credentials. Overture does not *look* for credentials — but it does relay
/// the CLI's stderr so a failed sign-in isn't a blank box, and stderr is
/// exactly where a badly-behaved tool would echo one. Scrubbing at the point
/// of construction means an unscrubbed value never exists inside a type the
/// UI can reach.
public enum Redaction {
    public static let mask = "[redacted]"

    /// Applied in order. Each pattern is deliberately broader than the token
    /// format it targets: a false positive costs a few masked characters in a
    /// diagnostic, a false negative costs a leaked credential.
    ///
    /// Stored as source strings, not `Regex` values — `Regex` is not
    /// `Sendable`, and these run only on failure paths where the compile cost
    /// is irrelevant.
    private static let patternSources = [
        // `NAME=secret` for anything credential-shaped. Runs first so the
        // variable NAME survives (it is what we report) and only the value is
        // masked.
        #"(?i)\b([A-Za-z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD)[A-Za-z0-9_]*)=\S+"#,
        // Anthropic API keys and any similarly shaped `sk-` key.
        #"sk-[A-Za-z0-9_\-]{8,}"#,
        // Authorization headers echoed into output.
        #"(?i)bearer\s+[A-Za-z0-9._\-]{8,}"#,
        // Query strings — OAuth codes and state travel here.
        #"\?\S+"#,
        // Any long opaque run left over (JWTs, base64 blobs).
        #"[A-Za-z0-9_\-]{40,}"#,
    ]

    public static func scrub(_ text: String) -> String {
        var result = text
        for source in patternSources {
            guard let pattern = try? Regex(source) else { continue }
            result = result.replacing(pattern) { match in
                // A captured group means the pattern kept a variable name.
                if match.count > 1, let name = match[1].substring {
                    return "\(name)=\(mask)"
                }
                return mask
            }
        }
        return result
    }

    public static func scrub(_ lines: [String]) -> [String] {
        lines.map(scrub)
    }

    /// Replaces the user's home directory with `~` so diagnostics can be
    /// pasted into an issue without revealing an account name.
    public static func abbreviatingHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty, path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
