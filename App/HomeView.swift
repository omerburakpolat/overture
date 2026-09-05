import SwiftUI
import OvertureDesign
import OvertureKit
import GitKit

/// Project tiles grid (spec 04 §12). Tile priority: needs-input > agents
/// running > last activity > fresh project.
struct HomeView: View {
    @Environment(AppState.self) private var appState
    @State private var pendingInit: URL?
    @State private var trustCandidate: Project?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(
                .adaptive(minimum: DS.Layout.tileMinWidth,
                          maximum: DS.Layout.tileIdealWidth + 60),
                spacing: DS.Layout.tileGridGap)],
                spacing: DS.Layout.tileGridGap) {
                ForEach(appState.projectsStore.projects) { project in
                    ProjectTile(project: project)
                        .onTapGesture { open(project) }
                        .contextMenu {
                            Button("Remove from Overture", role: .destructive) {
                                appState.projectsStore.remove(project)
                            }
                        }
                }
                AddProjectTile { pickFolder() }
            }
            .padding(DS.Layout.pageMargin)
        }
        .background(DS.Color.Surface.canvas)
        .navigationTitle("Projects")
        .toolbar {
            Button {
                pickFolder()
            } label: {
                Label("Add Project", systemImage: DS.Icon.newTicket)
            }
        }
        .alert("Not a git repository", isPresented: .constant(pendingInit != nil)) {
            Button("Run git init") {
                if let url = pendingInit {
                    Task {
                        try? await appState.projectsStore.initializeRepo(at: url)
                        try? appState.projectsStore.addProject(at: url)
                        pendingInit = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingInit = nil }
        } message: {
            Text("Boards, diffs, and worktrees need git. Initialize "
                 + "\(pendingInit?.lastPathComponent ?? "this folder")?")
        }
        .sheet(item: $trustCandidate) { project in
            TrustGateSheet(project: project) { trusted in
                if trusted {
                    appState.projectsStore.trust(project)
                    appState.navigationPath.append(project.id)
                }
                trustCandidate = nil
            }
        }
    }

    private func open(_ project: Project) {
        if project.trustedAt == nil {
            trustCandidate = project
        } else {
            appState.navigationPath.append(project.id)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder (a git repository)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try appState.projectsStore.addProject(at: url)
        } catch {
            pendingInit = url
        }
    }
}

