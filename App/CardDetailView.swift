import SwiftUI
import OvertureDesign
import OvertureKit
import ClaudeKit
import GitKit

/// The five-tab card sheet (resolution #14). M1 ships Chat, Diff, Activity;
/// Preview and Tests land with M2/M3.
struct CardDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let card: Card
    let store: BoardStore
    @State private var tab: Tab = .chat

    enum Tab: String, CaseIterable {
        case chat = "Chat"
        case diff = "Diff"
        case activity = "Activity"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .chat: ChatTab(card: card, store: store)
            case .diff: DiffTab(card: card)
            case .activity: ActivityTab(card: card)
            }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 520,
               idealHeight: 640)
        .background(DS.Color.Surface.canvas)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s200) {
            HStack {
                Label(card.column.title, systemImage: card.column.icon)
                    .font(DS.TypeStyle.badgeLabel)
                    .foregroundStyle(card.column.status.text)
                    .padding(.horizontal, DS.Space.s200)
                    .padding(.vertical, DS.Space.s050)
                    .background(card.column.status.tint, in: Capsule())
                Spacer()
                if card.column == .review || card.column == .testing {
                    Button("Approve → Done…") {
                        dismiss()
                        store.requestApproval(card)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.Color.Text.tertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            Text(card.title)
                .font(DS.TypeStyle.screenTitle)
                .foregroundStyle(DS.Color.Text.primary)
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
        }
        .padding(DS.Space.s400)
    }
}

// MARK: - Chat

struct ChatTab: View {
    @Environment(AppState.self) private var appState
    let card: Card
    let store: BoardStore
    @State private var draft = ""
    @State private var history: [TranscriptItem] = []

    private var liveState: SessionCoordinator.LiveState? {
        appState.coordinator.live[card.id]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.s400) {
                        ForEach(history) { item in
                            HistoryRow(item: item)
                        }
                        ForEach(liveState?.transcript ?? []) { item in
                            LiveRow(item: item)
                        }
                        if let streaming = liveState?.streamingText,
                           !streaming.isEmpty {
                            Text(streaming)
                                .font(DS.TypeStyle.chatBody)
                                .lineSpacing(DS.TypeStyle.chatBodyLineSpacing)
                                .foregroundStyle(DS.Color.Text.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("streaming")
                        }
                    }
                    .padding(DS.Space.s400)
                    .frame(maxWidth: DS.Layout.transcriptMeasure)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: liveState?.streamingText) {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }
            .background(DS.Color.Surface.sunken)

            if let approval = liveState?.planApproval {
                PlanApprovalBanner(card: card, approval: approval)
            }
            ForEach(liveState?.pendingPermissions ?? []) { pending in
                PermissionBanner(card: card, pending: pending)
            }
            if card.subState == .mergeConflict {
                HStack(spacing: DS.Space.s300) {
                    Label("Merge conflicts with \(store.project.defaultBranch)",
                          systemImage: DS.Icon.conflict)
                        .font(DS.TypeStyle.cardTitle)
                        .foregroundStyle(DS.Status.danger.text)
                    Spacer()
                    Button("Ask Claude to resolve") {
                        store.resolveConflictWithClaude(card)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Open in Terminal") {
                        let path = card.worktreePath ?? store.project.path
                        NSWorkspace.shared.open(
                            [URL(fileURLWithPath: path)],
                            withApplicationAt: URL(fileURLWithPath:
                                "/System/Applications/Utilities/Terminal.app"),
                            configuration: NSWorkspace.OpenConfiguration(),
                            completionHandler: nil)
                    }
                }
                .padding(DS.Space.s400)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Status.danger.tint)
            }
            if let error = liveState?.lastError {
                Label(error, systemImage: DS.Icon.error)
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Status.danger.text)
                    .padding(DS.Space.s300)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Status.danger.tint)
            }

            composer
        }
        .task(id: card.id) { loadHistory() }
    }

    private var composer: some View {
        HStack(spacing: DS.Space.s300) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.TypeStyle.chatBody)
                .lineLimit(1...6)
                .onSubmit(send)
            if liveState?.activity == .working {
                Button {
                    Task { await appState.coordinator.interrupt(card: card) }
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(DS.Status.danger.text)
                }
                .buttonStyle(.plain)
                .help("Interrupt the agent")
            }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(draft.isEmpty
                        ? AnyShapeStyle(DS.Color.Text.tertiary)
                        : AnyShapeStyle(DS.Color.Accent.fill))
            }
            .buttonStyle(.plain)
            .disabled(draft.isEmpty)
        }
        .padding(DS.Space.s300)
        .background(DS.Color.Surface.raised)
    }

    private var placeholder: String {
        switch card.column {
        case .backlog: "Start planning or chat about this ticket…"
        case .done: "Continue this conversation (card returns to In Progress)…"
        default: "Message the agent…"
        }
    }

    private func send() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        draft = ""
        if card.column == .done {
            // Continuing a Done card flies it back (spec 04 §2.2).
            Task {
                try? BoardEngine.apply(
                    .reopen, to: card,
                    in: appState.services.container.mainContext)
                await appState.coordinator.sendChat(message, to: card)
            }
        } else {
            Task { await appState.coordinator.sendChat(message, to: card) }
        }
    }

    private func loadHistory() {
        guard let session = card.sessions.first(where: { $0.role == .primary })
        else { return }
        let urls = TranscriptStore.locate(sessionID: session.sessionID)
        guard let url = urls.first,
              let content = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        history = TranscriptReader.items(fromJSONL: content)
    }
}

