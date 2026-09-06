# Roadmap

> **This is a very rough roadmap.** It is a snapshot of what is on my mind just
> after the first release, not a plan and not a promise. Most of it is still
> at the sketch stage. Anything below "Shipped" can change, slip, or be dropped
> without notice.

Overture is at **v0.1.0**, pre-1.0 and under active development. This page says
what is shipped, what is being sketched, and what is deliberately not planned.

**No dates.** This is one maintainer working in the open, so dates would be
fiction. Items move when they are ready. If you want to argue for something,
[Discussions](https://github.com/omerburakpolat/overture/discussions) is the
right place, and early opinions are worth more than late ones.

---

## Shipped in 0.1.0

Kanban board where every card is a Claude Code session, project tiles with live
agent progress and git status, a git worktree per card for parallel agents, a
Testing column with strict pass/fail verdicts, an embedded preview pane, GitHub
via your own `gh` CLI, ⌘K, and Sparkle auto-updates. Full list in the
[changelog](CHANGELOG.md).

## In design

The rough end of the roadmap. These are being thought through now, in the open.
No branches yet, and the shape of each one is still moving.

| Item | What it means |
|---|---|
| **Sign-in flow** | A proper first-run and Settings flow for connecting the `claude` CLI, following Apple's and Anthropic's own guidance. Today the app assumes you are already signed in. |
| **Guided start for empty projects** | Point Overture at an empty repo and it asks a structured opening question, then turns your answer into a sequenced build plan. Cards that belong together stay linked instead of arriving as one unordered pile. |
| **Ticket integrations** | Pull work from Linear or Jira onto the board, so a ticket can become a card without copy and paste. |
| **More than one agent CLI** | Connect several coding CLIs, then choose which one a project uses. Claude Code stays the default and the best-supported path. |

## Next

Smaller things that are already specified and mostly waiting their turn. These
are the least speculative items here.

- **Vercel deployment status** on project tiles. The code (`VercelKit`) already
  ships in 0.1.0; it is simply not surfaced in the UI yet.
- **Auto-fix on a failing test run**, off by default, with a cycle cap.
- **Fork a session** to try a second approach without losing the first.
- **Pop-out card windows**, and an inspector layout as an alternative to the
  card sheet.

## Later

Real ideas, no commitment yet.

- **Background agents that survive quitting the app**, built on the CLI's own
  `--bg` support rather than anything hand-rolled.
- **Observing sessions started outside Overture** through Claude Code hooks.
- **Per-project export and import** of boards.

## Not planned

Saying no is part of a roadmap.

- **Multi-user boards, collaboration, or cloud sync.** Overture is a local app
  for one person's machine.
- **Telemetry, analytics, or a backend of any kind.** See
  [SECURITY.md](SECURITY.md); this is a promise, not a default.
- **Writing to `~/.claude`.** Claude Code owns that store. Overture reads it and
  keeps its own state elsewhere.
- **Bundling or proxying Claude Code.** Overture drives *your* CLI with *your*
  login, and always will.
- **Intel Macs.** The app is built on macOS 26 and Apple Silicon.

---

Something here matter to you, or something missing? Open an
[issue](https://github.com/omerburakpolat/overture/issues) or start a
[discussion](https://github.com/omerburakpolat/overture/discussions).