struct ProjectTile: View {
    @Environment(AppState.self) private var appState
    let project: Project
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s200) {
            Text(project.name)
                .font(DS.TypeStyle.tileTitle)
                .foregroundStyle(DS.Color.Text.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            middle

            Spacer(minLength: 0)

            footer
        }
        .padding(DS.Space.s400)
        .frame(height: DS.Layout.tileHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.Surface.raised,
                    in: RoundedRectangle(cornerRadius: DS.Radius.tile))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.tile)
            .stroke(DS.Color.Border.subtle, lineWidth: 1))
        .elevation(hovering ? .hover : .card)
        .onHover { hovering = $0 }
        .animation(DS.Motion.Spring.snap, value: hovering)
        .task(id: project.id) {
            await appState.projectsStore.refreshGitStatus(for: project)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder private var middle: some View {
        let liveStates = project.cards.compactMap {
            appState.coordinator.live[$0.id]
        }
        let needsInput = liveStates.contains {
            !$0.pendingPermissions.isEmpty || $0.planApproval != nil
        }
        let workingCount = liveStates.filter {
            $0.activity == .working
        }.count

        if needsInput {
            Label("Needs your input", systemImage: DS.Icon.awaitingPermission)
                .font(DS.TypeStyle.tileSummary)
                .foregroundStyle(DS.Status.caution.text)
        } else if workingCount > 0 {
            Label("\(workingCount) agent\(workingCount == 1 ? "" : "s") working…",
                  systemImage: DS.Icon.sparkles)
                .font(DS.TypeStyle.tileSummary)
                .foregroundStyle(DS.Color.Accent.text)
        } else if let summary = freshestSummary {
            Text(summary)
                .font(DS.TypeStyle.tileSummary)
                .foregroundStyle(DS.Color.Text.secondary)
                .lineLimit(2)
        } else {
            Text("No cards yet — open the board and press ⌘N.")
                .font(DS.TypeStyle.tileSummary)
                .foregroundStyle(DS.Color.Text.tertiary)
        }
    }

    /// Freshest of: Overture card activity vs the newest transcript in the
    /// project dir (sessions run in a terminal/Desktop count too).
    private var freshestSummary: String? {
        var candidates: [(Date, String)] = project.cards.compactMap { card in
            card.lastAssistantSummary.map {
                (card.lastActivityAt ?? .distantPast, $0)
            }
        }
        if let external = appState.projectsStore.lastChat[project.id],
           let snippet = external.lastMessageSnippet {
            candidates.append((external.lastTimestamp ?? .distantPast,
                               external.title.map { "\($0) — \(snippet)" }
                                   ?? snippet))
        }
        return candidates.max { $0.0 < $1.0 }?.1
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: DS.Space.s200) {
            if let status = appState.projectsStore.gitStatus[project.id] {
                Label {
                    Text(status.branch ?? "detached")
                        .font(DS.TypeStyle.cardMeta)
                } icon: {
                    Image(systemName: DS.Icon.branch)
                }
                .foregroundStyle(DS.Color.Text.secondary)
                if !status.isClean {
                    Circle().fill(DS.Status.caution.dot)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("uncommitted changes")
                }
                if status.ahead > 0 {
                    Text("↑\(status.ahead)").font(DS.TypeStyle.timestamp)
                        .foregroundStyle(DS.Color.Text.tertiary)
                }
                if status.behind > 0 {
                    Text("↓\(status.behind)").font(DS.TypeStyle.timestamp)
                        .foregroundStyle(DS.Color.Text.tertiary)
                }
            }
            Spacer()
            let open = project.cards.filter {
                $0.archivedAt == nil && $0.column != .done
            }.count
            if open > 0 {
                Text("\(open)")
                    .font(DS.TypeStyle.badgeLabel)
                    .padding(.horizontal, DS.Space.s200)
                    .padding(.vertical, DS.Space.s050)
                    .background(DS.Status.neutral.tint, in: Capsule())
                    .foregroundStyle(DS.Status.neutral.text)
                    .accessibilityLabel("\(open) open cards")
            }
        }
    }

    private var accessibilitySummary: String {
        let status = appState.projectsStore.gitStatus[project.id]
        return "\(project.name), branch \(status?.branch ?? "unknown")"
    }
}

struct AddProjectTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: DS.Space.s200) {
                Image(systemName: DS.Icon.newTicket)
                    .font(.title2)
                Text("Add Project")
                    .font(DS.TypeStyle.cardTitle)
            }
            .foregroundStyle(DS.Color.Text.tertiary)
            .frame(maxWidth: .infinity)
            .frame(height: DS.Layout.tileHeight)
            .background(DS.Color.Surface.sunken,
                        in: RoundedRectangle(cornerRadius: DS.Radius.tile))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.tile)
                .stroke(DS.Color.Border.strong,
                        style: StrokeStyle(lineWidth: 1, dash: [6, 4])))
        }
        .buttonStyle(.plain)
    }
}

/// The per-project trust gate (resolution #12) — shown before the first
/// spawn: headless claude runs the project's own hooks and MCP servers.
struct TrustGateSheet: View {
    let project: Project
    let decision: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s400) {
            Label("Trust this project?", systemImage: DS.Icon.awaitingPermission)
                .font(DS.TypeStyle.screenTitle)
            Text("Running Claude Code in **\(project.name)** executes that "
                 + "project’s own configuration — hooks, MCP servers, and "
                 + "settings in its `.claude` folder. Only continue for "
                 + "projects you trust.")
                .font(DS.TypeStyle.chatBody)
                .foregroundStyle(DS.Color.Text.secondary)
            Text(project.path)
                .font(DS.TypeStyle.code)
                .foregroundStyle(DS.Color.Text.tertiary)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { decision(false) }
                Button("Trust and Open") { decision(true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.s600)
        .frame(width: 480)
        .background(DS.Color.Surface.overlay)
    }
}
