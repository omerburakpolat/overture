import Foundation
import Testing
@testable import ClaudeKit

@Suite struct TranscriptTailAndToolIDTests {
    @Test func toolUseRowsCarryTheToolUseID() throws {
        let url = try #require(Bundle.module.url(
            forResource: "Fixtures/transcript-sample", withExtension: "jsonl"))
        let items = TranscriptReader.items(
            fromJSONL: try String(contentsOf: url, encoding: .utf8))
        let tools = items.filter {
            if case .toolUse = $0.role { return true }
            return false
        }
        #expect(!tools.isEmpty)
        #expect(tools.allSatisfy { $0.toolUseID?.hasPrefix("toolu_") == true })
        #expect(items.filter { $0.role == .user }.allSatisfy { $0.toolUseID == nil })
    }

    @Test func tailReadDropsThePartialFirstLine() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = (1...5).map { #"{"n":\#($0),"pad":"\#(String(repeating: "x", count: 40))"}"# }
        try lines.joined(separator: "\n").write(to: url, atomically: true,
                                                 encoding: .utf8)
        // Window covers the last two lines plus a fragment of the third.
        let window = lines[3].utf8.count + lines[4].utf8.count + 1 + 10
        let tail = try #require(TranscriptStore.readTail(of: url, maxBytes: window))
        #expect(tail == lines[3] + "\n" + lines[4])

        let whole = try #require(TranscriptStore.readTail(of: url, maxBytes: 1 << 20))
        #expect(whole == lines.joined(separator: "\n"))
        #expect(TranscriptStore.readTail(of: url.appendingPathExtension("missing")) == nil)
    }

    /// The window start is an arbitrary byte offset; landing inside an em
    /// dash or an emoji must not nil out the whole tail.
    @Test func tailReadSurvivesAWindowStartingInsideAMultibyteCharacter() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tail-mb-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = #"{"n":1,"text":"a — b — c — d — e — f"}"#
        let second = #"{"n":2,"text":"last line ✓"}"#
        try (first + "\n" + second).write(to: url, atomically: true,
                                          encoding: .utf8)
        let total = first.utf8.count + 1 + second.utf8.count
        // Try every window that cuts somewhere inside the first line.
        for window in (second.utf8.count + 2)..<total {
            let tail = TranscriptStore.readTail(of: url, maxBytes: window)
            #expect(tail == second, "window \(window)")
        }
    }
}
