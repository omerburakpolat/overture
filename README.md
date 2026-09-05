# Overture

**A native macOS Kanban harness for Claude Code.** Project tiles show live agent
progress, git status, and Vercel deployments; each project opens into a board
where cards *are* Claude Code sessions and move themselves — plans stream into
the **Plan** column, running agents live in **In Progress**, finished work lands
in **Review**, and you mark it **Done**. Continue any conversation at any time;
a Done card flies back to In Progress.

> Status: pre-release, under active development. Nothing here is stable yet.

- **Native**: Swift 6 / SwiftUI, macOS 26+ (Apple Silicon), Liquid Glass design
  language, a single third-party dependency (Sparkle, for updates).
- **Integrations at launch**: Claude Code and GitHub (via `gh`). A Vercel
  deployment-status integration is built (VercelKit) and lands post-launch.
- **Execution modes per project**: a git worktree per card (parallel agents,
  branch + PR per card) or single-directory with a visible queue.
- **Testing built in**: a Testing column, an embedded preview pane running the
  card's own worktree code, and agent-driven test runs with strict verdicts.

Overture drives **your own installed `claude` CLI with your own login** — it
never bundles, redistributes, or proxies Claude Code or your credentials
(see [NOTICE](NOTICE)).

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

## License

MIT — see [LICENSE](LICENSE). Name, icon, and third-party marks excluded; see
[NOTICE](NOTICE).
