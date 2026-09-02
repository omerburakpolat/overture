import SwiftUI
import UniformTypeIdentifiers
import OvertureDesign
import OvertureKit

/// Column → design tokens (single hue ownership, spec 03 §3.4).
extension Column {
    var status: DS.StatusColor {
        switch self {
        case .backlog: DS.Status.neutral
        case .plan: DS.Status.plan
        case .inProgress: DS.Status.running
        case .testing: DS.Status.testing
        case .review: DS.Status.review
        case .done: DS.Status.success
        }
    }

    var icon: String {
        switch self {
        case .backlog: DS.Icon.backlog
        case .plan: DS.Icon.plan
        case .inProgress: DS.Icon.inProgress
        case .testing: DS.Icon.testing
        case .review: DS.Icon.review
        case .done: DS.Icon.done
        }
    }

    var title: String {
        switch self {
        case .backlog: "Backlog"
        case .plan: "Plan"
        case .inProgress: "In Progress"
        case .testing: "Testing"
        case .review: "Review"
        case .done: "Done"
        }
    }
}

struct BoardView: View {
    @Environment(AppState.self) private var appState
    @State var store: BoardStore
    @State private var selectedCard: Card?
    @State private var showComposer = false

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: DS.Layout.columnGap) {
                ForEach(Column.allCases, id: \.self) { column in
                    ColumnView(store: store, column: column,
                               selectedCard: $selectedCard)
                }
            }
            .padding(DS.Layout.boardMargin)
        }
        .background(DS.Color.Surface.canvas)
        .navigationTitle(store.project.name)
        .toolbar {
            Button {
                showComposer = true
            } label: {
                Label("New Ticket", systemImage: DS.Icon.newTicket)
            }
            .keyboardShortcut("n", modifiers: .command)
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
                    .padding(.bottom, DS.Space.s600)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(DS.Motion.Spring.entrance, value: store.toast)
    }
}

struct ColumnView: View {
    @Environment(AppState.self) private var appState
    let store: BoardStore
    let column: Column
    @Binding var selectedCard: Card?
    @State private var isDropTarget = false

    var body: some View {
        let cards = store.cards(in: column)
        VStack(alignment: .leading, spacing: DS.Space.s200) {
            header(count: cards.count)
            ScrollView {
                LazyVStack(spacing: DS.Layout.cardGap) {
                    ForEach(cards) { card in
                        CardView(card: card)
                            .onTapGesture { selectedCard = card }
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
                    style: StrokeStyle(lineWidth: 1,
                                       dash: isDropTarget ? [6, 4] : [])))
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
                .kerning(0.8)
                .foregroundStyle(column.status.text)
            Spacer()
            Text("\(count)")
                .font(DS.TypeStyle.badgeLabel)
                .padding(.horizontal, DS.Space.s200)
                .padding(.vertical, DS.Space.s050)
                .background(column.status.tint, in: Capsule())
                .foregroundStyle(column.status.text)
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
                    .fill(subStateColor.dot)
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
                Text(card.title)
                    .font(DS.TypeStyle.cardTitle)
                    .foregroundStyle(DS.Color.Text.primary)
                    .lineLimit(2)
            }

            contextLine

            footer
        }
        .padding(DS.Layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: DS.Layout.cardMinHeight)
        .background(DS.Color.Surface.raised,
                    in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
            .stroke(needsInput ? DS.Status.caution.text.opacity(0.6)
                               : DS.Color.Border.subtle, lineWidth: 1))
        .elevation(.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(card.title), \(card.column.title), \(card.subState.rawValue)")
    }

    private var needsInput: Bool {
        guard let liveState else { return false }
        return !liveState.pendingPermissions.isEmpty
            || liveState.planApproval != nil
    }

    private var subStateColor: DS.StatusColor {
        switch card.subState {
        case .running, .testingRunning: DS.Status.running
        case .needsInput, .awaitingApproval: DS.Status.caution
        case .error, .mergeConflict, .testsFailed: DS.Status.danger
        case .queued, .interrupted: DS.Status.neutral
        default: card.column.status
        }
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
                Text(costLabel)
                    .font(DS.TypeStyle.timestamp)
                    .foregroundStyle(DS.Color.Text.tertiary)
            }
        }
    }

    private var costLabel: String {
        // Tokens primary, dollars secondary-estimate (resolution #13).
        if appState.services.authStatus?.isSubscription == false,
           card.totalCostUSD > 0 {
            return String(format: "$%.2f", card.totalCostUSD)
        }
        return String(format: "~$%.2f", card.totalCostUSD)
    }
}

struct TagChip: View {
    let tag: OvertureKit.Tag

    var body: some View {
        let color = DS.Tags.color(for: tag.colorToken)
        Text(tag.name)
            .font(DS.TypeStyle.badgeLabel)
            .foregroundStyle(color.text)
            .padding(.horizontal, DS.Space.s200)
            .frame(height: 20)
            .background(color.background, in: Capsule())
    }
}
