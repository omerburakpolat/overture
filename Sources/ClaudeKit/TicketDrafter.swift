import Foundation
import ProcessCore

/// The Backlog composer's "Draft with Claude" one-shot (resolution #19):
/// stateless, read-only tools for codebase grounding, structured output,
/// budget-capped, no transcript.
public enum TicketDrafter {
    public struct Draft: Sendable, Equatable {
        public var title: String
        public var body: String
        public var suggestedTags: [String]
    }

    static let schema = """
    {"type":"object","properties":{"title":{"type":"string"},\
    "body":{"type":"string"},"suggestedTags":{"type":"array",\
    "items":{"type":"string"}}},"required":["title","body"]}
    """

    public static func draft(prompt: String, claudeURL: URL,
                             projectPath: String,
                             budget: Double = 0.5,
                             model: String? = "haiku") async -> Draft? {
        var arguments = ClaudeCLI.ticketDraftArguments(
            schema: schema, model: model, maxBudgetUSD: budget)
        arguments.append("""
        Draft a concise engineering ticket from this rough description. \
        Ground it in the actual codebase (read files as needed): use real \
        file/function names, and include acceptance criteria in the body.

        Description: \(prompt)
        """)
        let subprocess = Subprocess(configuration: .init(
            executable: claudeURL,
            arguments: arguments,
            currentDirectory: URL(fileURLWithPath: projectPath),
            strippedEnvPrefixes: ClaudeCLI.strippedEnvPrefixes))
        guard let lines = try? await subprocess.start() else { return nil }
        var output: [String] = []
        for await line in lines { output.append(line) }
        guard case .exited(code: 0) = await subprocess.waitForExit() else {
            return nil
        }
        guard let value = try? JSONDecoder().decode(
            JSONValue.self, from: Data(output.joined().utf8)),
              let structured = value["structured_output"],
              let title = structured["title"]?.stringValue,
              let body = structured["body"]?.stringValue else { return nil }
        return Draft(title: title, body: body,
                     suggestedTags: (structured["suggestedTags"]?.arrayValue
                        ?? []).compactMap(\.stringValue))
    }
}
