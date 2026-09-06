import SwiftUI
import OvertureDesign
import OvertureKit
import ClaudeKit
import GitKit

/// The five-tab card sheet (resolution #14). The Chat tab is the ticket
/// itself — title, description, tags — with its thread underneath: the
/// primary Claude conversation, the card's activity and its test verdicts in
/// one stream, the way a ticket's comments read in a tracker.
struct CardDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let card: Card
    let store: BoardStore
    @State private var tab: Tab = .chat
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    enum Tab: String, CaseIterable {
        case chat = "Chat"
        case diff = "Diff"
        case preview = "Preview"
        case tests = "Tests"
        case activity = "Activity"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .chat: ThreadTab(card: card, store: store)
            case .diff: DiffTab(card: card)
            case .preview: PreviewTab(card: card, store: store)
            case .tests: TestsTab(card: card)
            case .activity: ActivityTab(card: card)
            }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 520,
               idealHeight: 640)
        .background(DS.Color.Surface.canvas)
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                Text(toast.message)
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Color.Text.primary)
                    .padding(.horizontal, DS.Space.s400)
                    .padding(.vertical, DS.Space.s300)
                    .glassOrOpaque(in: RoundedRectangle(
                        cornerRadius: DS.Radius.panel))
                    .elevation(.overlay)
                    .padding(.bottom, DS.Space.s1200)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(DS.Motion.Spring.entrance, value: store.toast)
        .onAppear { titleDraft = card.title }
        .onChange(of: card.title) { titleDraft = card.title }
        .onChange(of: titleFocused) { if !titleFocused { commitTitle() } }
        // Focus loss is not delivered to a sheet being torn down, so every
        // exit commits explicitly; onDisappear is the backstop.
        .onDisappear { commitTitle() }
    }

    private var liveState: SessionCoordinator.LiveState? {
        appState.coordinator.live[card.id]
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s200) {
            HStack(spacing: DS.Space.s200) {
                Label(card.column.title, systemImage: card.column.icon)
                    .font(DS.TypeStyle.badgeLabel)
                    .foregroundStyle(card.column.status.text)
                    .padding(.horizontal, DS.Space.s200)
                    .padding(.vertical, DS.Space.s050)
                    .background(card.column.status.tint, in: Capsule())
                if card.subState != .idle {
                    Text(card.subState.displayName)
                        .font(DS.TypeStyle.badgeLabel)
                        .foregroundStyle(DS.Color.Text.tertiary)
                }
                Spacer()
                actions
                Button {
                    commitTitle()
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.Color.Text.tertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            TextField("Title", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(DS.TypeStyle.screenTitle)
                .foregroundStyle(DS.Color.Text.primary)
                .focused($titleFocused)
                .onSubmit { titleFocused = false }
                .accessibilityLabel("Ticket title")
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 380)
        }
        .padding(DS.Space.s400)
    }

    /// State-contextual actions (spec 04 §3.3): the same transitions a drag
    /// performs, one click away from the ticket.
    @ViewBuilder private var actions: some View {
        if card.subState.pinsCard {
            Button("Interrupt", role: .destructive) {
                Task { await appState.coordinator.interrupt(card: card) }
            }
        }
        switch card.column {
        case .backlog:
            Button("Start building") {
                store.perform(.drag(to: .inProgress), on: card)
            }
            Button("Plan") {
                store.perform(.startPlan, on: card)
            }
            .buttonStyle(.borderedProminent)
        case .review, .testing:
            Button("Approve → Done…") {
                commitTitle()
                dismiss()
                store.requestApproval(card)
            }
            .buttonStyle(.borderedProminent)
        case .done:
            Button("Reopen") { store.reopen(card) }
        case .inProgress:
            if !card.subState.pinsCard, card.subState != .queued {
                Button("Continue build") {
                    store.perform(.resumeRun, on: card)
                }
            }
        case .plan:
            EmptyView()
        }
    }

    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != card.title else {
            titleDraft = card.title
            return
        }
        if !store.updateTicket(card, title: trimmed, details: card.details,
                               tags: card.tags) {
            titleDraft = card.title
        }
    }
}

