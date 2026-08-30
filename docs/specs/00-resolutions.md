# Design Resolutions

Authoritative record of decisions resolving the defects found in
[05-review.md](05-review.md). **Where a resolution here conflicts with specs
01–04, this document wins.** Numbering follows the review.

## Blockers

**#1 — Plan→Execute worktree handoff.** Worktrees are created at **Plan entry**,
and the plan session runs read-only *inside the worktree*. Plan approval flips
permission mode in-process (`set_permission_mode` → acceptEdits) with no cwd
change. The "no worktree until execution" optimization applies only to
single-dir mode, where cwd never changes. Worktree removed on Abandon.

**#2 — One persistence layer.** Single global SwiftData store at
`~/Library/Application Support/Overture/Overture.store`. No per-repo
`board.db`. Anything Overture writes inside a repo (`.overture/worktrees/`) is
excluded via `.git/info/exclude`, never the project's `.gitignore`. Per-project
export/import is post-launch roadmap.

**#3 — Permission mechanism is gated by M0.** The `can_use_tool` control
protocol (enabling flag `--permission-prompt-tool stdio` + wire shapes) is
unproven. First coding task (M0) replicates the pinned
`@anthropic-ai/claude-agent-sdk` spawn args as contract-of-record with an
explicit go/no-go gate. Documented fallback, proven in the same spike: a local
stdio MCP server exposing an approval tool, passed as
`--permission-prompt-tool mcp__overture__approve`. Every spawn recipe that
needs UI-surfaced permissions includes the enabling flag.

**#4 — Run vs turn.** In streaming mode a `result` arrives per *turn*.
`BoardEngine` column transitions fire on `result` only for autonomous-execution
runs — the supervisor tracks a `runKind` (interactiveChat | plan |
autonomousRun | testRun) set when the run starts. Interactive chat turns never
move cards.

## Majors

**#5 — Transcript paths.** cwd encoding replaces **every non-alphanumeric**
char with `-`, is non-injective, and truncates+hashes >200 chars — so derive
the candidate, then **glob `~/.claude/projects/*/<sessionID>.jsonl`** and store
what is found. `SessionRef` holds a *list* of `(cwd, transcriptPath, from, to)`
segments (resume can move where new lines land). M0 verifies
resume-from-new-cwd placement empirically.

**#6 — Schema V1 reconciliation.** Before any code, `OvertureSchemaV1` absorbs
every field spec 04 requires: `Card.model`/`effort`, `baseRef`, full `subState`
enum (idle, drafting, planning, awaiting-approval, running, queued,
needs-input, interrupted, testing-running, manual, tests-failed,
merge-conflict, error), `archivedAt`, `fixCycleCount`; `TestRun.verdict`
includes `manual-pass` + `failures[]`; `Project` gains `testCommand`,
`readyPattern`, `agentTestingEnabled`, `autoFixOnTestFailure`, per-run/draft/
test budget caps, `mergeStrategy`.

**#7 — Quit behavior.** "Interrupt & Quit" (wait ≤10 s, then SIGTERM) or
Cancel. No headless agents surviving app quit in v1 — the CLI's own
`--bg` / `claude agents` is the sanctioned roadmap path. The orphan journal
still reconciles state on relaunch and offers batch resume.

**#8 — Vercel previews need a pushed branch.** Explicit "Push branch for
preview" action; opt-in auto-push on Testing entry. Branch naming is the
suffixed, collision-safe form everywhere: `overture/<card-slug>-<id8>`.

**#9 — Correct Apple APIs.** Liquid Glass on macOS is `glassEffect(_:in:)` +
`GlassEffectContainer` (spec 03 is canonical; spec 02's
`glassBackgroundEffect()` is visionOS-only). `NavigationTransition.zoom` is
treated as unavailable on macOS until the SDK proves otherwise; the tile→board
morph has a `matchedGeometryEffect`/custom-transition fallback designed up
front.

**#10 — Chat permission mode.** Spec 01 §3.3's profile table is canonical:
interactive chats run `manual` (Overture owns approvals);
`Project.claudePermissionMode` configures the **autonomous** profile only.

