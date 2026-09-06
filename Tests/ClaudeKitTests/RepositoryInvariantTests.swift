import Foundation
import Testing

/// `SECURITY.md`, `NOTICE` and `README.md` make promises about what Overture
/// never does with your credentials. Conventions get forgotten; these turn the
/// promises into build failures instead — the same trick `ContrastTests` uses
/// for the palette.
@Suite struct RepositoryInvariantTests {
    /// Walks up from this file to the package root.
    private static var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        return url
    }

    /// Source with comments removed. These invariants are about what the code
    /// *does*; a doc comment that names a forbidden API in order to explain
    /// why it is forbidden is exactly what we want to encourage.
    private static func code(of file: URL) throws -> String {
        let source = try String(contentsOf: file, encoding: .utf8)
        var result = ""
        var inBlockComment = false
        for var line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if inBlockComment {
                guard let end = line.range(of: "*/") else { continue }
                line = line[end.upperBound...]
                inBlockComment = false
            }
            if let start = line.range(of: "/*") {
                inBlockComment = true
                line = line[..<start.lowerBound]
            }
            if let start = line.range(of: "//") {
                line = line[..<start.lowerBound]
            }
            result += line + "\n"
        }
        return result
    }

    private static func swiftFiles(under relativePath: String) -> [URL] {
        let root = packageRoot.appendingPathComponent(relativePath)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
    }

    /// Only `VercelKit` may touch the Keychain, and only for Vercel's own
    /// user-supplied token. Claude's credentials are Claude Code's business.
    @Test(arguments: ["Sources/ClaudeKit", "Sources/OvertureKit",
                      "Sources/ProcessCore", "Sources/GitKit"])
    func onlyVercelKitTouchesTheKeychain(target: String) throws {
        for file in Self.swiftFiles(under: target) {
            let source = try Self.code(of: file)
            for forbidden in ["import Security", "SecItemAdd", "SecItemCopyMatching",
                              "SecItemUpdate", "SecItemDelete", "kSecClass"] {
                #expect(!source.contains(forbidden), Comment(rawValue:
                        "\(file.lastPathComponent) uses \(forbidden); only "
                        + "VercelKit may access the Keychain"))
            }
        }
    }

    /// Reading Claude Code's credential store is forbidden even for something
    /// as innocuous-looking as an expiry timestamp — hence no proactive
    /// expiry warning. If you are here because you want one, the answer is
    /// still no.
    @Test func nothingReadsClaudeCodesCredentialStore() throws {
        for target in ["Sources/ClaudeKit", "Sources/OvertureKit"] {
            for file in Self.swiftFiles(under: target) {
                let source = try Self.code(of: file)
                #expect(!source.contains(".credentials.json"), Comment(rawValue:
                        "\(file.lastPathComponent) references Claude Code's "
                        + "credential file"))
                #expect(!source.contains("Claude Code-credentials"), Comment(rawValue:
                        "\(file.lastPathComponent) references Claude Code's "
                        + "Keychain service"))
            }
        }
    }

    /// "Never write to `~/.claude`" — Claude Code owns that store, and
    /// `SECURITY.md` says so publicly. `TranscriptStore` is the only code that
    /// resolves paths inside it, so it is the only place that could regress.
    @Test func theTranscriptStoreOnlyReads() throws {
        let file = Self.packageRoot
            .appendingPathComponent("Sources/ClaudeKit/Transcript.swift")
        let source = try Self.code(of: file)
        for forbidden in ["write(to:", "createFile(", "removeItem(",
                         "createDirectory(", "moveItem(", "copyItem("] {
            #expect(!source.contains(forbidden), Comment(rawValue:
                    "TranscriptStore must never write: found \(forbidden)"))
        }
    }

    /// Overture drives the user's CLI; it never asks for a credential itself.
    /// An API-key field would be the single quickest way to make
    /// `SECURITY.md` a lie.
    @Test func noSourceAsksTheUserForACredential() throws {
        for target in ["Sources/ClaudeKit", "Sources/OvertureKit"] {
            for file in Self.swiftFiles(under: target) {
                let source = try Self.code(of: file)
                #expect(!source.contains("SecureField"), Comment(rawValue:
                        "\(file.lastPathComponent) has a credential field"))
                #expect(!source.contains("setup-token"), Comment(rawValue:
                        "\(file.lastPathComponent) mints a long-lived token"))
            }
        }
    }

    /// Recorded CLI sessions once carried a real account email, home
    /// directory and machine paths. A scanner catches what a find/replace
    /// misses — `CLAUDE.md` notes that long paths split mid-token across
    /// `partial_json` chunks.
    @Test func fixturesContainNoRealIdentifiers() throws {
        let fixtures = Self.packageRoot
            .appendingPathComponent("Tests/ClaudeKitTests/Fixtures")
        let allowedEmailDomains = ["example.com", "example.org"]
        let allowedUsers = ["/Users/dev", "/Users/example"]
        let emailPattern = try Regex(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
        let userPattern = try Regex(#"/Users/[A-Za-z0-9._-]+"#)

        guard let walker = FileManager.default.enumerator(
            at: fixtures, includingPropertiesForKeys: nil) else {
            Issue.record(Comment(rawValue: "no fixtures directory at \(fixtures.path)"))
            return
        }
        for case let file as URL in walker where file.pathExtension == "jsonl" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: emailPattern) {
                let email = String(text[match.range])
                #expect(allowedEmailDomains.contains { email.hasSuffix($0) },
                        Comment(rawValue:
                        "\(file.lastPathComponent) contains a real-looking "
                        + "email; fixtures must use example.com"))
            }
            for match in text.matches(of: userPattern) {
                let path = String(text[match.range])
                #expect(allowedUsers.contains(path), Comment(rawValue:
                        "\(file.lastPathComponent) contains \(path); fixtures "
                        + "must not carry a real home directory"))
            }
        }
    }
}
