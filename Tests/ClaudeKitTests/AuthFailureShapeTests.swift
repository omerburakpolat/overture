import Foundation
import Testing
@testable import ClaudeKit

/// Synthetic lines mirroring the shapes measured from CLI 2.1.236 in a clean
/// environment (docs/specs/06-m0-findings.md, M1 items 13–14). Hand-written:
/// auth fixtures are never recorded.
@Suite struct AuthFailureShapeTests {
    static let expiredLogin = #"{"type":"assistant","error":"authentication_failed","is_api_error_message":true,"message":{"id":"msg_0","role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"Failed to authenticate: OAuth session expired and could not be refreshed"}]},"parent_tool_use_id":null,"session_id":"00000000-0000-0000-0000-000000000000","uuid":"00000000-0000-0000-0000-000000000001"}"#
    static let rejectedKeyRetry = #"{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":500,"error":"authentication_failed","error_status":401,"session_id":"00000000-0000-0000-0000-000000000000","uuid":"00000000-0000-0000-0000-000000000002"}"#
    static let failedResult = #"{"type":"result","subtype":"success","is_error":true,"api_error_status":null,"result":"Failed to authenticate: OAuth session expired and could not be refreshed","session_id":"00000000-0000-0000-0000-000000000000","uuid":"00000000-0000-0000-0000-000000000003"}"#

    /// The case the `api_retry` branch alone never saw.
    @Test func anExpiredLoginIsAnAssistantMessageWithAnErrorCategory() {
        guard case .assistant(let message) =
                ClaudeEventDecoder.decode(line: Self.expiredLogin) else {
            Issue.record("expected an assistant event")
            return
        }
        #expect(message.error == ClaudeEvent.authenticationFailed)
        #expect(message.isAPIErrorMessage)
        #expect(message.text.contains("OAuth session expired"))
    }

    /// Tolerant decoding: the category is what matters, with or without the
    /// flag beside it.
    @Test func theCategoryIsReadEvenWithoutTheAPIErrorFlag() {
        let line = Self.expiredLogin
            .replacingOccurrences(of: #""is_api_error_message":true,"#, with: "")
        guard case .assistant(let message) = ClaudeEventDecoder.decode(line: line) else {
            Issue.record("expected an assistant event")
            return
        }
        #expect(message.error == ClaudeEvent.authenticationFailed)
        #expect(message.isAPIErrorMessage == false)
    }

    @Test func aRejectedKeyRetryCarriesTheCategoryAndStatus() {
        guard case .apiRetry(let retry) =
                ClaudeEventDecoder.decode(line: Self.rejectedKeyRetry) else {
            Issue.record("expected an api_retry event")
            return
        }
        #expect(retry.errorCategory == ClaudeEvent.authenticationFailed)
        #expect(retry.errorStatus == 401)
        #expect(retry.maxRetries == 10)
    }

    /// Why "Turn ended: success" appeared on a failed card.
    @Test func theFailedTurnIsMarkedSuccessAndErrorAtOnce() {
        guard case .result(let result) =
                ClaudeEventDecoder.decode(line: Self.failedResult) else {
            Issue.record("expected a result event")
            return
        }
        #expect(result.subtype == "success")
        #expect(result.isError)
    }

    @Test func ordinaryAssistantTextCarriesNoErrorCategory() {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]},"parent_tool_use_id":null,"session_id":"s","uuid":"u"}"#
        guard case .assistant(let message) = ClaudeEventDecoder.decode(line: line) else {
            Issue.record("expected an assistant event")
            return
        }
        #expect(message.error == nil)
        #expect(message.isAPIErrorMessage == false)
    }
}
