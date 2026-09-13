import Foundation
import Testing
@testable import ClaudeKit

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("overture-signature-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct CodeSignatureTests {
    @Test func exitCodesMapToVerdicts() {
        #expect(CodeSignature.status(forExitCode: 0) == .anthropic)
        #expect(CodeSignature.status(forExitCode: 3) == .otherDeveloper)
        #expect(CodeSignature.status(forExitCode: 1) == .unsignedOrModified)
        if case .unverified = CodeSignature.status(forExitCode: 2) {} else {
            Issue.record("an unexpected exit code must not claim a verdict")
        }
    }

    /// Real `codesign`, no `claude` needed: Apple signs `/bin/ls`, so it is
    /// validly signed — by someone other than Anthropic.
    @Test func anAppleBinaryIsAnotherDeveloper() async {
        #expect(await CodeSignature.verify(URL(fileURLWithPath: "/bin/ls")) == .otherDeveloper)
    }

    @Test func anUnsignedScriptIsReportedAsSuch() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("claude")
        try "#!/bin/sh\necho 2.1.236\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        #expect(await CodeSignature.verify(script) == .unsignedOrModified)
    }

    /// Homebrew's `claude` is a symlink into the Caskroom; the check follows it.
    @Test func symlinksAreFollowed() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: "/bin/ls"))
        #expect(await CodeSignature.verify(link) == .otherDeveloper)
    }

    /// Runs wherever Claude Code is installed via Homebrew (costs nothing —
    /// no request is made); skipped on CI, which has no `claude`.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/claude")))
    func theInstalledClaudeIsAnthropics() async {
        #expect(await CodeSignature.verify(URL(fileURLWithPath: "/opt/homebrew/bin/claude"))
                == .anthropic)
    }
}

@Suite struct CodeSignatureCacheTests {
    @Test func aVerdictIsReusedUntilTheFileChanges() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let counter = CallCounter()
        let cache = CodeSignatureCache()
        let verify: @Sendable (URL) async -> CodeSignature.Status = { _ in
            counter.increment(); return .unsignedOrModified
        }
        _ = await cache.status(for: file, verify: verify)
        _ = await cache.status(for: file, verify: verify)
        #expect(counter.value == 1)
        // Homebrew or the native installer replaced the binary.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 120)], ofItemAtPath: file.path)
        _ = await cache.status(for: file, verify: verify)
        #expect(counter.value == 2)
    }

    @Test func aCheckThatCouldNotRunIsNotCached() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let counter = CallCounter()
        let cache = CodeSignatureCache()
        let verify: @Sendable (URL) async -> CodeSignature.Status = { _ in
            counter.increment(); return .unverified("offline")
        }
        _ = await cache.status(for: file, verify: verify)
        _ = await cache.status(for: file, verify: verify)
        #expect(counter.value == 2)
    }
}

@Suite struct SignatureInReadinessTests {
    @Test func theVerdictIsReportedButNeverBlocks() async {
        let probes = ClaudeEnvironmentCheck.Probes(
            candidatePaths: { ["/opt/homebrew/bin/claude"] }, overridePath: { nil },
            isExecutable: { _ in true }, loginShellPATH: { nil },
            childEnvironment: { [:] },
            shellDivergence: { _ in .init(names: [], probeSucceeded: true) },
            capture: { _, arguments, _ in
                arguments == ["--version"]
                    ? .init(stdout: "2.1.236 (Claude Code)", exit: .exited(code: 0))
                    : .init(stdout: #"{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty"}"#,
                            exit: .exited(code: 0))
            },
            now: { Date() },
            signature: { _ in .otherDeveloper })
        let readiness = await ClaudeEnvironmentCheck(probes: probes).run()
        #expect(readiness.cli.signature == .otherDeveloper)
        #expect(readiness.canSpawn, "a signature warning must never block a run")
        #expect(readiness.redactedDiagnostics().contains("signature: otherDeveloper"))
    }
}
