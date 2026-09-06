import SwiftUI
import OvertureDesign
import OvertureKit

/// Per-project configuration (spec 02 §3.1 fields). Execution mode is the
/// headline choice; changing it affects only cards started afterwards.
struct ProjectSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(project.name)
                .font(DS.TypeStyle.screenTitle)
                .padding(DS.Space.s400)
            Form {
                Section("Execution") {
                    Picker("Mode", selection: executionModeBinding) {
                        Text("Worktree per card — parallel agents")
                            .tag(ExecutionMode.worktreePerCard)
                        Text("Single directory — one at a time")
                            .tag(ExecutionMode.singleDirectory)
                    }
                    .pickerStyle(.radioGroup)
                    if project.executionMode == .worktreePerCard {
                        Stepper("Max parallel agents: \(project.maxParallelAgents)",
                                value: $project.maxParallelAgents, in: 1...8)
                    }
                    TextField("Default branch", text: $project.defaultBranch)
                    Picker("Autonomous permissions",
                           selection: permissionBinding) {
                        Text("Accept edits (recommended)")
                            .tag(PermissionMode.acceptEdits)
                        Text("Bypass permissions — use with care")
                            .tag(PermissionMode.bypassPermissions)
                    }
                }
                Section("Testing") {
                    TextField("Test command (e.g. npm test)",
                              text: testCommandBinding)
                    Toggle("Agent-driven testing after each run",
                           isOn: $project.agentTestingEnabled)
                    Toggle("Auto-send fix message on failure (max 2 cycles)",
                           isOn: $project.autoFixOnTestFailure)
                }
                Section("Budgets (per run, USD)") {
                    budgetField("Execution", $project.runBudgetUSD)
                    budgetField("Agent test", $project.testBudgetUSD)
                    budgetField("Ticket draft", $project.draftBudgetUSD)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Space.s400)
        }
        .frame(width: DS.Layout.Sheet.medium, height: DS.Layout.Sheet.medium)
        .background(DS.Color.Surface.overlay)
        // Settings apply as they change, so Esc means the same as Done.
        .onExitCommand { dismiss() }
    }

    private var executionModeBinding: Binding<ExecutionMode> {
        Binding(get: { project.executionMode },
                set: { project.executionMode = $0 })
    }

    private var permissionBinding: Binding<PermissionMode> {
        Binding(get: { project.claudePermissionMode },
                set: { project.claudePermissionMode = $0 })
    }

    private var testCommandBinding: Binding<String> {
        Binding(get: { project.testCommand ?? "" },
                set: { project.testCommand = $0.isEmpty ? nil : $0 })
    }

    private func budgetField(_ label: String,
                             _ value: Binding<Double>) -> some View {
        TextField(label, value: value, format: .number.precision(
            .fractionLength(0...2)))
    }
}
