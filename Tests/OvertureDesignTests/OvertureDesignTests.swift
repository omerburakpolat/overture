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

/// Layout, stroke and opacity tokens are public API consumed by every
/// screen; a change here must be an intentional design decision, not a
/// side effect of a refactor.
@Suite struct LayoutTokenSnapshotTests {
    @Test func windowAndSheetSizes() {
        #expect(DS.Layout.windowMinWidth == 960)
        #expect(DS.Layout.windowMinHeight == 620)
        #expect(DS.Layout.Sheet.narrow == 480)
        #expect(DS.Layout.Sheet.medium == 520)
        #expect(DS.Layout.Sheet.wide == 560)
        #expect(DS.Layout.Sheet.detailMin == CGSize(width: 640, height: 520))
        #expect(DS.Layout.Sheet.detailIdeal == CGSize(width: 760, height: 640))
        #expect(DS.Layout.settingsWindowSize == CGSize(width: 480, height: 280))
        // Spec §5.4: command field 480×44; §7: toast max width 360.
        #expect(DS.Layout.commandFieldWidth == 480)
        #expect(DS.Layout.commandFieldHeight == 44)
        #expect(DS.Layout.toastMaxWidth == 360)
    }

    @Test func componentMetrics() {
        #expect(DS.Layout.statusDot == 8)
        #expect(DS.Layout.indicatorDot == 6)
        #expect(DS.Layout.chipHeight == 20)
        #expect(DS.Layout.iconColumnWidth == 20)
        #expect(DS.Layout.diffGutterWidth == 40)
        #expect(DS.Layout.editorMinHeight == 120)
        #expect(DS.Layout.planPreviewMaxHeight == 240)
        #expect(DS.Layout.consoleHeight == 120)
        #expect(DS.Layout.menuMinWidth == 260)
        #expect(DS.Layout.tileMaxWidth == 380)
        // Spec §7: user bubbles at most 75% of the transcript measure.
        #expect(DS.Layout.userBubbleMaxWidth == DS.Layout.transcriptMeasure * 0.75)
        #expect(DS.Layout.userBubbleMaxWidth == 480)
        // Every small hit target still clears the §5.4 minimum.
        #expect(DS.Layout.minimumHitTarget <= DS.Layout.menuRowHeight)
        #expect(DS.Layout.chipHeight < DS.Layout.minimumHitTarget)
    }

    @Test func strokesAndOpacities() {
        #expect(DS.Stroke.hairline == 1)
        #expect(DS.Stroke.accentBar == 2)
        #expect(DS.Stroke.dash == [6, 4])
        #expect(DS.Opacity.pending == 0.7)
        #expect(DS.Opacity.deselected == 0.45)
        #expect(DS.Opacity.cautionRing == 0.6)
        // Spec §1.2: content behind the command field is dimmed 25%.
        #expect(DS.Opacity.scrim == 0.25)
    }

    @Test func typographyAndIconAdditions() {
        #expect(DS.TypeStyle.columnHeaderKerning == 0.8)
        // One symbol per concept (§9): the new names must stay distinct.
        let names = [DS.Icon.close, DS.Icon.stop, DS.Icon.send, DS.Icon.info,
                     DS.Icon.edit, DS.Icon.selected, DS.Icon.reload,
                     DS.Icon.openInBrowser, DS.Icon.activity, DS.Icon.project]
        #expect(Set(names).count == names.count)
    }
}
