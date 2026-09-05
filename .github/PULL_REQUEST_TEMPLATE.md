## What and why

<!-- What does this change, and what problem does it solve? Link any issue. -->

## How to verify

<!-- The steps a reviewer should run. Include live-test notes if relevant. -->

## Checklist

- [ ] `swift build` and `swift test` pass
- [ ] No raw hex, sizes, or `Font.system(size:)` outside `OvertureDesign`
- [ ] Column transitions go through `BoardEngine`; new transitions have
      drag-matrix tests
- [ ] Nothing writes to `~/.claude`
- [ ] Decoding stays tolerant — unknown stream shapes are never fatal
- [ ] Specs in `docs/specs/` updated if behavior changed
