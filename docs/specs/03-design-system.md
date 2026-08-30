<!--
Provenance: produced 2026-08-27/29 by a multi-agent design workflow driven by
Claude Code, verified against `claude` CLI v2.1.231, live docs, and on-disk
session stores on the primary dev machine. Working name "Maestro" has been
renamed to "Overture" throughout.

Where this document conflicts with 00-resolutions.md, the resolutions win.
Claims tagged [assumed] must be proven or refuted by the M0 spike before code
depends on them.
-->

# Overture Design System Specification

**Target:** native macOS 26 "Tahoe", Apple Silicon, Swift 6 / SwiftUI, Liquid Glass. This document is the source of truth for the `OvertureDesign` Swift package. Every value below (hex, pt, ms) is intended to be transcribed into code verbatim. All color pairings in this spec were machine-verified against the WCAG 2.x relative-luminance formula; ratios are printed where load-bearing.

---

## 1. Design Direction

### 1.1 Identity: calm mission control

Overture watches over agents that work on their own. The dominant emotional register is **calm confidence**: the user should be able to leave the app open on a second display for hours without fatigue, glance at it, and know everything in under a second. That drives four rules:

1. **Chrome recedes, state advances.** Surfaces are quiet, low-chroma neutrals. Color is spent almost exclusively on *state* — agent activity, column identity, git/deploy health, tags. If something is colorful, it means something.
2. **Motion is information.** Nothing animates decoratively. A card moves because an agent moved it; a dot pulses because tokens are streaming. Idle boards are perfectly still.
3. **Density over spectacle.** This is a tool for people who run six agents at once. Prefer a readable 13pt row over a 17pt hero card. Whitespace is structured by the 4pt grid, not by generosity.
4. **Native to the bone.** Standard NSWindow toolbar behavior, standard focus rings supplemented by our own only where AppKit gives none, SF Pro/SF Mono only, real macOS context menus, `Settings` scene, menu bar with full keyboard equivalents. Overture should feel like it shipped with the OS — "Jira in Electron" is the anti-goal.

### 1.2 Liquid Glass policy

Liquid Glass is used **only on floating chrome**, never on content-bearing reading surfaces. Legibility beats material richness everywhere they conflict.

**Use glass (via `glassEffect` / toolbar materials):**

| Location | Treatment |
|---|---|
| Window toolbar + board header | System toolbar glass (default), scroll-edge effect on |
| Command field (floating, Cmd+K) | `glassEffect(.regular)` capsule, content behind dimmed 25% |
| Toasts / notifications | `glassEffect(.regular)` on `radius.lg` rect |
| Card drag "lift" | The dragged card gains a glass halo (`glassEffect` behind an opaque card body) |
| Segmented mode switches, floating filter bar over the board | Glass capsule group (`GlassEffectContainer`) |

**Never glass (opaque semantic surface tokens instead):**

- Card bodies, column wells, project tiles (content must be scannable at a glance).
- Chat transcript, tool-call rows, code and diff views (long-form reading; background must be dead stable while text streams).
- The permission request sheet (a security decision surface — maximum legibility, no visual ambiguity about what is behind it).
- Any surface directly under streaming text.

Glass surfaces always carry text at `text.primary`/`text.secondary` only — never tertiary — because glass eats ~1 stop of contrast. Under **Reduce Transparency** every glass token resolves to its paired opaque `surface.overlay` color (§8.4).

---

## 2. Token Architecture

### 2.1 Three tiers

```
primitive  ──▶  semantic  ──▶  component
(raw values)    (meaning)      (per-widget overrides, sparse)
```

- **Primitive**: raw ramps. `neutral.900`, `indigo.500`, `space.400`, `radius.lg`. No light/dark logic; never referenced by feature code. `internal` to the package.
- **Semantic**: meaning-bearing, mode-aware. `color.surface.raised`, `color.text.secondary`, `color.status.running`, `elevation.card`, `motion.spring.flight`. This is the tier feature code uses 95% of the time. `public`.
- **Component**: defined only when a component must deviate from the semantic default, e.g. `card.background`, `chip.tag.red.background`, `column.header.text`. Each component token is an alias of a semantic (or, rarely, primitive) token so retheming stays one-hop.

### 2.2 Naming convention

Spec-side (this document, docs, Figma): dot-path, lowercase —
`{tier omitted}.{category}.{concept}[.{variant}][.{state}]`
e.g. `color.surface.raised`, `color.status.running.text`, `card.border.focused`, `motion.duration.fast`.

Swift-side: nested `enum` namespaces under a single root, camelCase leaves:

