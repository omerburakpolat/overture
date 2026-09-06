import SwiftUI
import UniformTypeIdentifiers
import OvertureDesign
import OvertureKit

struct BoardView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.overtureTheme) private var theme
    @State var store: BoardStore
    @State private var selectedCard: Card?
    @State private var showComposer = false
    @State private var showSettings = false
    @Namespace private var boardSpace

    /// Card→column layout identity; drives the auto-move/fly-back travel
    /// (matched geometry animates the position change; Reduce Motion swaps
    /// it for a plain crossfade per spec 03 §6.4).
    private var layoutFingerprint: String {
        store.project.cards
            .map { "\($0.id.uuidString)#\($0.columnRaw)" }
            .sorted().joined()
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: DS.Layout.columnGap) {
                ForEach(Column.allCases, id: \.self) { column in
                    ColumnView(store: store, column: column,
                               selectedCard: $selectedCard,
                               boardSpace: boardSpace)
                }
            }
            .padding(DS.Layout.boardMargin)
            .animation(theme.reduceMotion ? DS.Motion.fade
                                          : DS.Motion.Spring.flight,
                       value: layoutFingerprint)
        }
        .background(DS.Color.Surface.canvas)
        .task(id: layoutFingerprint) {
            await store.refreshDerivedGitState()
        }
        .onChange(of: appState.pendingCardFocus) {
            guard let focusID = appState.pendingCardFocus,
                  let card = store.project.cards.first(
                    where: { $0.id == focusID }) else { return }
            selectedCard = card
            appState.pendingCardFocus = nil
        }
        .navigationTitle(store.project.name)
        .toolbar {
            Button {
                showSettings = true
            } label: {
                Label("Project Settings", systemImage: DS.Icon.settings)
            }
            Button {
                showComposer = true
            } label: {
                Label("New Ticket", systemImage: DS.Icon.newTicket)
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        .sheet(isPresented: $showSettings) {
            ProjectSettingsSheet(project: store.project)
        }
        .sheet(isPresented: $showComposer) {
            TicketComposer(store: store)
        }
        .sheet(item: $selectedCard) { card in
            CardDetailView(card: card, store: store)
        }
        .sheet(item: Binding(get: { store.mergeCandidate },
                             set: { store.mergeCandidate = $0 })) { card in
            MergeSheet(card: card, store: store)
        }
        .toastOverlay(store.toast)
    }
}

struct ColumnView: View {
    @Environment(AppState.self) private var appState
    let store: BoardStore
    let column: Column
    @Binding var selectedCard: Card?
    let boardSpace: Namespace.ID
    @State private var isDropTarget = false

