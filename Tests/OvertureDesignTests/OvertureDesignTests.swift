import AppKit
import SwiftUI
import Testing
@testable import OvertureDesign

/// WCAG 2.x relative luminance + contrast ratio, recomputed from the same
/// hex constants the colors are built from. The palette can never silently
/// regress below AA — this suite IS the CI gate (spec 03 §10).
private func luminance(_ hex: UInt32) -> Double {
    func channel(_ value: UInt32) -> Double {
        let c = Double(value) / 255
        return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel((hex >> 16) & 0xFF)
        + 0.7152 * channel((hex >> 8) & 0xFF)
        + 0.0722 * channel(hex & 0xFF)
}

private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
    let (la, lb) = (luminance(a), luminance(b))
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

@Suite struct ContrastTests {
    @Test func bodyTextExceedsAAAOnAllSurfaces() {
        for surface in [Palette.surfaceCanvas, Palette.surfaceSunken,
                        Palette.surfaceRaised] {
            #expect(contrast(Palette.textPrimary.light, surface.light) >= 7)
            #expect(contrast(Palette.textPrimary.dark, surface.dark) >= 7)
            #expect(contrast(Palette.textSecondary.light, surface.light) >= 4.5)
            #expect(contrast(Palette.textSecondary.dark, surface.dark) >= 4.5)
        }
    }

    @Test func tertiaryTextMeetsAAOnCanvas() {
        #expect(contrast(Palette.textTertiary.light,
                         Palette.surfaceCanvas.light) >= 4.5)
        #expect(contrast(Palette.textTertiary.dark,
                         Palette.surfaceCanvas.dark) >= 4.5)
    }

    @Test(arguments: ["neutral", "plan", "running", "testing",
                      "review", "caution", "success", "danger"])
    func statusTextMeetsAA(key: String) throws {
        let pair = try #require(Palette.statusText[key])
        for surface in [Palette.surfaceCanvas, Palette.surfaceRaised] {
            #expect(contrast(pair.light, surface.light) >= 4.5,
                    "\(key) light on \(surface.light)")
            #expect(contrast(pair.dark, surface.dark) >= 4.5,
                    "\(key) dark on \(surface.dark)")
        }
    }

    @Test func statusFillCarriesWhiteTextInLight() {
        for (key, pair) in Palette.statusText where key != "neutral" {
            #expect(contrast(0xFFFFFF, pair.light) >= 4.5,
                    "white on \(key) fill")
        }
    }

    @Test(arguments: ["tag.red", "tag.orange", "tag.amber", "tag.green",
                      "tag.teal", "tag.cyan", "tag.blue", "tag.indigo",
                      "tag.purple", "tag.pink", "tag.gray"])
    func tagChipsMeetAA(token: String) throws {
        let tag = try #require(Palette.tags[token])
        #expect(contrast(tag.text.light, tag.background.light) >= 4.5,
                "\(token) light")
        #expect(contrast(tag.text.dark, tag.background.dark) >= 4.5,
                "\(token) dark")
    }

    @Test func focusRingMeetsNonTextMinimum() {
        #expect(contrast(Palette.focusRing.light,
                         Palette.surfaceCanvas.light) >= 3)
        #expect(contrast(Palette.focusRing.dark,
                         Palette.surfaceCanvas.dark) >= 3)
    }

    @Test func accentMeetsAA() {
        #expect(contrast(Palette.accentText.light,
                         Palette.surfaceRaised.light) >= 4.5)
        #expect(contrast(Palette.accentText.dark,
                         Palette.surfaceRaised.dark) >= 4.5)
        #expect(contrast(0xFFFFFF, Palette.accentFill.light) >= 4.5)
        #expect(contrast(0xFFFFFF, Palette.accentFill.dark) >= 4.5)
    }

    @Test func diffLineBackgroundsKeepPrimaryTextReadable() {
        #expect(contrast(Palette.textPrimary.light, Palette.diffAdded.light) >= 7)
        #expect(contrast(Palette.textPrimary.dark, Palette.diffAdded.dark) >= 7)
        #expect(contrast(Palette.textPrimary.light, Palette.diffDeleted.light) >= 7)
        #expect(contrast(Palette.textPrimary.dark, Palette.diffDeleted.dark) >= 7)
    }
}

@Suite struct TokenAPITests {
    @Test func tagLookupIsTotalAndStable() {
        // Token names are persisted in Tag.colorToken — they live forever.
        #expect(DS.Tags.order.count == 11)
        for name in DS.Tags.order {
            #expect(DS.Tags.color(for: name).tokenName == name)
        }
        // Unknown names degrade to gray, never crash.
        #expect(DS.Tags.color(for: "tag.future").tokenName == "tag.future")
    }

    /// Snapshot: semantic colors resolve to the documented hex per mode.
    /// A change here must be an intentional palette decision.
    @Test func lightDarkResolutionSnapshot() {
        func resolved(_ color: NSColor, dark: Bool) -> UInt32 {
            var result: UInt32 = 0
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            appearance.performAsCurrentDrawingAppearance {
                let converted = color.usingColorSpace(.sRGB)!
                result = UInt32(round(converted.redComponent * 255)) << 16
                    | UInt32(round(converted.greenComponent * 255)) << 8
                    | UInt32(round(converted.blueComponent * 255))
            }
            return result
        }
        let canvas = NSColor(SwiftUI.Color(Palette.surfaceCanvas))
        #expect(resolved(canvas, dark: false) == 0xF7F7F9)
        #expect(resolved(canvas, dark: true) == 0x17171B)
        let primary = NSColor(SwiftUI.Color(Palette.textPrimary))
        #expect(resolved(primary, dark: false) == 0x232328)
        #expect(resolved(primary, dark: true) == 0xECECF1)
    }
}
