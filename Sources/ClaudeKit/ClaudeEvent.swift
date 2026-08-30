import Foundation
import ProcessCore

/// One NDJSON message from a `claude` stream-json stdout pipe, decoded
/// tolerantly: load-bearing shapes get typed payloads, everything else is
/// preserved as `.other` — an unknown message type must never be an error
/// (the transcript/stream format is version-drifting; see spec 01 §7.1).
///
/// Wire shapes proven live in spikes/m0 (docs/specs/06-m0-findings.md).
public enum ClaudeEvent: Sendable {
    /// `{"type":"system","subtype":"init",...}` — arrives at TURN start (not
    /// process start). Carries the authoritative session identity.
    case systemInit(SystemInit)
    /// Per-model retry telemetry: `{"type":"system","subtype":"api_retry",...}`.
    case apiRetry(APIRetry)
    /// Any other `system` subtype (`status`, `thinking_tokens`, …).
    case system(subtype: String, raw: JSONValue)
    /// Full assistant API message (text/thinking/tool_use blocks + usage).
    case assistant(AssistantMessage)
    /// Echoed user-side message (tool results; harness replays).
    case user(raw: JSONValue)
    /// Token-level delta when `--include-partial-messages` is set.
    case streamEvent(raw: JSONValue)
    /// Terminal event of ONE TURN (streaming mode emits one per turn — card
    /// transitions must additionally check the supervisor's `runKind`).
    case result(TurnResult)
    /// CLI → host control request (`can_use_tool`, `request_user_dialog`, hooks…).
    case controlRequest(ControlRequest)
    /// CLI's answer to a host-initiated control request.
    case controlResponse(ControlResponse)
    /// CLI cancelled one of its own in-flight requests.
    case controlCancel(requestID: String)
    /// Usage/rate-limit telemetry event.
    case rateLimit(raw: JSONValue)
    /// Anything unrecognized — preserved, surfaced only in diagnostics.
    case other(type: String, raw: JSONValue)
    /// A line that wasn't valid JSON (never fatal; kept for diagnostics).
    case unparseable(line: String)

    // MARK: Payloads

    public struct SystemInit: Sendable {
        public var sessionID: String
        public var model: String?
        public var permissionMode: String?
        public var tools: [String]
        /// Capability strings for feature detection (≥2.1.205) — never
        /// version-compare; check membership here.
        public var capabilities: [String]
        public var raw: JSONValue
    }

    public struct APIRetry: Sendable {
        public var attempt: Int?
        public var maxRetries: Int?
        public var retryDelayMS: Int?
        /// `rate_limit`, `overloaded`, `billing_error`, … drives queue policy.
        public var errorCategory: String?
        public var raw: JSONValue
    }

    public struct AssistantMessage: Sendable {
        public struct ToolUse: Sendable {
            public var id: String
            public var name: String
            public var input: JSONValue
        }
        public var text: String
        public var toolUses: [ToolUse]
        public var model: String?
        /// Non-nil ⇒ subagent traffic; hidden from primary transcript UI.
        public var parentToolUseID: String?
        public var usage: JSONValue?
        public var raw: JSONValue
    }

    public struct TurnResult: Sendable {
        /// `success`, `error_during_execution`, `error_max_turns`,
        /// `error_max_budget_usd`, … (open set — match known, keep raw).
        public var subtype: String
        public var isError: Bool
        public var resultText: String?
        public var sessionID: String?
        public var totalCostUSD: Double?
        public var numTurns: Int?
        public var durationMS: Int?
        public var raw: JSONValue
    }
}

// MARK: - Decoding

public enum ClaudeEventDecoder {
    /// Decodes one NDJSON line. Total function — never throws.
    public static func decode(line: String) -> ClaudeEvent {
        guard let data = line.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let type = value["type"]?.stringValue else {
            return .unparseable(line: line)
        }
        switch type {
        case "system":
            let subtype = value["subtype"]?.stringValue ?? ""
            switch subtype {
            case "init":
                return .systemInit(.init(
                    sessionID: value["session_id"]?.stringValue ?? "",
                    model: value["model"]?.stringValue,
                    permissionMode: value["permissionMode"]?.stringValue,
                    tools: (value["tools"]?.arrayValue ?? [])
                        .compactMap(\.stringValue),
                    capabilities: (value["capabilities"]?.arrayValue ?? [])
                        .compactMap(\.stringValue),
                    raw: value))
            case "api_retry":
                return .apiRetry(.init(
                    attempt: value["attempt"]?.numberValue.map(Int.init),
                    maxRetries: value["max_retries"]?.numberValue.map(Int.init),
                    retryDelayMS: value["retry_delay_ms"]?.numberValue.map(Int.init),
                    errorCategory: value["error"]?.stringValue,
                    raw: value))
            default:
                return .system(subtype: subtype, raw: value)
            }
        case "assistant":
            let message = value["message"]
            var text = ""
            var toolUses: [ClaudeEvent.AssistantMessage.ToolUse] = []
            for block in message?["content"]?.arrayValue ?? [] {
                switch block["type"]?.stringValue {
                case "text":
                    text += block["text"]?.stringValue ?? ""
                case "tool_use":
                    toolUses.append(.init(
                        id: block["id"]?.stringValue ?? "",
                        name: block["name"]?.stringValue ?? "",
                        input: block["input"] ?? .null))
                default:
                    break
                }
            }
            return .assistant(.init(
                text: text,
                toolUses: toolUses,
                model: message?["model"]?.stringValue,
                parentToolUseID: value["parent_tool_use_id"]?.stringValue,
                usage: message?["usage"],
                raw: value))
        case "user":
            return .user(raw: value)
        case "stream_event":
            return .streamEvent(raw: value)
        case "result":
            return .result(.init(
                subtype: value["subtype"]?.stringValue ?? "",
                isError: value["is_error"]?.boolValue ?? false,
                resultText: value["result"]?.stringValue,
                sessionID: value["session_id"]?.stringValue,
                totalCostUSD: value["total_cost_usd"]?.numberValue,
                numTurns: value["num_turns"]?.numberValue.map(Int.init),
                durationMS: value["duration_ms"]?.numberValue.map(Int.init),
                raw: value))
        case "control_request":
            return .controlRequest(ControlRequest(from: value))
        case "control_response":
            return .controlResponse(ControlResponse(from: value))
        case "control_cancel_request":
            return .controlCancel(
                requestID: value["request_id"]?.stringValue ?? "")
        case "rate_limit_event":
            return .rateLimit(raw: value)
        default:
            return .other(type: type, raw: value)
        }
    }
}