```swift
DS.Color.Surface.raised          // SwiftUI.Color (dynamic light/dark)
DS.Color.Status.running.text     // StatusColor struct: .text, .fill, .tint, .onFill
DS.Space.s300                    // CGFloat = 12
DS.Radius.card                   // CGFloat = 10
DS.Type.cardTitle                // Font + line spacing metadata
DS.Motion.Spring.flight          // SwiftUI.Animation
DS.Elevation.cardHover           // ShadowStyle struct
```

### 2.3 Implementation: code-defined tokens (recommended) vs asset catalog

**Recommendation: code-defined colors using dynamic `NSColor` providers, in a standalone `OvertureDesign` SwiftPM package.** Asset catalogs are the runner-up, not the pick:

| | Asset catalog | Code-defined (chosen) |
|---|---|---|
| Light/dark switching | automatic | automatic via `NSColor(name:dynamicProvider:)` |
| Increase Contrast variants | automatic (4 slots) | manual — provider inspects `NSAppearance.bestMatch` for `.accessibilityHighContrast*` names (§8.4) |
| Type safety | generated symbols (Xcode 15+), but stringly-typed underneath; symbol gen in SwiftPM targets is still second-class | fully type-safe, exhaustive `enum` namespaces |
| Reviewability | binary-ish JSON blobs in PRs | one diffable Swift file per tier — critical for an open-source project where the design system *is* public API |
| Single source of truth | values duplicated per appearance slot in a GUI | hex constants adjacent to their documented ratios; this spec's tables map 1:1 to code |
| Testability | needs a running bundle | unit-test contrast ratios in CI (`ContrastTests` recomputes WCAG ratios from the primitives — the palette can never silently regress below AA) |

Implementation core:

```swift
// OvertureDesign/Sources/Primitives/DynamicColor.swift
extension Color {
    /// Resolves per-appearance, including high-contrast variants.
    init(light: Int, dark: Int,
         lightHC: Int? = nil, darkHC: Int? = nil) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let isHC = appearance.name.rawValue.contains("HighContrast")
            switch (isDark, isHC) {
            case (false, false): return NSColor(hex: light)
            case (true,  false): return NSColor(hex: dark)
            case (false, true):  return NSColor(hex: lightHC ?? light)
            case (true,  true):  return NSColor(hex: darkHC ?? dark)
            }
        })
    }
}

// Semantic tier — the only tier feature code imports.
public enum DS {
    public enum Color {
        public enum Surface {
            public static let canvas  = SwiftUI.Color(light: 0xF7F7F9, dark: 0x17171B)
            public static let raised  = SwiftUI.Color(light: 0xFCFCFD, dark: 0x26262C)
            // ...
        }
    }
}
```

Non-color tokens (spacing, radius, type, motion) are plain statics on `DS`. A lightweight `Theme` struct is additionally injected through `EnvironmentValues` (`\.overtureTheme`) carrying only the things that can vary at runtime — user-selected accent (future), density mode, and resolved Reduce-Motion/Transparency flags — so previews can force any combination:

```swift
@Environment(\.overtureTheme) private var theme   // theme.accent, theme.reduceMotion, ...
```

Asset catalogs remain in use for **images only** (app icon, custom symbols §9.4).

---

## 3. Color System

### 3.1 Neutral primitives ("ink" ramp — cool-neutral, never pure black or pure white)

| Token | Hex | | Token | Hex |
|---|---|---|---|---|
| `neutral.25` | `#FCFCFD` | | `neutral.500` | `#8A8A93` |
| `neutral.50` | `#F7F7F9` | | `neutral.600` | `#6C6C76` |
| `neutral.100` | `#F1F1F4` | | `neutral.700` | `#50505A` |
| `neutral.150` | `#E8E8EC` | | `neutral.800` | `#35353C` |
| `neutral.200` | `#DEDEE3` | | `neutral.850` | `#2E2E35` |
| `neutral.300` | `#C9C9D0` | | `neutral.875` | `#26262C` |
| `neutral.400` | `#A9A9B2` | | `neutral.900` | `#232328` |
| | | | `neutral.925` | `#1D1D22` |
| | | | `neutral.950` | `#17171B` |

The ramp has a 1–2 point blue-violet bias (R=G<B) so dark surfaces read as "night sky," not "void," and light surfaces read as paper, not glare.

### 3.2 Semantic surfaces, text, borders

