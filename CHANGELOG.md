# Changelog

All notable changes to Overture are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — 2026-09-06

First public release. Pre-1.0: expect breaking changes.

### Added

- **Kanban board where cards are Claude Code sessions.** Plans stream into
  **Plan**, running agents live in **In Progress**, finished work lands in
  **Review**, and you mark it **Done**. Any conversation can be continued at
  any time; reopening a Done card flies it back to In Progress.
- **Project tiles** with live agent progress, git status, and last-chat
  previews, including for projects opened outside Overture.
- **Two execution modes per project** — a git worktree per card (parallel
  agents, branch and PR per card) or single-directory with a visible queue.
- **Testing column** with agent-driven test runs and strict pass/fail verdicts,
  plus an embedded preview pane that runs the card's own worktree code.
- **GitHub integration** via your existing `gh` CLI.
- **⌘K command palette**, overlap warnings, diff-stat caching, auto-archive,
  and VoiceOver announcements throughout.
- **Sparkle auto-updates**, EdDSA-signed and delivered over HTTPS.

### Notes

- Requires macOS 26+ on Apple Silicon, and your own signed-in `claude` CLI.
- A Vercel deployment-status integration (VercelKit) is built but not yet
  surfaced in the UI; it lands in a follow-up release.

[Unreleased]: https://github.com/omerburakpolat/overture/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/omerburakpolat/overture/releases/tag/v0.1.0
