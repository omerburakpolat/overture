import Foundation
import Testing
@testable import ProcessCore

@Suite struct SubprocessTests {
    @Test func streamsLinesAndExits() async throws {
        let subprocess = Subprocess(configuration: .init(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'one\\ntwo\\n'"]))
        var lines: [String] = []
        for await line in try await subprocess.start() {
            lines.append(line)
        }
        #expect(lines == ["one", "two"])
        #expect(await subprocess.waitForExit() == .exited(code: 0))
    }

    @Test func stdinRoundTrip() async throws {
        let subprocess = Subprocess(configuration: .init(
            executable: URL(fileURLWithPath: "/usr/bin/tr"),
            arguments: ["a-z", "A-Z"]))
        let stream = try await subprocess.start()
        try await subprocess.writeLine("hello")
        await subprocess.closeStdin()
        var lines: [String] = []
        for await line in stream { lines.append(line) }
        #expect(lines == ["HELLO"])
    }

    @Test func terminateEscalates() async throws {
        let subprocess = Subprocess(configuration: .init(
            executable: URL(fileURLWithPath: "/bin/sh"),
            // Short-lived children only: an orphaned grandchild inherits the
            // stdout pipe and would hold the line stream open until it dies.
            arguments: ["-c", "trap '' INT TERM; while :; do sleep 1; done"]))
        _ = try await subprocess.start()
        try await Task.sleep(for: .milliseconds(200))
        let exit = await subprocess.terminate(gracePeriod: .milliseconds(300))
        #expect(exit == .signalled(signal: SIGKILL))
    }

    @Test func stderrTailCaptured() async throws {
        let subprocess = Subprocess(configuration: .init(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo oops >&2"]))
        for await _ in try await subprocess.start() {}
        _ = await subprocess.waitForExit()
        // stderr reader is async; give it a beat.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await subprocess.stderrSnapshot().contains("oops"))
    }

    @Test func envPrefixStripping() async throws {
        let subprocess = Subprocess(configuration: .init(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo \"[$CLAUDETEST_X]\""],
            environment: ["CLAUDETEST_X": "leak", "PATH": "/usr/bin:/bin"],
            strippedEnvPrefixes: ["CLAUDE"]))
        var lines: [String] = []
        for await line in try await subprocess.start() { lines.append(line) }
        #expect(lines == ["[]"])
    }

    @Test func pidLivenessGuardsAgainstReuse() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        #expect(HostEnvironment.isProcessAlive(
            pid: selfPID, executableHint: "xctest")
            || HostEnvironment.isProcessAlive(
                pid: selfPID, executableHint: "swift"))
        #expect(!HostEnvironment.isProcessAlive(
            pid: selfPID, executableHint: "not-this-binary"))
    }
}
