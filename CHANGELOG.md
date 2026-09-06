# Changelog

All notable changes to Overture are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Sign in to Claude Code from inside Overture. The app starts your own
  `claude auth login`; the browser talks to the CLI's own callback and no
  credential passes through Overture. Signing in from a terminal is always
  offered as an alternative.
- A Settings window with panes, and a Claude pane showing your account, the
  CLI path (with an override), the config directory, and **which credential
  your agents will actually use** — including a warning when something in the
  environment overrides your signed-in account.
- Sign out, behind a confirmation that explains it signs the CLI out for every
  app on the Mac.
- A first-run window explaining what Overture needs, with a specific fix for
  each failure and a way past it. It re-checks when you switch back to the app,
  so installing the CLI or signing in elsewhere resolves it without a click.

### Fixed

- `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_USE_BEDROCK`/`_VERTEX`/`_FOUNDRY` and
  `CLAUDE_CODE_OAUTH_TOKEN` were stripped from every spawned `claude` process
  by an over-broad environment filter. Bedrock, Vertex and Foundry users were
  broken outright, and a custom config directory made Overture look for
  transcripts — and sign in — in the wrong place.
- A failed sign-in showed an empty box. The CLI reports login failures on
  stderr, which was never read, and its "paste code" prompt has no trailing
  newline so it never reached the UI at all.
- An expired or rejected credential mid-run surfaced as a generic error.
  It now stops the run with a specific message and offers a sign-in.
- A probe that could not run was reported as "you are not signed in".
- Dollar figures were shown as estimates for subscription accounts even when
  an API key in Overture's environment meant real per-token billing.

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
