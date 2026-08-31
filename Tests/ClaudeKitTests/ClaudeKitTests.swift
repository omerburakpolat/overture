import Foundation
import Testing
@testable import ClaudeKit
import ProcessCore

/// Golden tests against the M0 spike captures (spikes/m0/fixtures — real
/// stream-json from claude v2.1.231). "OUT" lines are CLI stdout; "IN" lines
/// are what the harness wrote to stdin.
private func fixtureLines(_ name: String, direction: String = "OUT") throws -> [String] {
    let url = try #require(Bundle.module.url(
        forResource: "Fixtures/\(name)", withExtension: "jsonl"))
    let content = try String(contentsOf: url, encoding: .utf8)
    return content.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: "\t", maxSplits: 1)
        guard parts.count == 2, parts[0] == direction.dropLast(0) else { return nil }
        return String(parts[1])
    }
}

@Suite struct DecoderGoldenTests {
    @Test(arguments: ["a-permissions", "b-interrupt", "c-plan", "d-resume"])
    func everyCapturedLineDecodes(fixture: String) throws {
        let lines = try fixtureLines(fixture)
        #expect(!lines.isEmpty)
        for line in lines {
            if case .unparseable = ClaudeEventDecoder.decode(line: line) {
                Issue.record("unparseable line in \(fixture): \(line.prefix(120))")
            }
        }
    }

    @Test func permissionRequestShape() throws {
        let events = try fixtureLines("a-permissions")
            .map(ClaudeEventDecoder.decode(line:))
        let requests = events.compactMap { event -> PermissionRequest? in
            if case .controlRequest(let request) = event {
                return request.permissionRequest
            }
            return nil
        }
        let bash = try #require(requests.first { $0.toolName == "Bash" })
        #expect(bash.input["command"]?.stringValue == "touch m0-touch.txt")
        #expect(bash.suggestions.arrayValue?.isEmpty == false)
    }

    @Test func perTurnResults() throws {
        let events = try fixtureLines("a-permissions")
            .map(ClaudeEventDecoder.decode(line:))
        let results = events.compactMap { event -> ClaudeEvent.TurnResult? in
            if case .result(let result) = event { return result }
            return nil
        }
        // Scenario A ran three turns through ONE process.
        #expect(results.count == 3)
        #expect(results.allSatisfy { $0.subtype == "success" && !$0.isError })
        #expect(results.allSatisfy { ($0.totalCostUSD ?? 0) > 0 })
    }

    @Test func systemInitCarriesIdentity() throws {
        let events = try fixtureLines("a-permissions")
            .map(ClaudeEventDecoder.decode(line:))
        let inits = events.compactMap { event -> ClaudeEvent.SystemInit? in
            if case .systemInit(let initInfo) = event { return initInfo }
            return nil
        }
        let first = try #require(inits.first)
        #expect(!first.sessionID.isEmpty)
        #expect(first.permissionMode == "default") // "manual" aliases to this
    }

    @Test func exitPlanModeCarriesPlan() throws {
        let events = try fixtureLines("c-plan")
            .map(ClaudeEventDecoder.decode(line:))
        let exitPlan = try #require(events.compactMap { event -> PermissionRequest? in
            if case .controlRequest(let request) = event,
               let permission = request.permissionRequest,
               permission.isExitPlanMode { return permission }
            return nil
        }.first)
        #expect(exitPlan.planText?.contains("README") == true)
        #expect(exitPlan.planFilePath?.isEmpty == false)
    }

    @Test func interruptEndsTurnWithErrorResult() throws {
        let events = try fixtureLines("b-interrupt")
            .map(ClaudeEventDecoder.decode(line:))
        let result = try #require(events.compactMap { event -> ClaudeEvent.TurnResult? in
            if case .result(let result) = event { return result }
            return nil
        }.last)
        #expect(result.subtype == "error_during_execution")
        #expect(result.isError)
    }

    @Test func unknownTypesArePreservedNotFatal() {
        let event = ClaudeEventDecoder.decode(
            line: #"{"type":"totally_new_thing","x":1}"#)
        guard case .other(let type, let raw) = event else {
            Issue.record("expected .other, got \(event)")
            return
        }
        #expect(type == "totally_new_thing")
        #expect(raw["x"]?.numberValue == 1)
    }
}

