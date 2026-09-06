import SwiftUI

public extension DS {
    /// 4pt grid (§5.1). Component-internal padding 100–400; siblings
    /// 200–300; sections 600; page margins 600.
    enum Space {
        public static let s050: CGFloat = 2
        public static let s100: CGFloat = 4
        public static let s200: CGFloat = 8
        public static let s300: CGFloat = 12
        public static let s400: CGFloat = 16
        public static let s500: CGFloat = 20
        public static let s600: CGFloat = 24
        public static let s800: CGFloat = 32
        public static let s1000: CGFloat = 40
        public static let s1200: CGFloat = 48
        public static let s1600: CGFloat = 64
    }

    /// Radius scale (§5.2). Nested corners stay concentric:
    /// inner = outer − padding.
    enum Radius {
        public static let xs: CGFloat = 4       // keycaps, badges, inline code
        public static let sm: CGFloat = 6       // chips, small buttons
        public static let md: CGFloat = 8       // buttons, inputs
        public static let card: CGFloat = 10    // kanban cards, chat bubbles
        public static let panel: CGFloat = 14   // column wells, banners
        public static let tile: CGFloat = 18    // project tiles, sheets
    }

    /// Shadow + border treatment per level (§5.3). Dark mode compensates
    /// weak shadows with a 1pt inner top highlight (white @ 6%).
    struct Elevation: Sendable {
        public var yOffset: CGFloat
        public var blur: CGFloat
        public var opacityLight: Double
        public var opacityDark: Double
        /// Whether the dark-mode top highlight applies.
        public var darkTopHighlight: Bool

        public static let flat = Elevation(yOffset: 0, blur: 0,
                                           opacityLight: 0, opacityDark: 0,
                                           darkTopHighlight: false)
        public static let card = Elevation(yOffset: 1, blur: 3,
                                           opacityLight: 0.08, opacityDark: 0.40,
                                           darkTopHighlight: true)
        public static let hover = Elevation(yOffset: 3, blur: 8,
                                            opacityLight: 0.10, opacityDark: 0.45,
                                            darkTopHighlight: true)
        public static let drag = Elevation(yOffset: 8, blur: 24,
                                           opacityLight: 0.14, opacityDark: 0.55,
                                           darkTopHighlight: true)
        public static let overlay = Elevation(yOffset: 12, blur: 32,
                                              opacityLight: 0.16, opacityDark: 0.60,
                                              darkTopHighlight: false)
        public static let modal = Elevation(yOffset: 20, blur: 48,
                                            opacityLight: 0.20, opacityDark: 0.65,
                                            darkTopHighlight: false)
    }

    /// Motion tokens (§6.2). Springs, not timed curves, for anything
    /// positional; every signature moment checks `Theme.reduceMotion`.
    enum Motion {
        public static let instant: Duration = .milliseconds(100)
        public static let fast: Duration = .milliseconds(150)
        public static let base: Duration = .milliseconds(200)
        public static let gentle: Duration = .milliseconds(300)
        public static let pulse: Duration = .milliseconds(2400)
        public static let shimmer: Duration = .milliseconds(1600)

        /// The Reduce Motion substitution for any positional spring (§6.4):
        /// a plain cross-fade at `duration.base`.
        public static let fade = Animation.easeInOut(duration: 0.2)

        public enum Spring {
            public static let snap = Animation.spring(response: 0.30,
                                                      dampingFraction: 0.90)
            public static let standard = Animation.spring(response: 0.38,
                                                          dampingFraction: 0.85)
            public static let entrance = Animation.spring(response: 0.45,
                                                          dampingFraction: 0.80)
            /// The Done→In Progress fly-back: one soft overshoot.
            public static let flight = Animation.spring(response: 0.55,
                                                        dampingFraction: 0.78)
        }
    }

