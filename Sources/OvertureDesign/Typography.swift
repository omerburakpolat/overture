import SwiftUI

public extension DS {
    /// Type roles (§4.2). All built from system text styles so Dynamic Type
    /// scales everything; SF Pro/SF Mono only — never a third face.
    /// Numerals that tick (counts, timers, costs) use `monospacedDigit`.
    enum TypeStyle {
        public static let screenTitle = Font.title.weight(.bold)
        public static let tileTitle = Font.title3.weight(.semibold)
        public static let tileSummary = Font.callout
        /// Uppercase, tracked +0.06em, colored by the column's status hue.
        public static let columnHeader = Font.subheadline.weight(.semibold)
        public static let cardTitle = Font.body.weight(.medium)
        public static let cardMeta = Font.subheadline
        /// Relaxed leading for transcript prose is applied via
        /// `chatBodyLineSpacing`.
        public static let chatBody = Font.body
        public static let chatBodyLineSpacing: CGFloat = 6  // 13 → 19 leading
        public static let code = Font.system(.callout, design: .monospaced)
        public static let diffLineNumber = Font.system(.caption,
                                                       design: .monospaced)
        public static let toolCallLabel = Font.callout.weight(.medium)
        public static let timestamp = Font.caption.monospacedDigit()
        public static let badgeLabel = Font.caption.weight(.semibold)
        public static let commandField = Font.title3
        public static let emptyStateTitle = Font.title3.weight(.semibold)
        public static let emptyStateBody = Font.callout
        public static let kbd = Font.system(.caption, design: .monospaced)
    }

    /// SF Symbols mapping (§9, with resolution #23's picks). One symbol per
    /// concept — status colors always pair with these.
    enum Icon {
        // Columns.
        public static let backlog = "tray"
        public static let plan = "map"
        public static let inProgress = "play.circle"
        public static let testing = "testtube.2"
        public static let review = "eye"
        public static let done = "checkmark.circle"
        // Agent & session states.
        public static let idle = "moon.zzz"
        public static let thinking = "ellipsis"
        public static let sparkles = "sparkles"
        public static let awaitingPermission = "hand.raised.fill"
        public static let error = "exclamationmark.triangle.fill"
        public static let finished = "checkmark.seal"
        public static let planReady = "map.fill"
        public static let continueChat = "arrow.uturn.backward.circle"
        // Git / deploy / actions.
        public static let branch = "arrow.triangle.branch"
        public static let commit = "smallcircle.filled.circle"
        public static let pullRequest = "arrow.triangle.merge"
        public static let conflict = "exclamationmark.arrow.triangle.2.circlepath"
        public static let deployReady = "checkmark.circle.fill"
        public static let deployBuilding = "arrow.triangle.2.circlepath"
        public static let deployFailed = "xmark.octagon.fill"
        public static let newTicket = "plus"
        public static let search = "magnifyingglass"
        public static let filter = "line.3.horizontal.decrease.circle"
        public static let tag = "tag"
        public static let settings = "gearshape"
        public static let terminal = "terminal"
        public static let chat = "text.bubble"
        public static let diff = "plus.forwardslash.minus"
        public static let preview = "macwindow.on.rectangle"
        public static let arrowUp = "arrow.up"
        public static let arrowDown = "arrow.down"
    }
}
