import Foundation
import Testing
import ProcessCore
@testable import ClaudeKit

/// Records every CLI invocation a check makes, so tests can assert on the
/// environment each probe saw.
private final class ProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(arguments: [String], environment: [String: String])] = []

    func record(_ arguments: [String], _ environment: [String: String]) {
        lock.lock(); calls.append((arguments, environment)); lock.unlock()
    }

    var statusEnvironments: [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.arguments == ["auth", "status", "--json"] }
            .map(\.environment)
    }
}

@Suite struct StoredLoginProbeTests {
    static let maxLogin = #"{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "email": "user@example.com", "subscriptionType": "max"}"#
    static let apiKeyShape = #"{"loggedIn": true, "authMethod": "api_key", "apiProvider": "firstParty", "apiKeySource": "ANTHROPIC_API_KEY"}"#
    static let nobody = #"{"loggedIn": false, "authMethod": "none", "apiProvider": "firstParty"}"#

    private static func probes(
        recorder: ProbeRecorder,
        environment: [String: String],
        status: @escaping @Sendable ([String: String]) -> String
    ) -> ClaudeEnvironmentCheck.Probes {
        .init(candidatePaths: { ["/opt/homebrew/bin/claude"] },
              overridePath: { nil },
              isExecutable: { _ in true },
              loginShellPATH: { nil },
              childEnvironment: { environment },
              shellDivergence: { _ in .init(names: [], probeSucceeded: true) },
              capture: { _, arguments, env in
                  recorder.record(arguments, env)
                  if arguments == ["--version"] {
                      return .init(stdout: "2.1.236 (Claude Code)", exit: .exited(code: 0))
                  }
                  return .init(stdout: status(env), exit: .exited(code: 0))
              },
              now: { Date(timeIntervalSince1970: 0) })
    }

    /// The ordinary case pays nothing extra.
    @Test func aCleanEnvironmentCostsOneStatusProbe() async {
        let recorder = ProbeRecorder()
        let readiness = await ClaudeEnvironmentCheck(probes: Self.probes(
            recorder: recorder, environment: ["PATH": "/usr/bin"],
            status: { _ in Self.maxLogin })).run()
        #expect(recorder.statusEnvironments.count == 1)
        #expect(readiness.storedLogin == nil)
    }

    /// Measured: with a key set and no working login underneath, the CLI
    /// reports plain `api_key`, which the shape-based rule reads as "nothing
    /// to override" — wrong whenever a subscription login does exist. Asking
    /// again with the key's name removed answers it directly.
    @Test func anAPIKeyIsCheckedAgainstTheLoginUnderneath() async {
        let recorder = ProbeRecorder()
        let readiness = await ClaudeEnvironmentCheck(probes: Self.probes(
            recorder: recorder,
            environment: ["ANTHROPIC_API_KEY": "sk-ant-CANARYabcdefgh",
                          "CLAUDE_CONFIG_DIR": "/tmp/overture-config"],
            status: { env in
                env["ANTHROPIC_API_KEY"] == nil ? Self.maxLogin : Self.apiKeyShape
            })).run()
        let environments = recorder.statusEnvironments
        #expect(environments.count == 2)
        #expect(environments.last?["ANTHROPIC_API_KEY"] == nil)
        // Only override names go; the config dir still selects the store.
        #expect(environments.last?["CLAUDE_CONFIG_DIR"] == "/tmp/overture-config")
        #expect(readiness.storedLogin?.subscriptionType == "max")
        #expect(readiness.effectiveCredential?.source == .apiKeyEnvironment)
        #expect(readiness.effectiveCredential?.overridesReportedLogin == true)
        let diagnostics = readiness.redactedDiagnostics()
        #expect(!diagnostics.contains("CANARY"))
        #expect(!diagnostics.contains("user@example.com"))
        #expect(diagnostics.contains("storedLogin: signed in"))
    }

    @Test func anAPIKeyWithNothingUnderneathIsSimplyTheCredential() async {
        let recorder = ProbeRecorder()
        let readiness = await ClaudeEnvironmentCheck(probes: Self.probes(
            recorder: recorder,
            environment: ["ANTHROPIC_API_KEY": "sk-ant-CANARYabcdefgh"],
            status: { env in
                env["ANTHROPIC_API_KEY"] == nil ? Self.nobody : Self.apiKeyShape
            })).run()
        #expect(readiness.effectiveCredential?.source == .apiKeyEnvironment)
        #expect(readiness.effectiveCredential?.overridesReportedLogin == false)
    }
}
