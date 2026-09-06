# Working in this repository

Overture is a native macOS Kanban harness for Claude Code. Swift 6 / SwiftUI,
macOS 26+, Apple Silicon. Public, MIT, pre-1.0. The specs in `docs/specs/` are
the source of truth; `00-resolutions.md` wins where they conflict.

---

## Pushing: `main` is protected, with no bypass

**There is no direct push to `main`. Not for contributors, not for the owner,
not with `--force`, not "just this once".** The ruleset has an empty bypass
list, so an attempt fails at the remote:

```
! [remote rejected] main -> main (push declined due to repository rule violations)
```

Every change reaches `main` through a pull request.

### The rules, exactly

| Rule | Effect |
|---|---|
| Pull request required | No direct pushes to `main` |
| Required approvals | **0** — you may merge your own PR |
| Required status checks | `Build & test packages` **and** `Build app` must pass |
| Branch must be up to date | Rebase or merge `main` before merging |
| Conversation resolution | Every review thread resolved before merge |
| Force pushes | Blocked on `main` |
| Deletion | Blocked on `main` |
| Bypass actors | **None** |

Approvals are 0 only because there is one maintainer and GitHub forbids
approving your own PR — with a second maintainer, raise it to 1.

### The loop

```bash
git checkout main && git pull --ff-only origin main
git checkout -b <type>/<short-description>       # feat/ fix/ docs/ ci/ refactor/
# ... work ...
swift build && swift test                        # must pass before you push
git push -u origin HEAD
gh pr create --fill
gh pr checks --watch                             # wait for both checks
gh pr merge --squash --delete-branch
```

Never leave a feature branch as your working branch after merging — go back to
`main` and pull. A stale branch is how commits silently pile up somewhere they
will never ship.

### Verify the push actually landed

`git push ... | tail` reports the exit status of `tail`, not of `git`. A
rejected push then looks identical to a successful one. **Never pipe a push
and trust the result.** Check the refs instead:

```bash
git push origin HEAD
echo "exit: $?"
git fetch -q origin
git log --oneline origin/main..HEAD          # empty means everything landed
```

If you are ever unsure whether work is public, compare hashes — do not infer
it from your local log:

```bash
git rev-parse --short HEAD origin/main
```

### Tags are immutable

`v*` tags are protected against update **and** deletion, with no bypass. A
release tag cannot be moved after it is pushed.

- Make sure the commit is right *before* tagging. A tag push triggers the
  signed, notarized release pipeline.
- A mistake means cutting the next patch version. It does not mean force-moving
  the tag; that is now impossible, and it was always wrong — Sparkle clients and
  anyone who fetched the old tag would disagree about what `v0.1.0` is.

---

## Never commit

- `dist/` and `build/` — release staging and build output (both gitignored).
  `scripts/release.sh` stages a ~2.5 MB signed DMG into `dist/`, so a careless
  `git add -A` during a release will try to commit a binary.
- `*.p12`, `*.p8`, `*.provisionprofile`, `sparkle_private_key*` — signing and
  notarization material. The App Store Connect key lives in
  `~/.appstoreconnect/private_keys/`, mode `600`, **outside the repo**.
- Anything derived from a real Claude session. The fixtures under
  `Tests/ClaudeKitTests/Fixtures/` are recordings and once carried a real
  account email, home directory and machine paths. If you re-record them,
  scrub before committing — and note that long paths are split mid-token across
  `partial_json` and `thinking_delta` chunks, so a whole-string find/replace
  will miss fragments.

Secret scanning with push protection is enabled, but it is a backstop, not a
substitute for not writing the secret down.

---

## Rules of the road

- **Tokens for everything**: no raw hex, sizes, or `Font.system(size:)` outside
  `OvertureDesign`. `ContrastTests` gate the palette at WCAG AA.
- **Tolerant decoding**: unknown stream or transcript shapes are never fatal.
- **Transitions go through `BoardEngine`** — nothing else mutates `card.column`.
  New transitions need drag-matrix tests.
- **Never write to `~/.claude`** — Claude Code owns that store. `SECURITY.md`
  states this publicly, so a violation makes the project dishonest, not just
  buggy.
- **No telemetry, no analytics, no backend.** Also a public SECURITY.md claim.

### Running your build

```bash
scripts/run-local.sh            # Debug, fastest
scripts/run-local.sh Release    # what users actually get
```

Builds the working tree, quits whatever copy is running, and launches the one
it just built.

That last part is the point. Several `Overture.app` copies can exist at once —
a brew-installed release in `/Applications`, an Xcode Debug build under the
machine-global `SYMROOT`, a Release build under `build/`, an old rc — and they
all share the bundle id `dev.overture.Overture`. `open`, the Dock and ⌘-Tab
hand focus to whichever LaunchServices saw last, so double-clicking your new
build can silently focus a stale one and you end up testing the wrong binary.

**Do not build a DMG to try a change.** A DMG is a distribution wrapper: it
needs a full signed Release build, `hdiutil`, and for anything you hand to
someone else, notarization. `scripts/release.sh` exists for that and is not
part of the edit-run loop. Xcode's ⌘R is fine too — it handles the quit and
relaunch itself.

### Cleaning up

```bash
scripts/clean.sh --dry-run   # show what would go
scripts/clean.sh             # delete it
```

Removes `.build*`, `build/` and `dist/` — all gitignored and regenerable.
Build output reaches a couple of gigabytes quickly, mostly DerivedData and
the per-agent SwiftPM scratch dirs. It refuses to run while Overture is
running from inside the repo, because `run-local.sh` launches out of `build/`
and deleting a live app bundle leaves the process running with its resources
pulled out from under it.

### Tests

`swift test` runs 85 unit tests with no network and no `claude` needed. Live
tests are opt-in because they spawn the real CLI and cost the maintainer's
subscription:

```bash
OVERTURE_LIVE_TESTS=1 OVERTURE_MINIMAL_CLAUDE_ENV=1 swift test
```

Never put the minimal-env flag on a product spawn — product sessions must load
the user's full config.

The dev-server test's readiness timeout is 45s deliberately: a login shell on a
cold CI runner spends ~10s sourcing its profile before `python3` is reached, so
the port only opens at ~12s. It is a ceiling, not a wait.

---

## Releasing

Full procedure in [docs/RELEASING.md](docs/RELEASING.md). In short: everything is
driven by pushing a `v*` tag, which runs the signed + notarized pipeline in CI.

Notarization uses an **App Store Connect API key**, not an Apple ID and
app-specific password — app-specific passwords are revoked wholesale whenever
the Apple ID password changes, and Apple reports that as a bare
`HTTP 401 Invalid credentials`.

Required repository secrets: `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`,
`NOTARY_KEY_P8_BASE64`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`,
`SPARKLE_ED_PRIVATE_KEY`. Set single-token secrets with `printf`, never `echo` —
`gh secret set` stores stdin verbatim and a trailing newline breaks
authentication in a way that is very hard to diagnose.

To verify a published build:

```bash
xcrun stapler validate ~/Downloads/Overture-<version>.dmg   # notarization ticket
spctl -a -vvv -t exec /Applications/Overture.app            # what Gatekeeper runs
```

Do **not** use `spctl --context context:primary-signature` on the DMG unless the
image itself was codesigned — it reports `rejected / no usable signature` for a
perfectly good stapled build.
