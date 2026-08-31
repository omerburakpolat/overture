import SwiftUI

/// The semantic tier — the only tier feature code touches (spec 03 §2).
/// "Tokens for everything" is enforced socially + by review: no raw hex,
/// no `Color(red:…)`, no `Font.system(size:)` outside this package.
public enum DS {
    // MARK: - Color

    public enum Color {
        public enum Surface {
            public static let canvas = SwiftUI.Color(Palette.surfaceCanvas)
            public static let sunken = SwiftUI.Color(Palette.surfaceSunken)
            public static let raised = SwiftUI.Color(Palette.surfaceRaised)
            public static let overlay = SwiftUI.Color(Palette.surfaceOverlay)
        }

        public enum Text {
            public static let primary = SwiftUI.Color(Palette.textPrimary)
            public static let secondary = SwiftUI.Color(Palette.textSecondary)
            public static let tertiary = SwiftUI.Color(Palette.textTertiary)
            /// Decorative only — never the sole information carrier.
            public static let disabled = SwiftUI.Color(Palette.textTertiary)
                .opacity(0.55)
            public static let onAccent = SwiftUI.Color(Palette.textOnAccent)
        }

        public enum Border {
            public static let subtle = SwiftUI.Color(Palette.borderSubtle)
            public static let strong = SwiftUI.Color(Palette.borderStrong)
            public static let control = SwiftUI.Color(Palette.borderControl)
        }

        public static let focusRing = SwiftUI.Color(Palette.focusRing)

        public enum Accent {
            public static let text = SwiftUI.Color(Palette.accentText)
            public static let fill = SwiftUI.Color(Palette.accentFill)
            public static let fillHover = SwiftUI.Color(Palette.accentFillHover)
            public static let fillPressed = SwiftUI.Color(Palette.accentFillPressed)
            /// Selection/hover wash (10% light / 14% dark, §3.3).
            public static let tint = SwiftUI.Color(
                HexPair(Palette.accentText.light, Palette.accentText.dark))
                .opacity(0.12)
        }

        public enum Diff {
            public static let addedBackground = SwiftUI.Color(Palette.diffAdded)
            public static let deletedBackground = SwiftUI.Color(Palette.diffDeleted)
        }
    }

    // MARK: - Status

    /// One functional status hue (§3.4): {text, fill, tint, dot}, single
    /// meaning per hue app-wide. Color is never the sole channel — every
    /// status pairs with `icon` and a label.
    public struct StatusColor: Sendable {
        public let text: SwiftUI.Color
        /// Solid badge fill — light mode pairs with `Text.onAccent`; dark
        /// solid badges render `tint` + `text` instead.
        public let fill: SwiftUI.Color
        /// 12%/16% alpha wash over surfaces.
        public let tint: SwiftUI.Color
        /// 6–8pt indicator dot (== text; ≥3:1 everywhere).
        public let dot: SwiftUI.Color
        public let icon: String

        init(_ key: String, icon: String) {
            let pair = Palette.statusText[key] ?? Palette.statusText["neutral"]!
            text = SwiftUI.Color(pair)
            fill = SwiftUI.Color(HexPair(pair.light, pair.light))
            tint = SwiftUI.Color(pair).opacity(0.14)
            dot = SwiftUI.Color(pair)
            self.icon = icon
        }
    }

    public enum Status {
        public static let neutral = StatusColor("neutral", icon: "tray")
        public static let plan = StatusColor("plan", icon: "map")
        public static let running = StatusColor("running", icon: "play.circle")
        public static let testing = StatusColor("testing", icon: "testtube.2")
        public static let review = StatusColor("review", icon: "eye")
        public static let caution = StatusColor("caution", icon: "hand.raised.fill")
        public static let success = StatusColor("success", icon: "checkmark.circle")
        public static let danger = StatusColor("danger", icon: "exclamationmark.triangle.fill")
    }

    // MARK: - Tags

    /// Chip pairing: tinted background + strong text (§3.5) — no
    /// white-on-saturated chips. Addressed by the persisted token name.
    public struct TagColor: Sendable {
        public let tokenName: String
        public let background: SwiftUI.Color
        public let text: SwiftUI.Color
    }

    public enum Tags {
        /// Stable palette order for pickers.
        public static let order = ["tag.red", "tag.orange", "tag.amber",
                                   "tag.green", "tag.teal", "tag.cyan",
                                   "tag.blue", "tag.indigo", "tag.purple",
                                   "tag.pink", "tag.gray"]

        /// Unknown token names degrade to gray — a future palette entry must
        /// never crash an old build.
        public static func color(for tokenName: String) -> TagColor {
            let pair = Palette.tags[tokenName] ?? Palette.tags["tag.gray"]!
            return TagColor(tokenName: tokenName,
                            background: SwiftUI.Color(pair.background),
                            text: SwiftUI.Color(pair.text))
        }

        public static var all: [TagColor] { order.map(color(for:)) }
    }
}
