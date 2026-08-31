import Foundation
import ProcessCore

/// GitHub via the user's own `gh` CLI — no OAuth client to ship, no token to
/// store (spec 02 §6). Degrades feature-level when gh is missing/unauthed.
public actor GitHubService {
    public enum ServiceError: Error, Sendable, Equatable {
        /// gh missing or not authenticated — PR features off, with a fix-it.
        case unavailable(hint: String)
        case commandFailed(String)
        case unparseableOutput(String)
    }

    public struct PRStatus: Sendable, Equatable {
        public var state: String            // OPEN | MERGED | CLOSED
        public var mergeable: String?       // MERGEABLE | CONFLICTING | UNKNOWN
        public var reviewDecision: String?  // APPROVED | CHANGES_REQUESTED | …
        public var checks: CheckRollup
    }

    /// Compact pass/fail/pending roll-up for the card chip.
    public struct CheckRollup: Sendable, Equatable {
        public var passed: Int
        public var failed: Int
        public var pending: Int
        public init(passed: Int = 0, failed: Int = 0, pending: Int = 0) {
            self.passed = passed
            self.failed = failed
            self.pending = pending
        }
    }

    private let ghPath: URL

    public init(ghPath: URL = URL(fileURLWithPath: "/opt/homebrew/bin/gh")) {
        self.ghPath = ghPath
    }

    /// Preflight, run on project open. Throws `.unavailable` with a fix-it.
    public func checkAvailability(in repo: URL) async throws {
        guard FileManager.default.isExecutableFile(atPath: ghPath.path) else {
            throw ServiceError.unavailable(
                hint: "Install GitHub CLI: brew install gh")
        }
        let (exit, _, stderr) = await run(["auth", "status"], in: repo)
        guard case .exited(code: 0) = exit else {
            throw ServiceError.unavailable(
                hint: "Sign in with: gh auth login — \(stderr.suffix(1).joined())")
        }
    }

    public func repoNameWithOwner(in repo: URL) async throws -> String {
        let output = try await runOK(
            ["repo", "view", "--json", "nameWithOwner"], in: repo)
        guard let name = Self.decode(output)?["nameWithOwner"]?.stringValue else {
            throw ServiceError.unparseableOutput(output)
        }
        return name
    }

    /// Pushes the branch and opens a PR; returns (number, url).
    public func prCreate(head: String, title: String, body: String,
                         in repo: URL) async throws -> (number: Int, url: String) {
        let output = try await runOK(
            ["pr", "create", "--head", head, "--title", title, "--body", body],
            in: repo)
        // gh prints the PR URL as the last line.
        guard let url = output.split(separator: "\n").last
            .map(String.init)?.trimmingCharacters(in: .whitespaces),
              let number = Int(url.split(separator: "/").last ?? "") else {
            throw ServiceError.unparseableOutput(output)
        }
        return (number, url)
    }

    public func prStatus(number: Int, in repo: URL) async throws -> PRStatus {
        let output = try await runOK(
            ["pr", "view", String(number), "--json",
             "state,mergeable,statusCheckRollup,reviewDecision"], in: repo)
        return try Self.parsePRStatus(output)
    }

    public func prMerge(number: Int, in repo: URL) async throws {
        _ = try await runOK(["pr", "merge", String(number),
                             "--squash", "--delete-branch"], in: repo)
    }

    /// Pure parser, golden-tested against canned gh JSON.
    public static func parsePRStatus(_ json: String) throws -> PRStatus {
        guard let value = decode(json),
              let state = value["state"]?.stringValue else {
            throw ServiceError.unparseableOutput(String(json.prefix(200)))
        }
        var rollup = CheckRollup()
        for check in value["statusCheckRollup"]?.arrayValue ?? [] {
            // Two shapes: CheckRun {status, conclusion} and
            // StatusContext {state}.
            let conclusion = check["conclusion"]?.stringValue
                ?? check["state"]?.stringValue ?? ""
            let status = check["status"]?.stringValue ?? "COMPLETED"
            if status != "COMPLETED" {
                rollup.pending += 1
            } else {
                switch conclusion.uppercased() {
                case "SUCCESS", "NEUTRAL", "SKIPPED":
                    rollup.passed += 1
                case "PENDING", "":
                    rollup.pending += 1
                default:
                    rollup.failed += 1
                }
            }
        }
        return PRStatus(state: state,
                        mergeable: value["mergeable"]?.stringValue,
                        reviewDecision: value["reviewDecision"]?.stringValue,
                        checks: rollup)
    }

    // MARK: - Plumbing

    private func runOK(_ args: [String], in repo: URL) async throws -> String {
        let (exit, stdout, stderr) = await run(args, in: repo)
        guard case .exited(code: 0) = exit else {
            throw ServiceError.commandFailed(
                "gh \(args.joined(separator: " ")): "
                + stderr.suffix(3).joined(separator: " | "))
        }
        return stdout
    }

    private func run(_ args: [String], in repo: URL)
        async -> (SubprocessExit, String, [String]) {
        let subprocess = Subprocess(configuration: .init(
            executable: ghPath, arguments: args, currentDirectory: repo))
        guard let lines = try? await subprocess.start() else {
            return (.failedToLaunch("spawn failed"), "", [])
        }
        var output: [String] = []
        for await line in lines { output.append(line) }
        let exit = await subprocess.waitForExit()
        return (exit, output.joined(separator: "\n"),
                await subprocess.stderrSnapshot())
    }

    private static func decode(_ json: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }
}