// MARK: - Thread (ticket + conversation)

struct ThreadTab: View {
    @Environment(AppState.self) private var appState
    let card: Card
    let store: BoardStore
    @State private var draft = ""
    @State private var digest = CardThread.HistoryDigest()
    @State private var entries: [ThreadEntry] = []
    /// Reloads can overlap (turn end and process end bump within a frame);
    /// a slower, older read must not overwrite a newer one.
    @State private var latestLoad = 0

    private var liveState: SessionCoordinator.LiveState? {
        appState.coordinator.live[card.id]
    }

    /// Reading `card.events` / `card.testRuns` here is what keeps the thread
    /// live: every activity row is appended through the observed arrays.
    /// Cheap fingerprints drive the merge so it runs once per real change,
    /// not on every keystroke or streamed delta.
    private var eventCount: Int { card.events.count }
    private var testRunFingerprint: String {
        card.testRuns.map {
            "\($0.id.uuidString)#\($0.statusRaw)#\($0.summary.count)"
        }.joined()
    }

    private func refreshEntries() {
        entries = CardThread.entries(
            digest: digest,
            events: card.events.map(ActivityRow.init),
            testRuns: card.testRuns.map(TestRunSummary.init),
            live: liveState?.transcript ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.s300) {
                        TicketBody(card: card, store: store)
                            .padding(.bottom, DS.Space.s200)
                        ForEach(entries) { entry in
                            ThreadRow(entry: entry)
                        }
                        if let streaming = liveState?.streamingText,
                           !streaming.isEmpty {
                            MarkdownText(streaming)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(DS.Space.s400)
                    .frame(maxWidth: DS.Layout.transcriptMeasure)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: entries.count) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: liveState?.streamingText) {
                    proxy.scrollTo("bottom", anchor: .bottom)
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
                conflictBanner
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
        .task(id: card.id) {
            refreshEntries()
            await reloadHistory()
        }
        .onChange(of: liveState?.historyGeneration) {
            Task { await reloadHistory() }
        }
        .onChange(of: digest) { refreshEntries() }
        .onChange(of: eventCount) { refreshEntries() }
        .onChange(of: testRunFingerprint) { refreshEntries() }
        .onChange(of: liveState?.transcript) { refreshEntries() }
    }

    private var conflictBanner: some View {
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
        case .backlog: "Comment — ask Claude about this ticket, or press Plan…"
        case .done: "Comment to continue (the card returns to In Progress)…"
        default: "Comment — Claude replies in this thread…"
        }
    }

    private func send() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        draft = ""
        if card.column == .done {
            // Continuing a Done card flies it back (spec 04 §2.2); the
            // message itself resumes the session.
            store.reopenForChat(card)
        }
        Task { await appState.coordinator.sendChat(message, to: card) }
    }

    private func reloadHistory() async {
        let locators = card.sessions
            .filter { $0.role == .primary }
            .map(SessionLocator.init)
        latestLoad += 1
        let token = latestLoad
        guard !locators.isEmpty else {
            digest = CardThread.HistoryDigest()
            return
        }
        let loaded = await CardThreadLoader.digest(for: locators)
        guard token == latestLoad else { return }   // a newer read landed
        digest = loaded
    }
}

