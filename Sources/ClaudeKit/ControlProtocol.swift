import Foundation
import ProcessCore

/// The bidirectional control protocol spoken over a stream-json session.
/// Shapes replicate @anthropic-ai/claude-agent-sdk 0.3.251 and were proven
/// live in the M0 spike (docs/specs/06-m0-findings.md).

// MARK: - CLI → host

/// An incoming `{"type":"control_request", request_id, request:{subtype,…}}`.
public struct ControlRequest: Sendable {
    public var requestID: String
    public var subtype: String
    public var raw: JSONValue

    public init(from value: JSONValue) {
        requestID = value["request_id"]?.stringValue ?? ""
        subtype = value["request"]?["subtype"]?.stringValue ?? ""
        raw = value
    }

    /// Typed view when `subtype == "can_use_tool"`.
    public var permissionRequest: PermissionRequest? {
        guard subtype == "can_use_tool", let request = raw["request"] else {
            return nil
        }
        return PermissionRequest(
            toolName: request["tool_name"]?.stringValue ?? "",
            input: request["input"] ?? .null,
            suggestions: request["permission_suggestions"] ?? .null,
            blockedPath: request["blocked_path"]?.stringValue,
            decisionReason: request["decision_reason"]?.stringValue,
            decisionReasonType: request["decision_reason_type"]?.stringValue,
            classifierApprovable: request["classifier_approvable"]?.boolValue)
    }
}

public struct PermissionRequest: Sendable {
    public var toolName: String
    public var input: JSONValue
    /// `permission_suggestions` verbatim — echo one back as
    /// `updatedPermissions` to implement "Always allow".
    public var suggestions: JSONValue
    public var blockedPath: String?
    /// Human-readable escalation reason. May carry ANSI escapes — sanitize
    /// before rendering.
    public var decisionReason: String?
    /// `rule`/`mode`/`safetyCheck`/`classifier`/… — host policy hook.
    public var decisionReasonType: String?
    public var classifierApprovable: Bool?

    /// Tool names that are questions/protocol, not executions.
    public var isExitPlanMode: Bool { toolName == "ExitPlanMode" }
    public var isAskUserQuestion: Bool { toolName == "AskUserQuestion" }

    /// Plan markdown for ExitPlanMode (`input.plan`; the `planFilePath`
    /// sibling is authoritative when present — read the file).
    public var planText: String? { input["plan"]?.stringValue }
    public var planFilePath: String? { input["planFilePath"]?.stringValue }
}

/// The CLI's answer to a host-initiated control request.
public struct ControlResponse: Sendable {
    public var requestID: String
    public var isSuccess: Bool
    public var payload: JSONValue
    public var errorMessage: String?

    public init(from value: JSONValue) {
        let response = value["response"]
        requestID = response?["request_id"]?.stringValue ?? ""
        isSuccess = response?["subtype"]?.stringValue == "success"
        payload = response?["response"] ?? .null
        errorMessage = response?["error"]?.stringValue
    }
}

// MARK: - Host → CLI

/// Answers and requests Overture writes to the CLI's stdin. Each `encode()`
/// yields one NDJSON line.
public enum OutboundControl {
    /// Permission verdict for a `can_use_tool` request.
    public enum PermissionVerdict: Sendable {
        /// Approve. Echo the original input as `updatedInput` (or an edited
        /// version); attach a `permission_suggestions` entry to persist a rule.
        case allow(updatedInput: JSONValue, updatedPermissions: JSONValue? = nil)
        /// Deny with a message the model sees — doubles as steering.
        case deny(message: String, interrupt: Bool = false)
    }

    public static func permissionResponse(requestID: String,
                                          verdict: PermissionVerdict) -> JSONValue {
        var inner: [String: JSONValue]
        switch verdict {
        case .allow(let input, let permissions):
            inner = ["behavior": .string("allow"), "updatedInput": input]
            if let permissions { inner["updatedPermissions"] = permissions }
        case .deny(let message, let interrupt):
            inner = ["behavior": .string("deny"), "message": .string(message)]
            if interrupt { inner["interrupt"] = .bool(true) }
        }
        return .object([
            "type": .string("control_response"),
            "response": .object([
                "subtype": .string("success"),
                "request_id": .string(requestID),
                "response": .object(inner),
            ]),
        ])
    }

    /// Host-initiated request envelope. Mint `requestID` per call.
    public static func request(requestID: String,
                               body: [String: JSONValue]) -> JSONValue {
        .object([
            "type": .string("control_request"),
            "request_id": .string(requestID),
            "request": .object(body),
        ])
    }

    public static func initialize(requestID: String) -> JSONValue {
        request(requestID: requestID, body: ["subtype": .string("initialize")])
    }

    /// `cancelQueued: true` = stop-means-stop (also cancels queued messages).
    public static func interrupt(requestID: String,
                                 cancelQueued: Bool = false) -> JSONValue {
        var body: [String: JSONValue] = ["subtype": .string("interrupt")]
        if cancelQueued { body["cancel_queued"] = .bool(true) }
        return request(requestID: requestID, body: body)
    }

    public static func setPermissionMode(requestID: String,
                                         mode: String) -> JSONValue {
        request(requestID: requestID, body: [
            "subtype": .string("set_permission_mode"),
            "mode": .string(mode),
        ])
    }

    public static func setModel(requestID: String,
                                model: String?) -> JSONValue {
        request(requestID: requestID, body: [
            "subtype": .string("set_model"),
            "model": model.map(JSONValue.string) ?? .null,
        ])
    }

    /// A user turn. `content` is Messages-API content blocks.
    public static func userMessage(content: JSONValue) -> JSONValue {
        .object([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": content,
            ]),
            "parent_tool_use_id": .null,
        ])
    }

    public static func userText(_ text: String) -> JSONValue {
        userMessage(content: .array([
            .object(["type": .string("text"), "text": .string(text)]),
        ]))
    }

    public static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
