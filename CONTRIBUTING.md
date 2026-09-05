# Contributing to Overture

## Getting started

Requirements: macOS 26+, Xcode 26+, and the `claude` CLI (signed in) for
live testing.

```bash
swift build          # all six library targets
swift test           # 85+ unit tests, no network, no claude needed
open Overture.xcodeproj   # the app target
```

## Layout

One SPM package, six targets — `ProcessCore` (subprocess primitives),
`ClaudeKit` (CLI supervision + stream-json protocol), `GitKit`, `VercelKit`,
`OvertureKit` (SwiftData schema, BoardEngine, stores), `OvertureDesign`
(tokens + components) — plus the thin app target in `App/`. The specs in
`docs/specs/` are the source of truth; `00-resolutions.md` wins conflicts.

## Rules of the road

- **Tokens for everything**: no raw hex, sizes, or `Font.system(size:)`
  outside `OvertureDesign`. `ContrastTests` gate the palette at WCAG AA.
- **Tolerant decoding**: unknown stream/transcript shapes are never fatal.
- **Transitions go through `BoardEngine`** — nothing else mutates
  `card.column`. New transitions need drag-matrix tests.
- **Never write** to `~/.claude` — Claude Code owns its store.
- Live tests (`OVERTURE_LIVE_TESTS=1`) spawn the real CLI and cost tokens;
  add `OVERTURE_MINIMAL_CLAUDE_ENV=1` for deterministic runs.

## Licensing

MIT (see LICENSE); third-party marks excluded (see NOTICE). By contributing
you agree your contributions are MIT-licensed.