struct HistoryRow: View {
    let item: TranscriptItem

    var body: some View {
        switch item.role {
        case .user:
            Text(item.text)
                .font(DS.TypeStyle.chatBody)
                .foregroundStyle(DS.Color.Text.primary)
                .padding(DS.Space.s300)
                .background(DS.Color.Accent.tint,
                            in: RoundedRectangle(cornerRadius: DS.Radius.card))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            Text(LocalizedStringKey(item.text))
                .font(DS.TypeStyle.chatBody)
                .lineSpacing(DS.TypeStyle.chatBodyLineSpacing)
                .foregroundStyle(DS.Color.Text.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .toolUse(let name):
            ToolRow(name: name, detail: item.text)
        case .toolResult:
            EmptyView() // collapsed in M1; expand affordance in M2
        }
    }
}

struct LiveRow: View {
    let item: LiveChatItem

    var body: some View {
        switch item.kind {
        case .user:
            Text(item.text)
                .font(DS.TypeStyle.chatBody)
                .foregroundStyle(DS.Color.Text.primary)
                .padding(DS.Space.s300)
                .background(DS.Color.Accent.tint,
                            in: RoundedRectangle(cornerRadius: DS.Radius.card))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistantText:
            Text(LocalizedStringKey(item.text))
                .font(DS.TypeStyle.chatBody)
                .lineSpacing(DS.TypeStyle.chatBodyLineSpacing)
                .foregroundStyle(DS.Color.Text.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .toolUse(let name):
            ToolRow(name: name, detail: item.text)
        case .notice:
            Label(item.text, systemImage: "info.circle")
                .font(DS.TypeStyle.cardMeta)
                .foregroundStyle(DS.Color.Text.tertiary)
        }
    }
}

struct ToolRow: View {
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: DS.Space.s200) {
            Image(systemName: DS.Icon.terminal)
                .foregroundStyle(DS.Color.Text.tertiary)
            Text(name).font(DS.TypeStyle.toolCallLabel)
                .foregroundStyle(DS.Color.Text.secondary)
            if !detail.isEmpty {
                Text(detail)
                    .font(DS.TypeStyle.code)
                    .foregroundStyle(DS.Color.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, DS.Space.s300)
        .frame(height: DS.Layout.menuRowHeight)
        .background(DS.Color.Surface.raised,
                    in: RoundedRectangle(cornerRadius: DS.Radius.sm))
    }
}

/// Plan approval (spec 04 §6): approve flips the same session into build.
struct PlanApprovalBanner: View {
    @Environment(AppState.self) private var appState
    let card: Card
    let approval: PendingPermission
    @State private var showPlan = false
    @State private var feedback = ""
    @State private var requestingChanges = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s300) {
            HStack {
                Label("Plan ready for review", systemImage: DS.Icon.planReady)
                    .font(DS.TypeStyle.cardTitle)
                    .foregroundStyle(DS.Status.plan.text)
                Spacer()
                Button(showPlan ? "Hide plan" : "Show plan") {
                    showPlan.toggle()
                }
            }
            if showPlan, let plan = approval.planText {
                ScrollView {
                    Text(LocalizedStringKey(plan))
                        .font(DS.TypeStyle.chatBody)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                .padding(DS.Space.s300)
                .background(DS.Color.Surface.raised,
                            in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            }
            if requestingChanges {
                TextField("What should change?", text: $feedback)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendFeedback)
            }
            HStack {
                Button("Approve & Build") {
                    Task { await appState.coordinator.approvePlan(card: card) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                Button("Request changes…") {
                    requestingChanges.toggle()
                }
            }
        }
        .padding(DS.Space.s400)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Status.plan.tint)
    }

    private func sendFeedback() {
        guard !feedback.isEmpty else { return }
        Task {
            await appState.coordinator.requestPlanChanges(
                card: card, feedback: feedback)
        }
        feedback = ""
        requestingChanges = false
    }
}

/// The permission sheet-as-banner (spec 03 §7: opaque, maximum legibility).
struct PermissionBanner: View {
    @Environment(AppState.self) private var appState
    let card: Card
    let pending: PendingPermission
    @State private var denyReason = ""
    @State private var denying = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s300) {
            Label("Agent wants to run \(pending.toolName)",
                  systemImage: DS.Icon.awaitingPermission)
                .font(DS.TypeStyle.cardTitle)
                .foregroundStyle(DS.Status.caution.text)
            Text(pending.displayInput)
                .font(DS.TypeStyle.code)
                .textSelection(.enabled)
                .padding(DS.Space.s300)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Color.Surface.sunken,
                            in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            if denying {
                TextField("Why not? (the agent sees this)", text: $denyReason)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { answer(allow: false) }
            }
            HStack {
                Button("Allow once") { answer(allow: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                if pending.suggestionsAvailable {
                    Button("Always allow") {
                        answer(allow: true, always: true)
                    }
                }
                Button("Deny…") {
                    if denying { answer(allow: false) } else { denying = true }
                }
            }
        }
        .padding(DS.Space.s400)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.Surface.overlay)  // never glass (spec 03 §1.2)
        .overlay(Rectangle().frame(height: 2)
            .foregroundStyle(DS.Status.caution.text), alignment: .top)
    }