/// The ticket body — description and tags, editable in place.
struct TicketBody: View {
    let card: Card
    let store: BoardStore
    @State private var editing = false
    @State private var detailsDraft = ""
    @State private var selectedTags: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s300) {
            HStack {
                Text("DESCRIPTION")
                    .font(DS.TypeStyle.columnHeader)
                    .kerning(0.8)
                    .foregroundStyle(DS.Color.Text.tertiary)
                Spacer()
                Button(editing ? "Cancel" : "Edit") {
                    if editing {
                        editing = false
                    } else {
                        detailsDraft = card.details
                        selectedTags = Set(card.tags.map(\.id))
                        editing = true
                    }
                }
                .buttonStyle(.plain)
                .font(DS.TypeStyle.cardMeta)
                .foregroundStyle(DS.Color.Accent.text)
            }
            if editing {
                TextEditor(text: $detailsDraft)
                    .font(DS.TypeStyle.chatBody)
                    .frame(minHeight: 120)
                    .padding(DS.Space.s100)
                    .background(DS.Color.Surface.sunken,
                                in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                tagPicker
                HStack {
                    Spacer()
                    Button("Save") {
                        let tags = store.project.tags.filter {
                            selectedTags.contains($0.id)
                        }
                        store.updateTicket(card, title: card.title,
                                           details: detailsDraft, tags: tags)
                        editing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                if card.details.isEmpty {
                    Text("No description yet — add context and acceptance "
                         + "criteria so Claude plans from the right brief.")
                        .font(DS.TypeStyle.chatBody)
                        .foregroundStyle(DS.Color.Text.tertiary)
                } else {
                    MarkdownText(card.details)
                }
                if !card.tags.isEmpty {
                    HStack(spacing: DS.Space.s100) {
                        ForEach(card.tags) { TagChip(tag: $0) }
                    }
                }
            }
        }
        .padding(DS.Space.s400)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.Surface.raised,
                    in: RoundedRectangle(cornerRadius: DS.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
            .stroke(DS.Color.Border.subtle, lineWidth: 1))
    }

    private var tagPicker: some View {
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
    }
}

/// One row of the thread: user comment, Claude reply, tool call, activity
/// line, test verdict, or notice.
struct ThreadRow: View {
    let entry: ThreadEntry

    var body: some View {
        switch entry.kind {
        case .user(let text):
            Text(text)
                .font(DS.TypeStyle.chatBody)
                .foregroundStyle(DS.Color.Text.primary)
                .textSelection(.enabled)
                .padding(DS.Space.s300)
                .background(DS.Color.Accent.tint,
                            in: RoundedRectangle(cornerRadius: DS.Radius.card))
                .opacity(entry.isPending ? 0.7 : 1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant(let text):
            VStack(alignment: .leading, spacing: DS.Space.s200) {
                HStack(spacing: DS.Space.s200) {
                    Image(systemName: DS.Icon.sparkles)
                        .foregroundStyle(DS.Color.Accent.text)
                    Text("Claude")
                        .font(DS.TypeStyle.cardMeta.weight(.medium))
                        .foregroundStyle(DS.Color.Text.secondary)
                    if let at = entry.at {
                        Text(at, style: .relative)
                            .font(DS.TypeStyle.timestamp)
                            .foregroundStyle(DS.Color.Text.tertiary)
                    }
                }
                MarkdownText(text)
                Divider().overlay(DS.Color.Border.subtle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let name, let detail):
            ToolRow(name: name, detail: detail)
        case .system(let kind, let summary):
            HStack(spacing: DS.Space.s200) {
                Image(systemName: Self.icon(for: kind))
                    .foregroundStyle(Self.tint(for: kind))
                Text(summary)
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Color.Text.secondary)
                if let at = entry.at {
                    Text(at, style: .time)
                        .font(DS.TypeStyle.timestamp)
                        .foregroundStyle(DS.Color.Text.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, DS.Space.s200)
            .accessibilityElement(children: .combine)
        case .testRun(let run):
            TestRunRow(run: run)
                .padding(DS.Space.s300)
                .background(DS.Color.Surface.raised,
                            in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        case .notice(let text):
            Label(text, systemImage: "info.circle")
                .font(DS.TypeStyle.cardMeta)
                .foregroundStyle(DS.Color.Text.tertiary)
        }
    }

    static func icon(for kind: EventKind) -> String {
        switch kind {
        case .cardCreated: DS.Icon.newTicket
        case .columnChanged: DS.Icon.arrowUp
        case .agentStarted: DS.Icon.sparkles
        case .agentFinished: DS.Icon.finished
        case .agentNeedsInput: DS.Icon.awaitingPermission
        case .toolUse: DS.Icon.terminal
        case .testRunFinished: DS.Icon.testing
        case .prOpened: DS.Icon.pullRequest
        case .prMerged, .merged: DS.Icon.commit
        case .deploymentReady: DS.Icon.deployReady
        case .userNote, .ticketEdited: "pencil"
        }
    }

    static func tint(for kind: EventKind) -> Color {
        switch kind {
        case .agentNeedsInput: DS.Status.caution.text
        case .agentFinished, .prMerged, .merged: DS.Status.success.text
        case .agentStarted: DS.Color.Accent.text
        default: DS.Color.Text.tertiary
        }
    }
}

/// Inline markdown (bold, code, links) with whitespace preserved — the
/// transcript is prose, not a rendered document (spec 03 §7).
struct MarkdownText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(attributed)
            .font(DS.TypeStyle.chatBody)
            .lineSpacing(DS.TypeStyle.chatBodyLineSpacing)
            .foregroundStyle(DS.Color.Text.primary)
            .textSelection(.enabled)
    }

    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
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
                    MarkdownText(plan)
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

// MARK: - Tests

struct TestsTab: View {
    @Environment(AppState.self) private var appState
    let card: Card

    var body: some View {
        VStack(spacing: 0) {
            if card.testRuns.isEmpty {
                ContentUnavailableView {
                    Label("No test runs yet", systemImage: DS.Icon.testing)
                } description: {
                    Text("Agent tests verify the work against the ticket's "
                         + "acceptance criteria without fixing anything.")
                } actions: {
                    runButton
                }
            } else {
                List(card.testRuns.sorted { $0.startedAt > $1.startedAt }
                        .map(TestRunSummary.init)) { run in
                    TestRunRow(run: run)
                }
                .scrollContentBackground(.hidden)
                HStack {
                    Spacer()
                    runButton
                }
                .padding(DS.Space.s300)
            }
        }
        .background(DS.Color.Surface.sunken)
    }

    private var runButton: some View {
        Button("Run agent tests") {
            Task { await appState.coordinator.startAgentTests(for: card) }
        }
        .disabled(card.subState.pinsCard)
    }
}

struct TestRunRow: View {
    let run: TestRunSummary

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s200) {
            HStack(spacing: DS.Space.s200) {
                Image(systemName: icon)
                    .foregroundStyle(tint.text)
                Text(title)
                    .font(DS.TypeStyle.cardTitle)
                    .foregroundStyle(DS.Color.Text.primary)
                Spacer()
                Text(run.startedAt, style: .relative)
                    .font(DS.TypeStyle.timestamp)
                    .foregroundStyle(DS.Color.Text.tertiary)
            }
            if !run.summary.isEmpty {
                Text(run.summary)
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Color.Text.secondary)
            }
            ForEach(Array(run.failures.enumerated()), id: \.offset) { _, failure in
                VStack(alignment: .leading, spacing: DS.Space.s050) {
                    Text(failure.title)
                        .font(DS.TypeStyle.cardMeta.weight(.medium))
                        .foregroundStyle(DS.Status.danger.text)
                    if !failure.detail.isEmpty {
                        Text(failure.detail)
                            .font(DS.TypeStyle.cardMeta)
                            .foregroundStyle(DS.Color.Text.secondary)
                    }
                }
                .padding(DS.Space.s200)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Status.danger.tint, in: RoundedRectangle(
                    cornerRadius: DS.Radius.xs))
            }
        }
        .padding(.vertical, DS.Space.s100)
    }

    private var icon: String {
        switch run.status {
        case .running: DS.Icon.deployBuilding
        case .passed: DS.Icon.done
        case .failed: DS.Icon.error
        case .aborted: DS.Icon.error
        }
    }

    private var tint: DS.StatusColor {
        switch run.status {
        case .running: DS.Status.running
        case .passed: DS.Status.success
        case .failed, .aborted: DS.Status.danger
        }
    }

    private var title: String {
        switch run.status {
        case .running: "Agent tests running…"
        case .passed: "Agent tests passed"
        case .failed: run.verdict == .manualPass ? "Manual pass" : "Agent tests failed"
        case .aborted: "Agent tests aborted"
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
                Image(systemName: ThreadRow.icon(for: event.kind))
                    .foregroundStyle(ThreadRow.tint(for: event.kind))
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