**#11 — Session collision defense.** Single app instance enforced; advisory
per-session lock in the orphan journal; if the transcript tailer sees foreign
writes to a session a supervisor owns, pause and surface "this session is open
elsewhere."

**#12 — Onboarding.** First-run checklist: claude binary discovery (Homebrew,
npm/nvm, `~/.claude/local`) → minimum-version check → **auth probe** (`claude`
auth subcommand) → git/gh/vercel presence (per-feature degradation) → and a
per-project **trust gate** shown before the first spawn in any new directory
(`-p` skips workspace trust and runs untrusted `.claude` hooks / MCP servers).

**#13 — Budget model.** Tokens primary, dollars secondary and gated on auth
type; `--max-budget-usd` behavior under OAuth is verified in M0 before any
$-denominated UI ships. Subscription-side runaway brakes: turn caps + the
unanswered-permission auto-deny timer.

**#14 — Card detail surface.** The five-tab sheet (Chat / Diff / Preview /
Tests / Activity) is canonical; ⌘⏎ pops it into its own window. The
`.inspector` variant is post-launch.

**#15 — No FSEvents on agent dirs.** Diff stats, dirty state, and
overlapping-file detection are recomputed on supervisor milestones
(tool-result events, turn `result`) and on card-detail open / Review entry —
never by watching worktrees during runs.

## Minors

- **#16** Done always requires an explicit approval act; the Testing→Done drag
  runs the same Done pipeline (merge sheet), restating the invariant as "Done
  requires approval," not "Review column is mandatory."
- **#17** Tags are **per-project**; spec 03's 11-color palette is the sole
  color authority; one default set: `bug`(red), `feature`(blue), `chore`(gray),
  `refactor`(purple), `docs`(cyan), `urgent`(orange), `design`(pink),
  `test`(teal), `perf`(amber), `idea`(green).
- **#18** `git fetch` happens only inside a user-initiated merge action.
- **#19** Ticket drafting recipe (single): `claude -p --output-format json
  --json-schema {title,body,suggestedTags[]} --tools "Read,Glob,Grep"
  --no-session-persistence --setting-sources ""` in the project cwd; no
  `--bare` under OAuth; not plan mode; never becomes the card's session.
- **#20** Test sessions exclude Edit/Write via `--tools` (removed from the tool
  set) + `manual` mode with a Bash allowlist — not deny rules alone.
- **#21** Third-party marks excluded from the MIT grant via NOTICE; text labels
  where brand guidelines disallow redistribution.
- **#22** Resolved by renaming Maestro → **Overture**.
- **#23** Icon table artifacts resolved: commit = `smallcircle.filled.circle`;
  preview pane = `macwindow.on.rectangle`.
- **#24** High-contrast detection uses `bestMatch(from:)` over all four
  appearance names (aqua, darkAqua, and both HighContrast variants) — never
  string-matching after a two-name bestMatch.
- **#25** Orphan detection: the journal (+ `proc_pidpath` + start-time PID-reuse
  guard) is primary, implemented once in ProcessCore; env-marker scan is
  diagnostics only.
- **#26** Dev-server command is a template with a `{port}` placeholder (env
  `$PORT` injection alone is insufficient — e.g. Vite).
- **#27** Notification "Reply…" when the supervisor was idle-terminated:
  respawn with `--resume`, wait for `system/init`, then send the message.
- **#28** One global "continue while I'm away" toggle governs all unattended
  automation (auto-fix, auto-resume-after-limit); **both default off in v1**;
  every unattended action logged to ActivityEvent.
- **#29** Swift 6 language mode implies strict concurrency (no redundant
  flag); Sparkle EdDSA private key lives only in CI secrets with a documented
  rotation procedure.

## Additional flags surfaced by the review (roadmap inputs)

`--forward-subagent-text` (subagent visibility), `--bg` / `claude agents`
(background agents that survive app quit), `claude auth` (onboarding probe).