| Semantic token | Light | Dark | Notes |
|---|---|---|---|
| `surface.canvas` | `#F7F7F9` | `#17171B` | window content background |
| `surface.sunken` | `#F1F1F4` | `#1D1D22` | column wells, input wells, transcript bg |
| `surface.raised` | `#FCFCFD` | `#26262C` | cards, tiles, rows |
| `surface.overlay` | `#FFFFFF` | `#2E2E35` | popovers, menus, toasts (also the Reduce-Transparency stand-in for glass) |
| `surface.selected` | accent 10% over raised | accent 14% over raised | selected card/row |
| `text.primary` | `#232328` | `#ECECF1` | 14.6:1 / 15.2:1 on canvas |
| `text.secondary` | `#50505A` | `#B3B3BC` | 7.4:1 / 8.6:1 |
| `text.tertiary` | `#6C6C76` | `#94949D` | 4.9:1 / 5.0:1 — still AA; timestamps, meta |
| `text.disabled` | `text.tertiary` at 55% opacity | same | decorative; never sole information carrier |
| `text.onAccent` | `#FFFFFF` | `#FFFFFF` | 6.1:1 / 5.1:1 on accent fills |
| `border.subtle` | `#E8E8EC` | `#33333A` | hairlines, card edges (decorative) |
| `border.strong` | `#C9C9D0` | `#45454D` | dividers on sunken surfaces |
| `border.control` | `#8A8A93` | `#7A7A83` | boundaries of interactive controls — ≥3:1 non-text contrast on their surfaces |
| `focus.ring` | `#4E4BE4` | `#8886FF` | 5.7:1 / 5.9:1 vs canvas — comfortably over the 3:1 non-text minimum |

### 3.3 Accent — "Baton Indigo"

One accent. Used for: selection, focus ring, primary buttons, links, the *thinking/streaming* agent state, and the command field caret. Nothing else.

| Token | Light | Dark | Verified |
|---|---|---|---|
| `accent.text` (text/icons on surfaces) | `#4E4BE4` | `#8886FF` | 5.9:1 on raised / 4.9:1 on card |
| `accent.fill` (buttons; white text) | `#4E4BE4` | `#5C5AEE` | on-fill white 6.1:1 / 5.1:1 |
| `accent.fill.hover` | `#4340C9` | `#6D6BFA` | |
| `accent.fill.pressed` | `#3A38B0` | `#4F4DDB` | |
| `accent.tint` (selected/hover washes) | accent @ 10% | accent @ 14% | non-text |

### 3.4 Functional status palette

Eight hues, each meaning exactly one thing across the whole app. Every status color ships as a 4-slot struct: **`.text`** (on app surfaces — all ratios below ≥5.2:1 light, ≥6.4:1 dark, verified), **`.fill`** (solid badge; use with `text.onFill = #FFFFFF` in light mode — all ≥5.3:1 — and with `.text` color on dark tint in dark mode), **`.tint`** (fill at 12% alpha light / 16% dark, layered on `surface.*`), **`.dot`** (equals `.text`; 6–8pt indicator dots, ≥3:1 everywhere).

| Meaning (single owner of the hue) | Token | Light `.text`/`.fill` | Dark `.text` |
|---|---|---|---|
| Neutral / idle / backlog / queued | `status.neutral` | `#63636D` | `#A2A2AB` |
| Planning | `status.plan` | `#7434BE` | `#C79BF2` |
| Active / running / in-progress / streaming† | `status.running` | `#2257CE` | `#7FA9F9` |
| Testing / verification | `status.testing` | `#0A6E63` | `#3FC3B2` |
| Needs a human (review column) | `status.review` | `#BE2F5C` | `#F387A6` |
| Caution: awaiting permission, dirty tree, building | `status.caution` | `#8A5A00` | `#E3B34F` |
| Success: done, clean, deployed | `status.success` | `#1B7038` | `#5BC97E` |
| Failure: error, conflict, failed deploy | `status.danger` | `#C42B24` | `#F2766F` |

