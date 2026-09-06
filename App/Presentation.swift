import SwiftUI
import OvertureDesign
import OvertureKit

// How domain state is presented: the one place that maps columns and
// sub-states to status hues and symbols (spec 03 §3.4 single hue ownership,
// §9 one symbol per concept), plus the small controls every screen shares.

// MARK: - Column and sub-state → tokens

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

    var title: String { displayName }
}

/// Sub-state → status hue and symbol (spec 03 §3.4 "state → token map").
/// A sub-state without a hue of its own borrows the column's.
extension CardSubState {
    var ownStatus: DS.StatusColor? {
        switch self {
        case .running, .testingRunning: DS.Status.running
        case .needsInput, .awaitingApproval: DS.Status.caution
        case .error, .mergeConflict, .testsFailed: DS.Status.danger
        case .queued, .interrupted: DS.Status.neutral
        case .idle, .drafting, .planning, .manual: nil
        }
    }

    func status(in column: Column) -> DS.StatusColor {
        ownStatus ?? column.status
    }

    func icon(in column: Column) -> String {
        switch self {
        case .running: DS.Icon.sparkles
        case .testingRunning, .testsFailed, .manual: DS.Icon.testing
        case .needsInput, .awaitingApproval: DS.Icon.awaitingPermission
        case .error: DS.Icon.error
        case .mergeConflict: DS.Icon.conflict
        case .queued, .interrupted: DS.Icon.idle
        case .planning: DS.Icon.plan
        case .drafting: DS.Icon.edit
        case .idle: column.icon
        }
    }
}

// MARK: - Badges and chips

/// The status badge (spec 03 §7): 20pt capsule, `status.tint` background,
/// `status.text` foreground, symbol + label — colour is never the only
/// channel. Without a symbol it is the count pill.
struct StatusBadge: View {
    let label: String
    var icon: String?
    let status: DS.StatusColor

    init(_ label: String, icon: String? = nil, status: DS.StatusColor) {
        self.label = label
        self.icon = icon
        self.status = status
    }

    var body: some View {
        Group {
            if let icon {
                Label(label, systemImage: icon)
            } else {
                Text(label).monospacedDigit()
            }
        }
        .font(DS.TypeStyle.badgeLabel)
        .foregroundStyle(status.text)
        .lineLimit(1)
        .padding(.horizontal, DS.Space.s200)
        .frame(height: DS.Layout.chipHeight)
        .background(status.tint, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Tag chip (spec 03 §3.5, §7): tinted background + strong text, 20pt
/// capsule. `selected` adds a checkmark so picker state does not depend on
/// colour or opacity alone.
struct TagChip: View {
    let tag: OvertureKit.Tag
    var selected = false

    var body: some View {
        let color = DS.Tags.color(for: tag.colorToken)
        HStack(spacing: DS.Space.s050) {
            if selected {
                Image(systemName: DS.Icon.selected)
            }
            Text(tag.name)
        }
        .font(DS.TypeStyle.badgeLabel)
        .foregroundStyle(color.text)
        .lineLimit(1)
        .padding(.horizontal, DS.Space.s200)
        .frame(height: DS.Layout.chipHeight)
        .background(color.background, in: Capsule())
    }
}

/// Toggleable tag chips, shared by the ticket body and the composer.
struct TagPicker: View {
    let tags: [OvertureKit.Tag]
    @Binding var selection: Set<UUID>

    var body: some View {
        HStack(spacing: DS.Space.s100) {
            ForEach(tags) { tag in
                let isSelected = selection.contains(tag.id)
                Button {
                    if isSelected {
                        selection.remove(tag.id)
                    } else {
                        selection.insert(tag.id)
                    }
                } label: {
                    TagChip(tag: tag, selected: isSelected)
                        .opacity(isSelected ? 1 : DS.Opacity.deselected)
                }
                .buttonStyle(.plain)
                .help(isSelected ? "Remove tag “\(tag.name)”"
                                 : "Add tag “\(tag.name)”")
                .accessibilityLabel(tag.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tags")
    }
}

// MARK: - Editable title

/// A title that reads as text and edits in place on click. It is never the
/// sheet's first key view, so opening a ticket cannot select-all the title
/// the way a bare `TextField` did.
struct EditableTitle: View {
    let title: String
    let onCommit: (String) -> Void
    @State private var editing = false
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("Title", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
                    .onAppear { focused = true }
                    // Focus loss is not delivered to a sheet being torn
                    // down; onDisappear is the backstop that still commits.
                    .onDisappear(perform: commit)
                    .onChange(of: focused) { if !focused { commit() } }
                    .overtureFocusRing(true, radius: DS.Radius.sm)
                    .accessibilityLabel("Ticket title")
            } else {
                HStack(spacing: DS.Space.s200) {
                    Text(title)
                        .lineLimit(2)
                    Image(systemName: DS.Icon.edit)
                        .font(DS.TypeStyle.cardMeta)
                        .foregroundStyle(DS.Color.Text.tertiary)
                        .opacity(hovering ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: begin)
                .onHover { hovering = $0 }
                .help("Click to rename")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Ticket title")
                .accessibilityValue(title)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: "Rename", begin)
            }
        }
        .font(DS.TypeStyle.screenTitle)
        .foregroundStyle(DS.Color.Text.primary)
        .animation(DS.Motion.fade, value: hovering)
    }

    private func begin() {
        draft = title
        editing = true
    }

    /// Idempotent: submit, focus loss and teardown can all arrive for one
    /// edit, and only the first one commits.
    private func commit() {
        guard editing else { return }
        editing = false
        onCommit(draft)
    }

    private func cancel() {
        editing = false
    }
}

// MARK: - Toast

/// The board/sheet toast (spec 03 §7): glass panel at the bottom, entrance
/// spring (fade under Reduce Motion), cleared by the store.
struct ToastOverlay: ViewModifier {
    @Environment(\.overtureTheme) private var theme
    let toast: BoardStore.Toast?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast.message)
                        .font(DS.TypeStyle.cardMeta)
                        .foregroundStyle(DS.Color.Text.primary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Space.s400)
                        .padding(.vertical, DS.Space.s300)
                        .frame(maxWidth: DS.Layout.toastMaxWidth)
                        .glassOrOpaque(in: RoundedRectangle(
                            cornerRadius: DS.Radius.panel))
                        .elevation(.overlay)
                        .padding(.bottom, DS.Space.s600)
                        .transition(theme.reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity))
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .animation(theme.reduceMotion ? DS.Motion.fade
                                          : DS.Motion.Spring.entrance,
                       value: toast)
    }
}

extension View {
    func toastOverlay(_ toast: BoardStore.Toast?) -> some View {
        modifier(ToastOverlay(toast: toast))
    }
}