@Suite struct OutboundControlTests {
    @Test func allowResponseMatchesSDKShape() throws {
        let json = OutboundControl.encode(OutboundControl.permissionResponse(
            requestID: "r1",
            verdict: .allow(updatedInput: .object(
                ["command": .string("touch x")]))))
        let value = try JSONDecoder().decode(
            JSONValue.self, from: Data(json.utf8))
        #expect(value["type"]?.stringValue == "control_response")
        let response = value["response"]
        #expect(response?["subtype"]?.stringValue == "success")
        #expect(response?["request_id"]?.stringValue == "r1")
        #expect(response?["response"]?["behavior"]?.stringValue == "allow")
        #expect(response?["response"]?["updatedInput"]?["command"]?.stringValue
                == "touch x")
    }

    @Test func denyCarriesMessage() throws {
        let json = OutboundControl.encode(OutboundControl.permissionResponse(
            requestID: "r2", verdict: .deny(message: "nope")))
        let value = try JSONDecoder().decode(
            JSONValue.self, from: Data(json.utf8))
        #expect(value["response"]?["response"]?["behavior"]?.stringValue == "deny")
        #expect(value["response"]?["response"]?["message"]?.stringValue == "nope")
    }
}

@Suite struct SpawnArgumentTests {
    @Test func streamingRecipeMatchesContractOfRecord() {
        let id = UUID()
        let args = ClaudeCLI.streamingArguments(for: .init(
            sessionID: id, profile: .askMe))
        // SDK 0.3.251 base args, in its order.
        #expect(args.starts(with: ["-p", "--output-format", "stream-json",
                                   "--verbose", "--input-format", "stream-json"]))
        #expect(args.contains("--permission-prompt-tool"))
        #expect(args[args.firstIndex(of: "--permission-prompt-tool")! + 1] == "stdio")
        #expect(args.contains(id.uuidString.lowercased()))
        #expect(!args.contains("--resume"))
    }

    @Test func resumeOmitsSessionID() {
        let id = UUID()
        let args = ClaudeCLI.streamingArguments(for: .init(
            sessionID: id, resume: true, profile: .autonomous))
        #expect(args.contains("--resume"))
        #expect(!args.contains("--session-id"))
        #expect(args[args.firstIndex(of: "--permission-mode")! + 1] == "acceptEdits")
    }

    @Test func ticketDraftRecipeIsStatelessAndReadOnly() {
        let args = ClaudeCLI.ticketDraftArguments(schema: "{}")
        #expect(args.contains("--no-session-persistence"))
        #expect(args.contains("Read,Glob,Grep"))
        #expect(!args.contains("--bare")) // OAuth-incompatible; resolution #19
    }
}

@Suite struct InitializeInfoTests {
    @Test func decodesRealInitializeResponse() throws {
        // The captured initialize response from scenario A.
        let line = try #require(try fixtureLines("a-permissions").first {
            $0.contains("\"control_response\"")
        })
        guard case .controlResponse(let response) =
            ClaudeEventDecoder.decode(line: line) else {
            Issue.record("expected control_response")
            return
        }
        let info = try #require(InitializeInfo(from: response))
        #expect(!info.commands.isEmpty)
        #expect(!info.models.isEmpty)
        let first = try #require(info.models.first)
        #expect(!first.displayName.isEmpty)
        #expect(first.supportsEffort)
        #expect(first.effortLevels.contains("max"))
        #expect(info.accountEmail?.contains("@") == true)
    }
}
