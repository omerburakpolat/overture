# Overture

**A native macOS Kanban harness for Claude Code.** Project tiles show live agent
progress, git status, and last-chat previews; each project opens into a board
where cards *are* Claude Code sessions and move themselves — plans stream into
the **Plan** column, running agents live in **In Progress**, finished work lands
in **Review**, and you mark it **Done**. Continue any conversation at any time;
a Done card flies back to In Progress.

[![CI](https://github.com/omerburakpolat/overture/actions/workflows/ci.yml/badge.svg)](https://github.com/omerburakpolat/overture/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/omerburakpolat/overture?include_prereleases&sort=semver)](https://github.com/omerburakpolat/overture/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B%20(Apple%20Silicon)-black?logo=apple)](#requirements)

> **Status: pre-release, under active development.** Nothing here is stable yet.
> Expect breaking changes between versions.

## Download

```bash
brew install --cask omerburakpolat/tap/overture
```

Or grab the signed and notarized DMG from the
**[Releases page](https://github.com/omerburakpolat/overture/releases/latest)**,
open it, and drag Overture to Applications. Either way the app updates itself
from then on via [Sparkle](https://sparkle-project.org).

Every release is signed with a Developer ID certificate and notarized by Apple,
so Gatekeeper opens it without a warning. Verify for yourself if you like:

```bash
xcrun stapler validate ~/Downloads/Overture-*.dmg
```

That confirms Apple's notarization ticket is attached to the image. Once you
have copied the app across, this checks the app Gatekeeper will actually run:

```bash
spctl -a -vvv -t exec /Applications/Overture.app
```

### Requirements

- **macOS 26 (Tahoe) or later, Apple Silicon.** Overture uses the Liquid Glass
  design language and Swift 6.2 concurrency; there is no Intel build.
- **The [`claude` CLI](https://claude.com/claude-code), installed and signed in.**
  Overture drives *your own* CLI with *your own* login — it never bundles,
  redistributes, or proxies Claude Code or your credentials (see [NOTICE](NOTICE)).
- **`git`**, and **[`gh`](https://cli.github.com)** if you want the GitHub
  integration.

## What it does

- **Native**: Swift 6 / SwiftUI, macOS 26+, Liquid Glass, a single third-party
  dependency (Sparkle, for updates).
- **Integrations at launch**: Claude Code and GitHub (via `gh`). A Vercel
  deployment-status integration is built (VercelKit) and lands post-launch.
- **Execution modes per project**: a git worktree per card (parallel agents,
  branch + PR per card) or single-directory with a visible queue.
- **Testing built in**: a Testing column, an embedded preview pane running the
  card's own worktree code, and agent-driven test runs with strict verdicts.

### A word on what agents can do

Cards are Claude Code sessions with real tool access — they run commands and
change files. Worktree mode gives each card its own branch and directory, which
limits the blast radius but is **not** a security boundary. Review diffs before
you merge them. See [SECURITY.md](SECURITY.md) for the full threat model.

## Building from source

```bash
git clone https://github.com/omerburakpolat/overture.git
cd overture
swift build                # all six library targets
swift test                 # 85 unit tests — no network, no claude needed
open Overture.xcodeproj    # the app target
```

Requires Xcode 26+. See [CONTRIBUTING.md](CONTRIBUTING.md) for the module
layout and the rules of the road.

## Documentation

Design and architecture specs live in [docs/specs/](docs/specs/):

| Doc | Contents |
|---|---|
| [00-resolutions.md](docs/specs/00-resolutions.md) | Authoritative design resolutions — supersedes the specs where they conflict |
| [01-claude-integration.md](docs/specs/01-claude-integration.md) | Driving the `claude` CLI: stream-json, control protocol, permissions, sessions |
| [02-architecture.md](docs/specs/02-architecture.md) | App architecture, SPM modules, SwiftData model, process supervision |
| [03-design-system.md](docs/specs/03-design-system.md) | OvertureDesign: tokens, color, type, motion, components, accessibility |
| [04-product-behavior.md](docs/specs/04-product-behavior.md) | Kanban mechanics, card lifecycle, drag matrix, testing & review flows |
| [05-review.md](docs/specs/05-review.md) | Adversarial review of the above (defects → resolutions) |
| [06-m0-findings.md](docs/specs/06-m0-findings.md) | Protocol spike results — every claim proven against the live CLI |

Release process: [docs/RELEASING.md](docs/RELEASING.md).
Version history: [CHANGELOG.md](CHANGELOG.md).
A rough roadmap, including what is *not* planned: [ROADMAP.md](ROADMAP.md).

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md)
and the [Code of Conduct](CODE_OF_CONDUCT.md). Questions and ideas belong in
[Discussions](https://github.com/omerburakpolat/overture/discussions).

## License

MIT — see [LICENSE](LICENSE). Name, icon, and third-party marks excluded; see
[NOTICE](NOTICE).

Overture is an independent open-source project. It is not affiliated with,
endorsed by, or sponsored by Anthropic, GitHub, or Vercel.
