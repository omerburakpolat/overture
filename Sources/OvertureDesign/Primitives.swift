import AppKit
import SwiftUI

// Primitive tier: raw values transcribed from docs/specs/03-design-system.md
// §3. Internal — feature code uses the semantic tier only. Hex constants live
// here so ContrastTests can recompute WCAG ratios from the same source of
// truth the colors are built from.

/// One light/dark hex pairing (with optional high-contrast overrides).
struct HexPair: Sendable, Equatable {
    var light: UInt32
    var dark: UInt32
    var lightHC: UInt32?
    var darkHC: UInt32?

    init(_ light: UInt32, _ dark: UInt32,
         lightHC: UInt32? = nil, darkHC: UInt32? = nil) {
        self.light = light
        self.dark = dark
        self.lightHC = lightHC
        self.darkHC = darkHC
    }
}

enum Palette {
    // §3.2 semantic surfaces / text / borders (values from the ink ramp §3.1).
    static let surfaceCanvas = HexPair(0xF7F7F9, 0x17171B)
    static let surfaceSunken = HexPair(0xF1F1F4, 0x1D1D22)
    static let surfaceRaised = HexPair(0xFCFCFD, 0x26262C)
    static let surfaceOverlay = HexPair(0xFFFFFF, 0x2E2E35)

    static let textPrimary = HexPair(0x232328, 0xECECF1)
    static let textSecondary = HexPair(0x50505A, 0xB3B3BC)
    // HC: tertiary deepens to the secondary values (§8.4).
    static let textTertiary = HexPair(0x6C6C76, 0x94949D,
                                      lightHC: 0x50505A, darkHC: 0xB3B3BC)
    static let textOnAccent = HexPair(0xFFFFFF, 0xFFFFFF)

    // HC: borders shift one ramp step (§8.4).
    static let borderSubtle = HexPair(0xE8E8EC, 0x33333A,
                                      lightHC: 0xC9C9D0, darkHC: 0x4F4F58)
    static let borderStrong = HexPair(0xC9C9D0, 0x45454D)
    static let borderControl = HexPair(0x8A8A93, 0x7A7A83)
    static let focusRing = HexPair(0x4E4BE4, 0x8886FF)

    // §3.3 accent — "Baton Indigo".
    static let accentText = HexPair(0x4E4BE4, 0x8886FF)
    static let accentFill = HexPair(0x4E4BE4, 0x5C5AEE)
    static let accentFillHover = HexPair(0x4340C9, 0x6D6BFA)
    static let accentFillPressed = HexPair(0x3A38B0, 0x4F4DDB)

    // §3.4 functional status palette — .text light/dark. The solid .fill
    // uses the light value with white text (light mode); dark solid badges
    // render tint + .text instead (glass eats contrast there).
    static let statusText: [String: HexPair] = [
        "neutral": HexPair(0x63636D, 0xA2A2AB),
        "plan": HexPair(0x7434BE, 0xC79BF2),
        "running": HexPair(0x2257CE, 0x7FA9F9),
        "testing": HexPair(0x0A6E63, 0x3FC3B2),
        "review": HexPair(0xBE2F5C, 0xF387A6),
        "caution": HexPair(0x8A5A00, 0xE3B34F),
        "success": HexPair(0x1B7038, 0x5BC97E),
        "danger": HexPair(0xC42B24, 0xF2766F),
    ]

    // §3.5 tag palette — (background, text) per mode. Token names are the
    // persisted `Tag.colorToken` strings and live forever.
    struct TagPair: Sendable, Equatable {
        var background: HexPair
        var text: HexPair
    }

    static let tags: [String: TagPair] = [
        "tag.red": .init(background: HexPair(0xFBE3E1, 0x43201E),
                         text: HexPair(0xA02C23, 0xFCA9A2)),
        "tag.orange": .init(background: HexPair(0xFCE8DB, 0x3F2818),
                            text: HexPair(0x96430A, 0xF5B98A)),
        "tag.amber": .init(background: HexPair(0xF9EDCF, 0x3B2E12),
                           text: HexPair(0x7A5304, 0xE9C979)),
        "tag.green": .init(background: HexPair(0xDEF2E2, 0x16321F),
                           text: HexPair(0x1D6B37, 0x94DFA9)),
        "tag.teal": .init(background: HexPair(0xD7F1ED, 0x103230),
                          text: HexPair(0x0B615B, 0x7BD9CF)),
        "tag.cyan": .init(background: HexPair(0xDBEFF9, 0x12303C),
                          text: HexPair(0x12607F, 0x8CCDE8)),
        "tag.blue": .init(background: HexPair(0xE0EAFB, 0x1B2A47),
                          text: HexPair(0x2350B8, 0xA6C4F7)),
        "tag.indigo": .init(background: HexPair(0xE6E5FB, 0x26254B),
                            text: HexPair(0x4340C9, 0xB7B5F9)),
        "tag.purple": .init(background: HexPair(0xEFE4FA, 0x2E2040),
                            text: HexPair(0x6D2FA8, 0xCFAAF2)),
        "tag.pink": .init(background: HexPair(0xFAE1EC, 0x3C1E2C),
                          text: HexPair(0xA82762, 0xF0A3C4)),
        "tag.gray": .init(background: HexPair(0xEAEAEE, 0x2C2C33),
                          text: HexPair(0x48484F, 0xC6C6CE)),
    ]

    // §3.4 diff line backgrounds (text stays text.primary on both).
    static let diffAdded = HexPair(0xE4F5E7, 0x15301D)
    static let diffDeleted = HexPair(0xFBE7E5, 0x3A1D1A)
}

// MARK: - Dynamic color construction

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    /// Appearance-resolving color. Matches over ALL FOUR appearance names —
    /// a two-name bestMatch normalizes high-contrast away (resolution #24).
    init(_ pair: HexPair, alpha: CGFloat = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let name = appearance.bestMatch(from: [
                .aqua, .darkAqua,
                .accessibilityHighContrastAqua,
                .accessibilityHighContrastDarkAqua,
            ])
            switch name {
            case .accessibilityHighContrastAqua:
                return NSColor(hex: pair.lightHC ?? pair.light, alpha: alpha)
            case .accessibilityHighContrastDarkAqua:
                return NSColor(hex: pair.darkHC ?? pair.dark, alpha: alpha)
            case .darkAqua:
                return NSColor(hex: pair.dark, alpha: alpha)
            default:
                return NSColor(hex: pair.light, alpha: alpha)
            }
        })
    }
}