    var body: some View {
        let cards = store.cards(in: column)
        VStack(alignment: .leading, spacing: DS.Space.s200) {
            header(count: cards.count)
            ScrollView {
                LazyVStack(spacing: DS.Layout.cardGap) {
                    ForEach(cards) { card in
                        CardView(card: card,
                                 overlaps: store.overlaps[card.id] ?? []) {
                            selectedCard = card
                        }
                        .matchedGeometryEffect(id: card.id, in: boardSpace)
                        .draggable(card.id.uuidString)
                        .contextMenu { cardMenu(card) }
                    }
                }
                .padding(DS.Layout.columnInnerPadding)
            }
        }
        .frame(width: DS.Layout.columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Color.Surface.sunken,
                    in: RoundedRectangle(cornerRadius: DS.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
            .stroke(isDropTarget ? column.status.text : DS.Color.Border.subtle,
                    style: StrokeStyle(lineWidth: DS.Stroke.hairline,
                                       dash: isDropTarget ? DS.Stroke.dash : [])))
        .dropDestination(for: String.self) { items, _ in
            guard let idString = items.first,
                  let cardID = UUID(uuidString: idString) else { return false }
            store.drop(cardID: cardID, into: column)
            return true
        } isTargeted: { isDropTarget = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(column.title) column, \(cards.count) cards")
    }

    private func header(count: Int) -> some View {
        HStack(spacing: DS.Space.s200) {
            Image(systemName: column.icon)
                .foregroundStyle(column.status.text)
            Text(column.title.uppercased())
                .font(DS.TypeStyle.columnHeader)
                .kerning(DS.TypeStyle.columnHeaderKerning)
                .foregroundStyle(column.status.text)
            Spacer()
            StatusBadge("\(count)", status: column.status)
                .accessibilityLabel("\(count) cards")
        }
        .frame(height: DS.Layout.columnHeaderHeight)
        .padding(.horizontal, DS.Space.s300)
    }

    @ViewBuilder private func cardMenu(_ card: Card) -> some View {
        if card.column == .review || card.column == .testing {
            Button("Approve → Done…") { store.requestApproval(card) }
        }
        if card.column == .done {
            Button("Reopen") { store.reopen(card) }
        }
        if card.subState.pinsCard {
            Button("Interrupt", role: .destructive) {
                Task { await appState.coordinator.interrupt(card: card) }
            }
        }
        Divider()
        Button("Archive", role: .destructive) { store.archive(card) }
    }
}

struct CardView: View {
    @Environment(AppState.self) private var appState
    let card: Card
    var overlaps: [String] = []
    /// Click, Return or the VoiceOver default action.
    var open: () -> Void = {}
    @FocusState private var focused: Bool

    private var liveState: SessionCoordinator.LiveState? {
        appState.coordinator.live[card.id]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s200) {
            if !card.tags.isEmpty {
                HStack(spacing: DS.Space.s100) {
                    ForEach(card.tags.prefix(3)) { tag in
                        TagChip(tag: tag)
                    }
                    if card.tags.count > 3 {
                        Text("+\(card.tags.count - 3)")
                            .font(DS.TypeStyle.badgeLabel)
                            .foregroundStyle(DS.Color.Text.tertiary)
                    }
                }
            }

            HStack(alignment: .top, spacing: DS.Space.s200) {
                Circle()
                    .fill(card.subState.status(in: card.column).dot)
                    .frame(width: DS.Layout.statusDot,
                           height: DS.Layout.statusDot)
                    .padding(.top, DS.Space.s100)
                Text(card.title)
                    .font(DS.TypeStyle.cardTitle)
                    .foregroundStyle(DS.Color.Text.primary)
                    .lineLimit(2)
            }

            contextLine

            if let first = overlaps.first {
                Label(overlaps.count == 1
                      ? "Overlaps “\(first)”"
                      : "Overlaps \(overlaps.count) cards",
                      systemImage: DS.Icon.conflict)
                    .font(DS.TypeStyle.timestamp)
                    .foregroundStyle(DS.Status.caution.text)
                    .lineLimit(1)
                    .help("These cards changed the same files — the second "
                          + "to merge will hit conflicts.")
            }

            footer
        }
        .padding(DS.Layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: DS.Layout.cardMinHeight)
        .background(DS.Color.Surface.raised,
                    in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
            .stroke(needsInput
                    ? DS.Status.caution.text.opacity(DS.Opacity.cautionRing)
                    : DS.Color.Border.subtle,
                    lineWidth: DS.Stroke.hairline))
        .elevation(.card)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        // Keyboard: Tab reaches the card and Return opens it, with the
        // design system's ring in place of the default focus effect.
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .overtureFocusRing(focused, radius: DS.Radius.card)
        .onKeyPress(.return) {
            open()
            return .handled
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(card.title), \(card.column.title), \(card.subState.displayName)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }

    private var needsInput: Bool {
        guard let liveState else { return false }
        return !liveState.pendingPermissions.isEmpty
            || liveState.planApproval != nil
    }

    @ViewBuilder private var contextLine: some View {
        if let approval = liveState?.planApproval, approval.planText != nil {
            Label("Plan ready for review", systemImage: DS.Icon.planReady)
                .font(DS.TypeStyle.cardMeta)
                .foregroundStyle(DS.Status.plan.text)
        } else if let pending = liveState?.pendingPermissions.first {
            Label("\(pending.toolName): \(pending.displayInput)",
                  systemImage: DS.Icon.awaitingPermission)
                .font(DS.TypeStyle.cardMeta)
                .foregroundStyle(DS.Status.caution.text)
                .lineLimit(1)
        } else if card.subState == .running,
                  let summary = card.lastAssistantSummary {
            Text(summary)
                .font(DS.TypeStyle.cardMeta)
                .foregroundStyle(DS.Color.Text.secondary)
                .lineLimit(1)
        } else if card.subState == .queued, let position = card.queuePosition {
            Text("Queued · #\(position + 1)")
                .font(DS.TypeStyle.cardMeta)
                .foregroundStyle(DS.Color.Text.tertiary)
        } else if card.column == .review {
            diffStat
        }
    }

    @ViewBuilder private var diffStat: some View {
        if let files = card.cachedFilesChanged {
            HStack(spacing: DS.Space.s200) {
                Text("\(files) file\(files == 1 ? "" : "s")")
                    .foregroundStyle(DS.Color.Text.secondary)
                Text("+\(card.cachedInsertions ?? 0)")
                    .foregroundStyle(DS.Status.success.text)
                Text("−\(card.cachedDeletions ?? 0)")
                    .foregroundStyle(DS.Status.danger.text)
            }
            .font(DS.TypeStyle.code)
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: DS.Space.s200) {
            if let branch = card.branchName {
                Label {
                    Text(branch.replacingOccurrences(of: "overture/", with: ""))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: DS.Icon.branch)
                }
                .font(DS.TypeStyle.timestamp)
                .foregroundStyle(DS.Color.Text.tertiary)
            }
            Spacer()
            if card.totalTokens > 0 || card.totalCostUSD > 0 {
                costText
                    .font(DS.TypeStyle.timestamp)
                    .foregroundStyle(DS.Color.Text.tertiary)
            }
        }
    }

    /// Tokens primary, dollars secondary-estimate (resolution #13): the
    /// figure is exact only for API-key billing, else a "~" estimate.
    private var costText: Text {
        let amount = Text(card.totalCostUSD,
                          format: .currency(code: "USD")
                              .precision(.fractionLength(2)))
        let exact = appState.services.authStatus?.isSubscription == false
            && card.totalCostUSD > 0
        return exact ? amount : Text("~") + amount
    }
}