† The *agent* streaming indicator itself uses `accent` (it is the app's "live" color); the *column* In Progress uses `status.running`. They are deliberate near-neighbors (indigo/blue) — "agent alive" and "work active" are cousins.

**State → token map (exhaustive):**

- Agent: idle→`neutral`, thinking/streaming→`accent` (+ animation §6), awaiting-permission→`caution`, error→`danger`, finished-awaiting-review→`review`.
- Columns: Backlog→`neutral`, Plan→`plan`, In Progress→`running`, Testing→`testing`, Review→`review`, Done→`success`.
- Git: clean→`success`, dirty→`caution`, conflict→`danger`, ahead/behind→`neutral` (+ `arrow.up`/`arrow.down` glyph, count).
- Vercel: queued→`neutral`, building→`caution` (pulsing dot), ready→`success`, error→`danger`, canceled→`neutral` at 60%.

Color is never the sole channel: every status pairs with an SF Symbol (§9) and a text label or accessibility label.

### 3.5 Tag palette

Eleven named colors. Chips render as **tinted background + strong text** (no white-on-saturated chips — easier on the eyes at density). Every pair below is verified ≥4.5:1 (actual range 5.4–8.9:1).

| Tag | Light bg | Light text | Dark bg | Dark text |
|---|---|---|---|---|
| Red | `#FBE3E1` | `#A02C23` | `#43201E` | `#FCA9A2` |
| Orange | `#FCE8DB` | `#96430A` | `#3F2818` | `#F5B98A` |
| Amber | `#F9EDCF` | `#7A5304` | `#3B2E12` | `#E9C979` |
| Green | `#DEF2E2` | `#1D6B37` | `#16321F` | `#94DFA9` |
| Teal | `#D7F1ED` | `#0B615B` | `#103230` | `#7BD9CF` |
| Cyan | `#DBEFF9` | `#12607F` | `#12303C` | `#8CCDE8` |
| Blue | `#E0EAFB` | `#2350B8` | `#1B2A47` | `#A6C4F7` |
| Indigo | `#E6E5FB` | `#4340C9` | `#26254B` | `#B7B5F9` |
| Purple | `#EFE4FA` | `#6D2FA8` | `#2E2040` | `#CFAAF2` |
| Pink | `#FAE1EC` | `#A82762` | `#3C1E2C` | `#F0A3C4` |
| Gray | `#EAEAEE` | `#48484F` | `#2C2C33` | `#C6C6CE` |

Default tags shipped: `bug`→Red, `feature`→Blue, `chore`→Gray, `refactor`→Purple, `docs`→Cyan, `urgent`→Orange, `design`→Pink, `test`→Teal, `perf`→Amber, `idea`→Green. User-created tags pick any of the 11; the color picker shows chips, not swatches, so users see real contrast.

---

## 4. Typography

SF Pro (text/display auto-selected by size) + SF Mono. **Never** a third face.

### 4.1 Base scale (macOS text styles — all roles are built from these so Dynamic Type scales everything)

| Style | Size/Leading | Weight |
|---|---|---|
| largeTitle | 26/32 | Bold |
| title | 22/26 | Bold |
| title2 | 17/22 | Semibold |
| title3 | 15/20 | Semibold |
| headline | 13/16 | Semibold |
| body | 13/16 | Regular |
| callout | 12/15 | Regular |
| subheadline | 11/14 | Regular |
| footnote | 10/13 | Regular |
| caption | 10/13 | Regular |

### 4.2 Overture roles (`DS.Type.*`)

| Role | Definition | Usage rules |
|---|---|---|
| `screenTitle` | title (22/26 Bold) | Home "Projects", board title in toolbar |
| `tileTitle` | title3 (15/20 Semibold), `text.primary` | 1 line, middle-truncate |
| `tileSummary` | callout (12/16 Regular), `text.secondary` | last-chat summary, 2 lines max |
| `columnHeader` | subheadline (11/14 **Semibold**), uppercase, tracking +0.06em, column's `status.*.text` |
| `cardTitle` | body (13/17 **Medium**), `text.primary` | 2 lines max |
| `cardMeta` | subheadline (11/14), `text.secondary` | branch, tag overflow "+2" |
| `chatBody` | body at 13/**19** (relaxed leading token `leading.reading = 1.45×`), `text.primary` | transcript prose |
| `code` | SF Mono 12/18 Regular | code blocks, diffs; never below 11pt |
| `diffLineNumber` | SF Mono 10/18, `text.tertiary`, monospacedDigit |
| `toolCallLabel` | callout (12/15 Medium), SF Mono for the command excerpt |
| `timestamp` | caption (10/13), `text.tertiary`, `.monospacedDigit()` |
| `badgeLabel` | caption (10/13 **Semibold**), tracking +0.02em |
| `commandField` | title3-size 15/20 Regular (large, confident input) |
| `emptyStateTitle` | title3 Semibold; `emptyStateBody` callout `text.secondary` |
| `kbd` | SF Mono 10, in 4pt-radius `surface.sunken` keycap |

**Dynamic Type:** every role is declared `Font.system(.style)` relative, custom sizes via `@ScaledMetric(relativeTo:)`. Layout must survive the macOS "Larger Text" accessibility sizes: cards grow vertically (never clip), column width is fixed so text wraps, transcript is fully fluid. Numerals in counts/timers are always `monospacedDigit` to prevent jitter while streaming.

---

## 5. Spacing, Layout, Radius, Elevation

### 5.1 Spacing (4pt grid)

`space.050=2, 100=4, 200=8, 300=12, 400=16, 500=20, 600=24, 800=32, 1000=40, 1200=48, 1600=64`

Rules: component-internal padding uses 100–400; between siblings 200–300; between sections 600; page margins 600 (24). The only sub-4 value is `050=2` (chip internals, dot-to-label gaps).

### 5.2 Radius (concentric-aware)

| Token | pt | Used on |
|---|---|---|
| `radius.xs` | 4 | keycaps, badge rects, inline code |
| `radius.sm` | 6 | chips, small buttons, tool-call rows |
| `radius.md` | 8 | buttons, inputs, segmented controls |
| `radius.card` | 10 | kanban cards, chat bubbles |
| `radius.panel` | 14 | column wells, transcript panel, banners |
| `radius.tile` | 18 | project tiles, sheets, popovers |
| `radius.capsule` | ∞ | status pills, command field, filter bar |

Nested corners are **concentric**: `inner = outer − padding` (e.g. card 10 inside column well 14 with 4pt visual inset margin honors 14−4=10). On macOS 26 use `ConcentricRectangle`/container-relative shapes where available so windows and sheets inherit the OS curvature.

### 5.3 Elevation

Five levels; each = shadow + border treatment. Dark mode compensates weak shadows with a 1pt inner top highlight (`white @ 6%`).

| Token | Light shadow | Dark shadow | Extras |
|---|---|---|---|
| `elevation.flat` | none | none | sunken wells; `border.subtle` only |
| `elevation.card` | `y1 blur3 black@8%` | `y1 blur3 black@40%` | + `border.subtle`; + top highlight (dark) |
| `elevation.hover` | `y3 blur8 black@10%` | `y4 blur10 black@45%` | card raises, no scale |
| `elevation.drag` | `y8 blur24 black@14%` | `y10 blur28 black@55%` | + scale 1.02 + glass halo |
| `elevation.overlay` | `y12 blur32 black@16%` | `y16 blur40 black@60%` | popovers, toasts |
| `elevation.modal` | `y20 blur48 black@20%` | `y24 blur56 black@65%` | sheets |

### 5.4 Layout metrics

| Token | Value |
|---|---|
| Board column width | **300pt fixed** (`column.width`); board scrolls horizontally when 6×300+gaps exceeds window |
| Column gap | 12; board margins 20; column inner padding 8; column header height 36 |
| Card width | 284 (300 − 2×8); card padding 12; card gap 8; card min-height 68 |
| Project tile grid | adaptive, min 280 / ideal 320; tile height 168; grid gap 16; page margin 24 |
| Chat/detail pane | min 400, ideal 520, resizable; transcript measure ≤ 640pt (center-capped for readability) |
| Toolbar | system height; command field 480×44 centered overlay |
| Hit targets | minimum 24×24pt clickable, 28pt row height for menus/lists |

---

## 6. Motion

### 6.1 Principles

1. **Motion = causality.** Every animation traces to an agent or user event; nothing loops idly except the two "alive" indicators (streaming shimmer, activity pulse), and those stop the instant the state ends.
2. **Interruptible & redirectable** — springs, not timed curves, for anything positional.
3. **One noticeable thing at a time.** If a card auto-moves while another streams, the move plays and the shimmer continues — but we never add a third simultaneous flourish (badges just swap).
4. **Respect Reduce Motion absolutely** (§6.4).

### 6.2 Tokens

| Token | Value | Use |
|---|---|---|
| `duration.instant` | 100ms | hover tints, icon swaps |
| `duration.fast` | 150ms | pressed states, chip toggles |
| `duration.base` | 200ms | fades, badge changes, selection |
| `duration.gentle` | 300ms | panel slide, sheet present (with spring) |
| `duration.pulse` | 2400ms | live-activity pulse cycle |
| `duration.shimmer` | 1600ms | streaming shimmer sweep |
| `spring.snap` | response 0.30, damping 0.90 | control feedback |
| `spring.standard` | response 0.38, damping 0.85 | most layout changes, auto-move |
| `spring.entrance` | response 0.45, damping 0.80 | toasts, sheets, column populate |
| `spring.flight` | response 0.55, damping 0.78 | the Done→In Progress fly-back (one soft overshoot) |

### 6.3 Signature moments

**Card auto-move (agent changed state), e.g. In Progress → Review.**
Sequence: (1) card raises to `elevation.hover` and its status dot swaps color, 150ms; (2) card travels to the destination column slot with `spring.standard` using `matchedGeometryEffect`, siblings close/open gaps simultaneously with the same spring; (3) on landing, the destination column well flashes its column tint at 10% and decays over 600ms; the column count pill ticks with a `numericText` transition. Total ≈ 700ms; noticeable, silent, never blocks input. Off-screen destination: card slides toward the column's edge direction and a transient pill "→ Review" appears on the destination header for 2s.

**Done → In Progress "fly back" (user continues a finished chat).**
The moment of delight, kept under a second: (1) card lifts to `elevation.drag`, scale 1.03 (120ms); (2) flies right-to-left along a slight arc (control point 40pt above the straight line) with `spring.flight`, leaving a 200ms-fading accent-tinted ghost at its origin; (3) lands in In Progress, compresses to scale 0.98 and settles (spring completes), agent indicator ignites (idle→streaming transition); (4) column tint flash as above. Implementation: `matchedGeometryEffect` in a shared board coordinate space; arc via a custom `Animatable` offset.

**Streaming text shimmer.** While tokens stream into a transcript or card summary, the newest line carries a left-to-right luminance sweep: a 60°-angled linear gradient mask, `text.primary` → `accent.text` at 35% blend → back, sweeping over `duration.shimmer`, repeat while streaming. Applied to at most the last visual line — never whole paragraphs (reading stability).

**Tile live-activity pulse.** Project tile shows an 8pt accent dot + "Working…" when any agent runs. The dot eases opacity 0.55 → 1.0 → 0.55 over `duration.pulse`; a hairline accent ring on the tile breathes in sync at 0→15% opacity. Stops (fades out over 300ms) the moment the last agent stops.

### 6.4 Reduce Motion map (exact substitutions)

| Full motion | Reduce Motion |
|---|---|
| Auto-move travel | 200ms cross-fade out at origin / in at destination; column flash retained (it is opacity-only) |
| Fly-back flight | same cross-fade + the accessibility announcement (§8.3) |
| Shimmer | none; static `text.secondary` "streaming" caption + non-animated glyph |
| Tile pulse | static filled dot |
| Toast slide-in | fade |
| Drag scale/halo | plain shadow change |

`theme.reduceMotion` resolves from `\.accessibilityReduceMotion`; every signature moment reads it — no exceptions.

---

## 7. Component Inventory

Interactive states everywhere: `default / hover / pressed / focused / disabled` (+ `selected`, `dragged` where applicable). Hover = `+accent.tint` or elevation step; pressed = 96% scale on controls (`spring.snap`) or darkened fill; focused = `focus.ring` 2pt stroke, 2pt offset, `radius+2` outer; disabled = 50% opacity + `allowsHitTesting(false)`.

**Project tile** — `surface.raised`, `radius.tile`, `elevation.card`. Anatomy: header (tileTitle + tag chips), middle (live agent line with pulse dot *or* last-chat summary in `tileSummary`), footer (git group: `arrow.triangle.branch` + branch name in `cardMeta`, dirty dot `status.caution`, ahead/behind counts; Vercel status pill). Hover→`elevation.hover` + 150ms tint; pressed→scale 0.98; focused→ring; agent-active variant swaps summary for progress line (current tool + elapsed `timestamp`).

**Board column** — well: `surface.sunken`, `radius.panel`, `elevation.flat`. Header: column SF Symbol + `columnHeader` label in the column's `status.*.text` + count pill (`status tint` bg, `.text` fg, capsule). Drop-target state: well stroke `border.control` dashed → column tint 10% wash; WIP-limit exceeded (single-dir mode): count pill flips to `status.caution` tint with tooltip "queued: N".

**Card** — `surface.raised`, `radius.card`, `elevation.card`, padding 12. Rows: (1) status dot 8pt + `cardTitle`; (2) tag chips (max 3 + "+N"); (3) meta row — branch, diff stat (`+42 −7` in `code` 10pt, success/danger colors), agent activity indicator right-aligned. Selected→`surface.selected` + ring; dragged→`elevation.drag`; agent-state variants recolor the dot and meta line (streaming = accent + shimmer on the live summary line; awaiting-permission = caution dot + `hand.raised.fill` + card border `status.caution` at 60%; error = danger dot + one-line error in `status.danger.text`).

**Tag chip** — capsule, `badgeLabel` type... height 20, padding H 8; colors §3.5. Removable variant appends 12pt `xmark` at 70% opacity (100% on hover). Focused→ring; in filter bars, selected chip = solid `.fill` with `onFill` text.

**Status badge** — capsule, height 20, dot(6) + `badgeLabel`, `status.*.tint` bg + `.text` fg. Solid variant (toolbar deploy badge) uses `.fill` + white (light) / tint+`.text` (dark).

**Agent activity indicator** — 16pt component: idle=`moon.zzz` neutral; thinking/streaming=three 3pt dots in accent, staggered opacity wave 1.2s (RM: static `ellipsis` glyph); awaiting-permission=`hand.raised.fill` caution + gentle 2× scale-pulse of its tint ring; error=`exclamationmark.triangle.fill` danger, static. Always accompanied by an `accessibilityLabel` ("Agent streaming, 2 minutes elapsed").

**Chat transcript** — background `surface.sunken`; user messages: right-aligned bubbles, `accent.tint` bg, `radius.card`, max 75% width; agent messages: no bubble — full-measure `chatBody` on the well (documents, not chat toys), separated by `space.400` + hairline. Code blocks: `surface.raised`, `radius.sm`, `code` type, copy button on hover. Streaming: shimmer on last line (§6.3).

**Tool-call row** — collapsed 28pt row: chevron, tool SF Symbol, `toolCallLabel` ("Bash — `swift build`" with SF Mono excerpt), right status: spinner(accent)/check(success)/x(danger)/timer. Expanded: `surface.raised` inset panel, `radius.sm`, mono output, max-height 240 then inner scroll. Hover reveals "expand/copy".

**Plan approval banner** — pinned above transcript input: `status.plan` tint bg, `radius.panel`, `map` symbol + "Plan ready for review" headline + buttons [Approve & Run `accent.fill` primary] [Edit plan] [Reject `plain`]. Enters with `spring.entrance` slide+fade.

**Permission request sheet** — opaque `surface.overlay` (never glass), `radius.tile`, `elevation.modal`. Caution header band (`status.caution.tint`, `hand.raised.fill`), the requested command verbatim in `code` on `surface.sunken`, scope note ("in worktree feature/auth-refresh"), buttons [Deny plain] [Allow once `accent.fill`] [Always allow — checkbox row]. Default focus = Allow once; Esc = Deny. Cmd+Return confirms. Badge count of queued requests when multiple.

**Diff viewer chrome** — header: file path in `code`, +/− stat, view toggle (unified/split, glass segmented capsule). Gutter: `diffLineNumber` on `surface.sunken`. Line backgrounds: light `#E4F5E7`/dark `#15301D` (add), light `#FBE7E5`/dark `#3A1D1A` (delete) — text stays `text.primary` on both (verified ≥12:1); word-level emphasis: add/delete tint at 2× alpha. Collapsed-context bars: 24pt, `text.tertiary`, "⋯ 34 unchanged lines".

**Toolbar** — system glass; leading: back + project name (`headline`); center: view switcher; trailing: deploy status badge, git badge, `plus` (new ticket), `magnifyingglass`. Overflow collapses into `ellipsis.circle` menu.

**Command field (Cmd+K)** — centered floating capsule 480×44, glass, `commandField` type, results list on `surface.overlay` below (rows 28pt, symbol + label + `kbd` shortcut). Scope prefixes ("> " commands, "@" projects, "#" cards).

**Empty states** — centered, max 320 wide: 32pt hierarchical SF Symbol in `text.tertiary`, `emptyStateTitle`, `emptyStateBody`, one primary action. Copy is specific: Backlog: "No tickets yet — press ⌘N or ask Claude to draft one." Review: "Nothing to review. Agents will land finished work here."

**Toasts** — bottom-trailing stack, glass capsule-to-`radius.panel`, `elevation.overlay`, max width 360, auto-dismiss 5s (pause on hover), enters `spring.entrance` from bottom (RM: fade). Anatomy: status dot/symbol + `body` message + optional action button. Agent events (card moved, tests passed, permission needed) are the primary emitters; clicking focuses the card.

---

## 8. Accessibility

### 8.1 Contrast targets

- Text ≥ 4.5:1 (AA) in **both** modes — the entire §3 palette is verified and CI-tested (`ContrastTests`).
- Aim AAA (7:1) for `text.primary` and `text.secondary` — achieved (14.6/7.4 light, 15.2/8.6 dark).
- Non-text (focus ring, control borders, status dots) ≥ 3:1.
- Color never sole channel: status = color + symbol + label everywhere.

### 8.2 Keyboard model (full app is keyboard-operable)

- **Board focus model:** columns are a horizontal focus group; cards a vertical list within. `←/→` move between columns (landing on the nearest card by visual row), `↑/↓` within a column, `Home/End` first/last. Focused card shows `focus.ring`.
- **Move card:** `⌘←/⌘→` moves the focused card one column; `⌘⇧←/⌘⇧→` to first/last column; moves trigger the same animation + announcement as agent moves. `⌘↑/⌘↓` reorders within a column.
- **Act:** `Space` quick-look preview; `Return` open chat; `⌘Return` approve (plan/permission contexts); `⌘D` mark Done; `⌘N` new ticket; `⌘K` command field; `⌘F` filter; `⌘1…6` jump to column; `Esc` closes panes in LIFO order.
- Full-keyboard-access compliant: every control reachable by Tab, actions in menu bar with equivalents (discoverability + system shortcut remapping).

### 8.3 VoiceOver

- Columns: `accessibilityElement(children: .contain)`, label "In Progress column, 3 cards, 1 agent running", `.updatesFrequently` on count.
- Cards: single element; label = "\(title), \(column), \(agentState), tags \(tags), \(position) of \(count)"; custom rotor actions: "Move to …" (6), "Open chat", "Mark done".
- Live agent status: transcript container is a live region; the activity indicator posts state *changes* only (no per-token chatter).
- **Auto-move announcements:** every agent-driven move posts `AccessibilityNotification.Announcement("Auth refresh moved to Review — agent finished")`, high priority for permission requests ("Agent awaiting permission to run npm install"), polite otherwise. Toasts mirror announcements so sighted and VO users get parity.
- Streaming: announce "response streaming started/finished", not content; user reads at will.

### 8.4 System adaptations

- **Reduce Motion:** §6.4 table, resolved once into `theme.reduceMotion`.
- **Reduce Transparency:** all glass → `surface.overlay` opaque via a `glassOrOpaque()` modifier; scroll-edge effects become hard hairlines.
- **Increase Contrast:** dynamic providers ship HC variants — borders shift one ramp step darker/lighter (`border.subtle`→`neutral.300`/`#4F4F58`), `text.tertiary`→`text.secondary` values, status `.text` colors deepen ~15% (e.g. light caution `#8A5A00`→`#6E4700`), tints double to 20/28% alpha, focus ring 3pt.
- **Differentiate Without Color:** already satisfied structurally (symbols + labels); dot-only indicators (tile pulse, dirty dot) gain their symbol when `accessibilityDifferentiateWithoutColor` is on.

---

## 9. Iconography

SF Symbols 7, default weight `medium`, hierarchical rendering on surfaces, monochrome inside chips/badges. Sizes: 12 (inline/meta), 16 (cards/rows), 20 (toolbar), 32 (empty states).

### 9.1 Columns
| Concept | Symbol |
|---|---|
| Backlog | `tray` |
| Plan | `map` |
| In Progress | `play.circle` |
| Testing | `testtube.2` |
| Review | `eye` |
| Done | `checkmark.circle` (`.fill` when column non-empty) |

### 9.2 Agent & session states
| State | Symbol |
|---|---|
| Idle | `moon.zzz` |
| Thinking/streaming | `ellipsis` (animated 3-dot component §7) / `sparkles` in menus |
| Awaiting permission | `hand.raised.fill` |
| Error | `exclamationmark.triangle.fill` |
| Finished (awaiting review) | `checkmark.seal` |
| Plan ready | `map.fill` |
| Continue chat | `arrow.uturn.backward.circle` |

### 9.3 Git / deploy / actions
| Concept | Symbol |
|---|---|
| Branch / worktree | `arrow.triangle.branch` |
| Dirty tree | `circle.fill` (6pt, caution) |
| Ahead / behind | `arrow.up` / `arrow.down` + count |
| Commit | `checkmark.circle.badge.questionmark` → plain `signpost.right` alt: use `smallcircle.filled.circle` for commit nodes |
| Pull request | `arrow.triangle.merge` |
| Conflict | `exclamationmark.arrow.triangle.2.circlepath` |
| Deploy ready / building / failed | `checkmark.circle.fill` / `arrow.triangle.2.circlepath` / `xmark.octagon.fill` |
| New ticket | `plus` · Search `magnifyingglass` · Filter `line.3.horizontal.decrease.circle` · Tags `tag` · Settings `gearshape` · Terminal/tool call `terminal` · Chat `text.bubble` · Diff `plus.forwardslash.minus` · Preview pane `safari` alt `rectangle.inset.filled.and.person.filled` → prefer `macwindow.on.rectangle` |

### 9.4 Custom symbols (asset catalog, drawn to SF grid as symbol templates)
`claude.spark` (agent avatar — asterisk mark), `github.mark`, `vercel.triangle`, `overture.baton` (app glyph accents). Each exported as a 3-weight SF Symbol template so they scale/align with system glyphs and respect Bold Text.

---

## 10. Package Shape (hand-off note)

```
OvertureDesign/
├─ Sources/OvertureDesign/
│  ├─ Primitives/   Palette.swift, DynamicColor.swift, SpacePrimitives.swift
│  ├─ Semantic/     Colors.swift, Typography.swift, Spacing.swift,
│  │                Radius.swift, Elevation.swift, Motion.swift, Icons.swift
│  ├─ Component/    CardTokens.swift, ChipTokens.swift, ColumnTokens.swift, …
│  ├─ Theme/        Theme.swift (EnvironmentKey), GlassPolicy.swift
│  └─ Modifiers/    FocusRing.swift, GlassOrOpaque.swift, Shimmer.swift, Elevation.swift
└─ Tests/OvertureDesignTests/
   ├─ ContrastTests.swift      // recomputes every §3 ratio; fails CI < 4.5 (text) / 3.0 (non-text)
   └─ TokenSnapshotTests.swift // token values are public API — changes must be intentional
```

Feature code may import only the Semantic and Component tiers; SwiftLint rule bans `Color(red:…)`, raw hex, raw `CGFloat` paddings, and `Font.system(size:)` outside `OvertureDesign` — that is what "tokens for everything" means in enforcement terms.