    private func answer(allow: Bool, always: Bool = false) {
        Task {
            await appState.coordinator.answerPermission(
                card: card, requestID: pending.id, allow: allow,
                always: always, denyMessage: denyReason)
        }
    }
}

// MARK: - Diff

struct DiffTab: View {
    @Environment(AppState.self) private var appState
    let card: Card
    @State private var files: [DiffFile] = []
    @State private var loadFailed = false

    var body: some View {
        Group {
            if files.isEmpty {
                ContentUnavailableView(
                    loadFailed ? "No diff available" : "No changes yet",
                    systemImage: DS.Icon.diff)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.s400) {
                        ForEach(files) { file in
                            DiffFileView(file: file)
                        }
                    }
                    .padding(DS.Space.s400)
                }
            }
        }
        .background(DS.Color.Surface.sunken)
        .task(id: card.id) { await loadDiff() }
    }

    private func loadDiff() async {
        guard let project = card.project else { return }
        let runner = GitRunner()
        let repo = URL(fileURLWithPath: card.worktreePath ?? project.path)
        do {
            let range: String
            if let branch = card.branchName {
                let base = try await SnapshotRefs(runner: runner).mergeBase(
                    of: branch, and: project.defaultBranch, in: repo)
                range = "\(base)...HEAD"
            } else if let baseRef = card.baseRef {
                range = baseRef
            } else {
                range = "HEAD"
            }
            let unified = try await runner.run(["diff", "-U3", range], in: repo)
            files = DiffParser.files(fromUnified: unified)
        } catch {
            loadFailed = true
        }
    }
}

