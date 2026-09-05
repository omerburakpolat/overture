import Foundation
import ProcessCore

/// Read-only access to Claude Code's own session store
/// (`~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`). The format is
/// undocumented and version-drifting — this is Overture's most fragile
/// dependency, so: tolerant decoding only, never write, degrade to
/// "history unavailable" rather than fail (spec 01 §7.1).
public enum TranscriptStore {
    /// `~/.claude` (respects `CLAUDE_CONFIG_DIR`).
    public static func configRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["CLAUDE_CONFIG_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
    }

    /// Observed encoding rule: every non-alphanumeric character becomes "-".
    /// Fine for DISPLAY lookups (tiles); never trusted for session identity
    /// (that path goes through `locate`).
    public static func encodedDirName(forCWD path: String) -> String {
        String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// Newest transcript in a cwd's project dir — powers "last chat" tiles
    /// for sessions Overture did NOT spawn (terminal/Desktop usage).
    public static func newestTranscript(forCWD path: String,
                                        configRoot: URL = configRoot()) -> URL? {
        let dir = configRoot.appendingPathComponent("projects")
            .appendingPathComponent(encodedDirName(forCWD: path))
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? []
        return files.filter { $0.pathExtension == "jsonl" }
            .max { lhs, rhs in
                let l = (try? lhs.resourceValues(
                    forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(
                    forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return l < r
            }
    }

    /// The cwd-encoding is non-injective and version-dependent — NEVER
    /// derive-and-trust. Locate a session by globbing every project dir
    /// (resolution #5; M0 finding #9 confirms lines stay at the origin dir
    /// across cwd-changing resumes).
    public static func locate(sessionID: UUID,
                              configRoot: URL = configRoot()) -> [URL] {
        let projects = configRoot.appendingPathComponent("projects")
        let target = "\(sessionID.uuidString.lowercased()).jsonl"
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir in
            let candidate = dir.appendingPathComponent(target)
            return FileManager.default.fileExists(atPath: candidate.path)
                ? candidate : nil
        }
    }
}

/// One rendered chat item from a transcript.
public struct TranscriptItem: Sendable, Identifiable {
    public enum Role: Sendable, Equatable {
        case user
        case assistant
        case toolUse(name: String)
        case toolResult
    }

    public var id: String       // transcript line uuid
    public var parentID: String?
    public var role: Role
    public var text: String
    public var timestamp: Date?
    public var isSidechain: Bool
    public var raw: JSONValue
}

/// Session-level metadata mined from a transcript (titles for tiles).
public struct TranscriptSummary: Sendable {
    public var sessionID: String?
    public var title: String?          // custom-title ?? ai-title ?? first user line
    public var lastMessageSnippet: String?
    public var lastTimestamp: Date?
}

public enum TranscriptReader {
    /// Parses whole-file content into chat items on the ACTIVE branch (the
    /// ancestry of the last line — edits/forks create DAG branches).
    /// Total function: unknown line types are skipped, never fatal.
    public static func items(fromJSONL content: String) -> [TranscriptItem] {
        // The DAG spans EVERY line type (attachments, thinking, titles all
        // carry uuid/parentUuid and sit on the spine) — ancestry must walk
        // the full graph even though only user/assistant lines render.
        var parentOf: [String: String] = [:]
        var items: [(lineID: String, item: TranscriptItem)] = []
        var lastID: String?

        for line in content.split(separator: "\n") {
            guard let value = try? JSONDecoder().decode(
                JSONValue.self, from: Data(line.utf8)) else { continue }
            guard let uuid = value["uuid"]?.stringValue else { continue }
            if let parent = value["parentUuid"]?.stringValue {
                parentOf[uuid] = parent
            }
            lastID = uuid
            guard let type = value["type"]?.stringValue,
                  type == "user" || type == "assistant" else { continue }
            let sidechain = value["isSidechain"]?.boolValue ?? false
            let message = value["message"]
            let timestamp = value["timestamp"]?.stringValue
                .flatMap { TranscriptDate.parse($0) }

            var pieces: [(TranscriptItem.Role, String)] = []
            if let text = message?["content"]?.stringValue {
                pieces.append((type == "user" ? .user : .assistant, text))
            } else {
                for block in message?["content"]?.arrayValue ?? [] {
                    switch block["type"]?.stringValue {
                    case "text":
                        pieces.append((type == "user" ? .user : .assistant,
                                       block["text"]?.stringValue ?? ""))
                    case "tool_use":
                        pieces.append((.toolUse(
                            name: block["name"]?.stringValue ?? "tool"),
                            OutboundControl.encode(block["input"] ?? .null)))
                    case "tool_result":
                        pieces.append((.toolResult,
                                       block["content"]?.stringValue ?? ""))
                    default:
                        break
                    }
                }
            }
            // One line usually holds one block; multi-block lines become
            // sub-items sharing the line's uuid for ancestry membership.
            for (index, piece) in pieces.enumerated() {
                items.append((lineID: uuid, item: TranscriptItem(
                    id: index == 0 ? uuid : "\(uuid)#\(index)",
                    parentID: value["parentUuid"]?.stringValue,
                    role: piece.0, text: piece.1, timestamp: timestamp,
                    isSidechain: sidechain, raw: value)))
            }
        }

        // Active branch: ancestry of the LAST line over the full uuid graph
        // (forks/edits leave abandoned siblings off this path).
        guard var cursor = lastID else { return [] }
        var active: Set<String> = [cursor]
        while let parent = parentOf[cursor], !active.contains(parent) {
            active.insert(parent)
            cursor = parent
        }
        return items.compactMap { lineID, item in
            guard active.contains(lineID), !item.isSidechain else {
                return nil
            }
            return item
        }
    }

    /// Cheap tail-read for tiles: title lines + last message snippet without
    /// parsing the whole file (reads the last `tailBytes` only).
    public static func summary(of url: URL,
                               tailBytes: Int = 256 * 1024) -> TranscriptSummary {
        var summary = TranscriptSummary()
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return summary
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else {
            return summary
        }
        for line in content.split(separator: "\n").reversed() {
            guard let value = try? JSONDecoder().decode(
                JSONValue.self, from: Data(line.utf8)),
                  let type = value["type"]?.stringValue else { continue }
            switch type {
            case "custom-title":
                summary.title = value["title"]?.stringValue ?? summary.title
            case "ai-title":
                if summary.title == nil {
                    summary.title = value["title"]?.stringValue
                }
            case "assistant", "user":
                if summary.lastMessageSnippet == nil {
                    let message = value["message"]
                    let text = message?["content"]?.stringValue
                        ?? message?["content"]?.arrayValue?
                            .compactMap { $0["text"]?.stringValue }
                            .joined(separator: " ")
                    if let text, !text.isEmpty {
                        summary.lastMessageSnippet = String(text.prefix(200))
                        summary.lastTimestamp = value["timestamp"]?.stringValue
                            .flatMap { TranscriptDate.parse($0) }
                        summary.sessionID = value["sessionId"]?.stringValue
                    }
                }
            default:
                continue
            }
            if summary.title != nil, summary.lastMessageSnippet != nil { break }
        }
        return summary
    }
}

enum TranscriptDate {
    /// Transcript timestamps carry fractional seconds; accept both forms.
    static func parse(_ string: String) -> Date? {
        (try? Date(string, strategy: Date.ISO8601FormatStyle(
            includingFractionalSeconds: true)))
            ?? (try? Date(string, strategy: .iso8601))
    }
}
