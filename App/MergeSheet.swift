import SwiftUI
import OvertureDesign
import OvertureKit

/// The Approve→Done sheet (spec 04 §9): strategy choice per execution mode,
/// inline errors, conflicts route back to Review with the conflict banner.
struct MergeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let card: Card
    let store: BoardStore
    @State private var working = false
    @State private var errorMessage: String?

    private var isWorktreeCard: Bool { card.branchName != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s400) {
            Label("Approve “\(card.title)”", systemImage: DS.Icon.done)
                .font(DS.TypeStyle.tileTitle)
                .foregroundStyle(DS.Color.Text.primary)
                .lineLimit(2)

            if let files = card.cachedFilesChanged {
                Text("\(files) file\(files == 1 ? "" : "s") changed · "
                     + "+\(card.cachedInsertions ?? 0) "
                     + "−\(card.cachedDeletions ?? 0)")
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Color.Text.secondary)
            }

            if isWorktreeCard {
                option(title: "Squash-merge into \(store.project.defaultBranch)",
                       detail: "Merge locally, delete the branch and worktree.",
                       icon: DS.Icon.branch, choice: .mergeLocally)
                option(title: "Open a pull request",
                       detail: "Push the branch and create a PR with gh. The "
                           + "branch survives until the PR merges.",
                       icon: DS.Icon.pullRequest, choice: .openPR)
                option(title: "Just mark Done",
                       detail: "No git action — branch and worktree stay.",
                       icon: DS.Icon.done, choice: .justMarkDone)
            } else {
                option(title: "Commit the changes",
                       detail: "Stage everything and commit with the card "
                           + "title.",
                       icon: DS.Icon.commit, choice: .commitSingleDir)
                option(title: "Leave uncommitted",
                       detail: "You own the commit. The Review diff becomes "
                           + "unavailable.",
                       icon: DS.Icon.branch, choice: .leaveUncommitted)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: DS.Icon.error)
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Status.danger.text)
                    .padding(DS.Space.s300)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Status.danger.tint, in: RoundedRectangle(
                        cornerRadius: DS.Radius.sm))
            }

            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(working)
            }
        }
        .padding(DS.Space.s600)
        .frame(width: 480)
        .background(DS.Color.Surface.overlay)
    }

    private func option(title: String, detail: String, icon: String,
                        choice: BoardStore.ApproveChoice) -> some View {
        Button {
            perform(choice)
        } label: {
            HStack(alignment: .top, spacing: DS.Space.s300) {
                Image(systemName: icon)
                    .foregroundStyle(DS.Color.Accent.text)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: DS.Space.s050) {
                    Text(title).font(DS.TypeStyle.cardTitle)
                        .foregroundStyle(DS.Color.Text.primary)
                    Text(detail).font(DS.TypeStyle.cardMeta)
                        .foregroundStyle(DS.Color.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(DS.Space.s300)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Color.Surface.raised, in: RoundedRectangle(
                cornerRadius: DS.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md)
                .stroke(DS.Color.Border.subtle, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(working)
    }

    private func perform(_ choice: BoardStore.ApproveChoice) {
        working = true
        errorMessage = nil
        Task {
            let failure = await store.approve(card, choice: choice)
            working = false
            if let failure {
                errorMessage = failure
            } else {
                dismiss()
            }
        }
    }
}