    /// Layout metrics (§5.4).
    enum Layout {
        public static let columnWidth: CGFloat = 300
        public static let columnGap: CGFloat = 12
        public static let columnInnerPadding: CGFloat = 8
        public static let columnHeaderHeight: CGFloat = 36
        public static let cardPadding: CGFloat = 12
        public static let cardGap: CGFloat = 8
        public static let cardMinHeight: CGFloat = 68
        public static let tileMinWidth: CGFloat = 280
        public static let tileIdealWidth: CGFloat = 320
        public static let tileHeight: CGFloat = 168
        public static let tileGridGap: CGFloat = 16
        public static let pageMargin: CGFloat = 24
        public static let boardMargin: CGFloat = 20
        public static let detailMinWidth: CGFloat = 400
        public static let detailIdealWidth: CGFloat = 520
        public static let transcriptMeasure: CGFloat = 640
        public static let minimumHitTarget: CGFloat = 24
        public static let menuRowHeight: CGFloat = 28

        // Windows and sheets.
        public static let windowMinWidth: CGFloat = 960
        public static let windowMinHeight: CGFloat = 620
        public static let settingsWindowSize = CGSize(width: 480, height: 280)

        /// Sheet widths (§5.2 `radius.tile` surfaces): three fixed widths for
        /// the dialog-style sheets, and the resizable card detail sheet.
        public enum Sheet {
            public static let narrow: CGFloat = 480
            public static let medium: CGFloat = 520
            public static let wide: CGFloat = 560
            public static let detailMin = CGSize(width: 640, height: 520)
            public static let detailIdeal = CGSize(width: 760, height: 640)
        }

        /// ⌘K command field, 480×44 centered (§5.4).
        public static let commandFieldWidth: CGFloat = 480
        public static let commandFieldHeight: CGFloat = 44
        /// Toast max width (§7).
        public static let toastMaxWidth: CGFloat = 360

        // Small fixed parts of components (§7).
        /// 8pt status dot on cards and server indicators; 6pt for the tile's
        /// dirty-tree dot.
        public static let statusDot: CGFloat = 8
        public static let indicatorDot: CGFloat = 6
        /// Tag chips and status badges are 20pt tall.
        public static let chipHeight: CGFloat = 20
        /// Fixed-width leading symbol column in option rows and lists.
        public static let iconColumnWidth: CGFloat = 20
        public static let diffGutterWidth: CGFloat = 40
        public static let editorMinHeight: CGFloat = 120
        /// Inline plan preview / expanded tool output cap before inner scroll.
        public static let planPreviewMaxHeight: CGFloat = 240
        public static let consoleHeight: CGFloat = 120
        public static let menuMinWidth: CGFloat = 260
        public static let tileMaxWidth: CGFloat = 380
        /// User bubbles sit at ≤75% of the transcript measure (§7).
        public static let userBubbleMaxWidth: CGFloat = transcriptMeasure * 0.75
    }

    /// Stroke widths and patterns (§5.3, §7).
    enum Stroke {
        public static let hairline: CGFloat = 1
        /// The 2pt accent bar on the permission banner.
        public static let accentBar: CGFloat = 2
        /// Drop-target and "add" outlines.
        public static let dash: [CGFloat] = [6, 4]
    }

    /// Opacity steps for states that dim rather than recolor (§7).
    enum Opacity {
        /// A provisional row (sent, not yet echoed by the CLI).
        public static let pending: Double = 0.7
        /// An unselected chip in a picker.
        public static let deselected: Double = 0.45
        /// The caution ring around a card that needs input (§7 "at 60%").
        public static let cautionRing: Double = 0.6
        /// Content dimmed behind the ⌘K command field (§1.2 "dimmed 25%").
        public static let scrim: Double = 0.25
    }
}

public extension View {
    /// Applies an elevation level (shadow; dark top highlight is the
    /// surface's own job via overlay where it applies).
    func elevation(_ level: DS.Elevation) -> some View {
        shadow(color: .black.opacity(level.opacityLight),
               radius: level.blur / 2, x: 0, y: level.yOffset)
    }
}
