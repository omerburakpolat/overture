import Foundation

/// Parses the tester session's final message. The prompt asks for a strict
/// trailing `VERDICT: PASS|FAIL` line plus failure bullets, but models drift
/// — parsing is forgiving: last VERDICT line wins; no VERDICT at all is a
/// FAIL (an unverifiable run must not silently pass).
public enum TestVerdictParser {
    public struct Outcome: Sendable, Equatable {
        public var passed: Bool
        public var summary: String
        public var failures: [TestFailure]
    }

    public static func parse(_ text: String) -> Outcome {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var verdict: Bool?
        var failures: [TestFailure] = []
        var afterVerdict = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = trimmed.firstMatch(
                of: /(?i)^\**\s*VERDICT\s*:?\s*\**\s*(PASS|FAIL)/) {
                verdict = match.1.uppercased() == "PASS"
                afterVerdict = true
                failures.removeAll()   // bullets belong to the LAST verdict
                continue
            }
            if afterVerdict, trimmed.hasPrefix("-") {
                let body = trimmed.drop(while: { $0 == "-" || $0 == " " })
                let parts = body.split(separator: ":", maxSplits: 1)
                failures.append(TestFailure(
                    title: parts.first.map(String.init)?
                        .trimmingCharacters(in: .whitespaces) ?? String(body),
                    detail: parts.count > 1
                        ? parts[1].trimmingCharacters(in: .whitespaces) : ""))
            }
        }

        guard let verdict else {
            return Outcome(passed: false,
                           summary: "No verdict reported",
                           failures: [TestFailure(
                               title: "No verdict",
                               detail: "The test run ended without a "
                                   + "VERDICT line.")])
        }
        let summary = verdict
            ? "Verified"
            : (failures.isEmpty ? "Failed"
               : "\(failures.count) failure\(failures.count == 1 ? "" : "s")")
        return Outcome(passed: verdict, summary: summary, failures: failures)
    }
}
