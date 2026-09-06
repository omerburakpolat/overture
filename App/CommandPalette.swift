import SwiftUI
import OvertureDesign
import OvertureKit

/// ⌘K command field (spec 03 §7): floating glass capsule over a dimmed
/// board. Scope prefixes: `@` projects, `#` cards; plain text searches both.
struct CommandPalette: View {
    @Environment(AppState.self) private var appState
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var selection = 0

    struct Result: Identifiable {
        enum Kind {
            case project(Project)
            case card(Card)
        }
        let id: UUID
        let kind: Kind
        let title: String
        let subtitle: String
        let icon: String
    }

    var body: some View {
        VStack(spacing: DS.Space.s200) {
            HStack(spacing: DS.Space.s300) {
                Image(systemName: DS.Icon.search)
                    .foregroundStyle(DS.Color.Text.tertiary)
                TextField("Jump to a card or project…  (@ projects, # cards)",
                          text: $query)
                    .textFieldStyle(.plain)
                    .font(DS.TypeStyle.commandField)
                    .focused($focused)
                    .onSubmit { activate(results[safe: selection]) }
                    .onKeyPress(.downArrow) {
                        selection = min(selection + 1,
                                        max(results.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        selection = max(selection - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        appState.showCommandPalette = false
                        return .handled
                    }
            }
            .padding(.horizontal, DS.Space.s400)
            .frame(height: DS.Layout.commandFieldHeight)
            .glassOrOpaque(in: Capsule())

            if !results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) {
                        index, result in
                        Button {
                            activate(result)
                        } label: {
                            HStack(spacing: DS.Space.s300) {
                                Image(systemName: result.icon)
                                    .foregroundStyle(DS.Color.Text.secondary)
                                    .frame(width: DS.Layout.iconColumnWidth)
                                Text(result.title)
                                    .font(DS.TypeStyle.cardTitle)
                                    .foregroundStyle(DS.Color.Text.primary)
                                    .lineLimit(1)
                                Spacer()
                                Text(result.subtitle)
                                    .font(DS.TypeStyle.timestamp)
                                    .foregroundStyle(DS.Color.Text.tertiary)
                            }
                            .padding(.horizontal, DS.Space.s400)
                            .frame(height: DS.Layout.menuRowHeight)
                            .background(index == selection
                                ? AnyShapeStyle(DS.Color.Accent.tint)
                                : AnyShapeStyle(.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(
                            index == selection ? .isSelected : [])
                    }
                }
                .padding(.vertical, DS.Space.s100)
                .background(DS.Color.Surface.overlay, in: RoundedRectangle(
                    cornerRadius: DS.Radius.panel))
                .elevation(.overlay)
            }
        }
        .frame(width: DS.Layout.commandFieldWidth)
        .onAppear { focused = true }
        .onChange(of: query) { selection = 0 }
    }

    private var results: [Result] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var scope: Character?
        var needle = trimmed.lowercased()
        if let first = trimmed.first, "@#".contains(first) {
            scope = first
            needle = trimmed.dropFirst()
                .trimmingCharacters(in: .whitespaces).lowercased()
        }

        var found: [Result] = []
        if scope != "#" {
            found += appState.projectsStore.projects
                .filter { needle.isEmpty
                    || $0.name.lowercased().contains(needle) }
                .prefix(4)
                .map { Result(id: $0.id, kind: .project($0), title: $0.name,
                              subtitle: "Project", icon: DS.Icon.project) }
        }
        if scope != "@" {
            let cards = appState.projectsStore.projects
                .flatMap(\.cards)
                .filter { $0.archivedAt == nil && (needle.isEmpty
                    || $0.title.lowercased().contains(needle)) }
                .sorted { ($0.lastActivityAt ?? $0.movedAt)
                    > ($1.lastActivityAt ?? $1.movedAt) }
                .prefix(6)
            found += cards.map { card in
                Result(id: card.id, kind: .card(card), title: card.title,
                       subtitle: "\(card.project?.name ?? "") · "
                           + card.column.title,
                       icon: card.column.icon)
            }
        }
        return found
    }

    private func activate(_ result: Result?) {
        guard let result else { return }
        appState.showCommandPalette = false
        switch result.kind {
        case .project(let project):
            appState.navigationPath = NavigationPath()
            appState.navigationPath.append(project.id)
        case .card(let card):
            appState.focusCard(card.id)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