struct DiffFileView: View {
    let file: DiffFile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(file.path).font(DS.TypeStyle.code)
                    .foregroundStyle(DS.Color.Text.primary)
                Spacer()
                Text("+\(file.additions)")
                    .foregroundStyle(DS.Status.success.text)
                Text("−\(file.deletions)")
                    .foregroundStyle(DS.Status.danger.text)
            }
            .font(DS.TypeStyle.code)
            .padding(DS.Space.s300)
            .background(DS.Color.Surface.raised)

            ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                    DiffLineView(line: line)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm)
            .stroke(DS.Color.Border.subtle, lineWidth: 1))
    }
}

struct DiffLineView: View {
    let line: DiffFile.Hunk.Line

    var body: some View {
        HStack(spacing: DS.Space.s200) {
            Text(line.newNumber.map(String.init)
                 ?? line.oldNumber.map(String.init) ?? "")
                .font(DS.TypeStyle.diffLineNumber)
                .foregroundStyle(DS.Color.Text.tertiary)
                .frame(width: 40, alignment: .trailing)
            Text(line.text)
                .font(DS.TypeStyle.code)
                .foregroundStyle(DS.Color.Text.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.s200)
        .padding(.vertical, 1)
        .background(background)
    }

    private var background: Color {
        switch line.kind {
        case .addition: DS.Color.Diff.addedBackground
        case .deletion: DS.Color.Diff.deletedBackground
        case .context: .clear
        }
    }
}

// MARK: - Activity

struct ActivityTab: View {
    let card: Card

    var body: some View {
        List(card.events.sorted { $0.at > $1.at }, id: \.id) { event in
            HStack(spacing: DS.Space.s300) {
                Text(event.at, style: .time)
                    .font(DS.TypeStyle.timestamp)
                    .foregroundStyle(DS.Color.Text.tertiary)
                Text(event.summary)
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Color.Text.primary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.Color.Surface.sunken)
    }
}

// MARK: - Ticket composer

struct TicketComposer: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let store: BoardStore
    @State private var title = ""
    @State private var details = ""
    @State private var selectedTags: Set<UUID> = []
    @State private var draftPrompt = ""
    @State private var drafting = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s400) {
            Text("New Ticket").font(DS.TypeStyle.screenTitle)

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(DS.TypeStyle.cardTitle)
            TextEditor(text: $details)
                .font(DS.TypeStyle.chatBody)
                .frame(minHeight: 140)
                .padding(DS.Space.s100)
                .background(DS.Color.Surface.sunken,
                            in: RoundedRectangle(cornerRadius: DS.Radius.sm))

            HStack(spacing: DS.Space.s100) {
                ForEach(store.project.tags) { tag in
                    Button {
                        if selectedTags.contains(tag.id) {
                            selectedTags.remove(tag.id)
                        } else {
                            selectedTags.insert(tag.id)
                        }
                    } label: {
                        TagChip(tag: tag)
                            .opacity(selectedTags.contains(tag.id) ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            HStack(spacing: DS.Space.s200) {
                Image(systemName: DS.Icon.sparkles)
                    .foregroundStyle(DS.Color.Accent.text)
                TextField("Draft with Claude: describe the problem roughly…",
                          text: $draftPrompt)
                    .textFieldStyle(.plain)
                    .onSubmit(draftWithClaude)
                if drafting { ProgressView().controlSize(.small) }
            }
            .padding(DS.Space.s300)
            .background(DS.Color.Accent.tint,
                        in: RoundedRectangle(cornerRadius: DS.Radius.md))

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") {
                    let tags = store.project.tags.filter {
                        selectedTags.contains($0.id)
                    }
                    store.createCard(title: title, details: details, tags: tags)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.s600)
        .frame(width: 560)
        .background(DS.Color.Surface.overlay)
    }

    /// The stateless one-shot recipe (resolution #19) — grounded in the
    /// project's code via read-only tools; never becomes the card's session.
    private func draftWithClaude() {
        guard !draftPrompt.isEmpty, !drafting,
              let claudeURL = appState.services.claudeURL else { return }
        drafting = true
        let prompt = draftPrompt
        let projectPath = store.project.path
        Task {
            defer { drafting = false }
            let draft = await TicketDrafter.draft(
                prompt: prompt, claudeURL: claudeURL,
                projectPath: projectPath,
                budget: store.project.draftBudgetUSD)
            if let draft {
                title = draft.title
                details = draft.body
            }
        }
    }
}
