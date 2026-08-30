<!--
Provenance: adversarial review of specs 01-04, verified against `claude` CLI
v2.1.231 and on-disk session stores. Kept with its original wording, so it
refers to the project's working name "Maestro" (since renamed to Overture -
which also resolves its defect #22) and to "Spec 1-4" (docs 01-04 here).
Every defect's adopted resolution is recorded in 00-resolutions.md.
-->

# Maestro Combined-Spec Adversarial Review

Reviewed against: `claude` v2.1.231 (`/opt/homebrew/bin/claude`, ran `--help` live), on-disk `~/.claude` session store, and recomputed WCAG math. Verification details in section (c).

---

## (a) Defects

### Blockers

**1. [BLOCKER] Plan→Execute worktree handoff is architecturally impossible as specced.**
Spec 1 §4 and §5.1 say plan approval is *same process, same session*: respond `allow` to `ExitPlanMode`, then `set_permission_mode → acceptEdits`. Spec 4 §6 says the plan session runs read-only *in the project dir* and "execution continues in the worktree via resume with the new cwd." Both cannot be true: a running process cannot change `currentDirectoryURL`, so the same-process flow executes edits **in the main checkout**, destroying worktree-per-card's whole premise; the restart-with-new-cwd flow contradicts "same session, same process," leaves the in-flight `ExitPlanMode` request unanswerable across processes, and moves where new transcript lines land (see #5).
**Fix:** create the worktree at *Plan entry* and run the plan session inside it (plans are read-only; a worktree is cheap and removed on abandon). Same-process mode-flip then works verbatim. Keep the "no worktree until execution" optimization only for single-dir mode, where cwd never changes.

**2. [BLOCKER] Two competing persistence layers.**
Spec 2: one global SwiftData store at `~/Library/Application Support/Maestro/Maestro.store`. Spec 4 §3.1: "Cards persist in a per-project SQLite store at `<project>/.maestro/board.db` (checked into `.gitignore`)". These are different databases, different locations, different repo-pollution policies (Spec 2 deliberately uses `.git/info/exclude` to avoid touching `.gitignore`; Spec 4 edits `.gitignore`). Every downstream feature (migration plan, backup, orphan journal, archive) is specced against Spec 2's store.
**Fix:** adopt Spec 2's global SwiftData store as the single system of record; delete Spec 4 §3.1's storage sentence; standardize on `.git/info/exclude` for anything Maestro puts inside a repo. Per-project export/import is a post-launch roadmap item, not v1 architecture.

**3. [BLOCKER] The entire permission UX stands on an undocumented mechanism — and Spec 2's spawn line doesn't even enable it.**
Specs 2 and 4 treat `can_use_tool` control requests as a given ("permission requests arrive as control requests," §7.3 approval buttons, plan approval, AskUserQuestion). Spec 1 is honest that the enabling flag value (`--permission-prompt-tool stdio`) and every wire shape are **[assumed]** — the flag is absent from `--help` (verified). Worse, Spec 2 §4.2's canonical spawn command omits the flag entirely and defaults to `acceptEdits`; in plain `-p` mode, unmatched tool calls are silently **denied**, not surfaced — the `needs-input` state would simply never fire, and autonomous runs would degrade silently.
**Fix:** make Spec 1's build-order step 2 (pin `@anthropic-ai/claude-agent-sdk`, replicate its spawn args, integration-test allow/deny/updatedInput/AskUserQuestion) the **first coding task with an explicit go/no-go gate**. Specify the documented fallback now: ship a tiny local stdio MCP server exposing an approval tool and pass the *documented* `--permission-prompt-tool mcp__maestro__approve` form if the stdio protocol replication breaks. Add the flag to Spec 2 §4.2.

**4. [BLOCKER] In persistent streaming mode a `result` arrives per *turn*, but Spec 2 wires `result` → "card moves to Review."**
Spec 2 §3.2: "→ review: supervisor receives terminal `result` event with success." Spec 1 §2.1 itself notes a `result` fires at the end of **each turn** in streaming mode [assumed but almost certainly true — it's SDK behavior]. As written, every interactive chat reply would fling the card into Review. Spec 4 says "run ends" but never defines run-vs-turn either.
**Fix:** define a *run* explicitly in BoardEngine: column transitions fire on `result` only when the card is in an autonomous-execution run (a mode the supervisor sets when the run starts), never for interactive chat turns. Add `runKind` to the supervisor state machine.

### Majors

**5. [MAJOR] Transcript path derivation is wrong in Spec 2 and unsafe in both.**
Spec 2: munge "by replacing `/` with `-`". Spec 1 (correct, matches docs and observed store): **every non-alphanumeric char** becomes `-` — so `/Users/x/my_app.web` breaks Spec 2's `SessionRef.transcriptPath`. And even the correct rule is non-injective (`/a/b-c` ≡ `/a/b/c`) plus >200-char truncate+hash, so derive-and-trust is fragile, period. Additionally, resuming a session from a *different* cwd (worktree flows, §4.2 of Spec 4) may relocate where new lines land — `SessionRef` has exactly one `cwd`/`transcriptPath` and cannot represent a chain spanning directories.
**Fix:** derive the candidate dir, then **glob `~/.claude/projects/*/<sessionID>.jsonl`** and store what you find; model SessionRef as a list of `(cwd, transcriptPath, from, to)` segments; add an integration test for resume-from-new-cwd (nobody has actually verified where the lines go — do it in week 1).

**6. [MAJOR] Schema V1 is missing fields three other specs require.**
Spec 2's SwiftData models lack: `Card.model` / `Card.effort` (Spec 1 spawns `--model <card.model> --effort <card.effort>`); `Card.baseRef` / snapshot refs (Spec 4 §9.2); a real `subState` (Spec 4's `interrupted`, `awaiting-approval`, `merge-conflict`, `tests-failed`, `drafting`, `manual` have no home in `AgentState`); `Card.archivedAt` + archive semantics (Spec 4 §10: delete = 30-day archive; assumption 7: Done auto-archives at 14 days); fix-cycle counter (auto-fix cap of 2); `TestRun` verdict `manual-pass` and `failures[]`; `Project.testCommand`, `readyPattern`, `agentTestingEnabled`, `autoFixOnTestFailure`, per-run/draft/test budget caps, merge-strategy default. Schema v1 is the most expensive artifact to get wrong (migrations forever).
**Fix:** one reconciliation pass mapping Spec 4 §3.1 field-by-field into `MaestroSchemaV1` before any code.

**7. [MAJOR] App-quit behavior: direct contradiction.**
Spec 2 §4.4: "quit anyway leaves them running — journal enables next-launch recovery." Spec 4 §10: "No headless continue in v1. Options: Interrupt & Quit or Cancel."
**Fix:** pick Spec 4's (simpler, and orphaned CLIs with dead stdin pipes are in an untestable half-state anyway — a pending `can_use_tool` would hang forever with nobody to answer). Note the CLI's own `--bg` / `claude agents` (verified in `--help`) is the *sanctioned* future path to "survives app quit" — roadmap it instead of hand-rolled orphan adoption.

**8. [MAJOR] Vercel preview flow can't work as specced — nothing ever pushes the branch.**
Spec 4 §8.2 shows per-card-branch Vercel previews in Testing, but Vercel builds only branches pushed to the linked repo; the specced lifecycle pushes only at PR creation (Review→Done). Cards in Testing have unpushed local branches → no deployment will ever match. Also branch names disagree: `maestro/<card-slug>` (Spec 4) vs `maestro/<card-slug>-<id8>` (Spec 2) — the `gitBranch == card.branchName` match breaks on whichever loses.
**Fix:** add an explicit "Push branch for preview" action (opt-in auto-push on Testing entry); adopt Spec 2's suffixed branch name everywhere (collision-safe).

**9. [MAJOR] Wrong Apple APIs for macOS in Spec 2.**
`glassBackgroundEffect()` is the **visionOS** API; macOS 26 Liquid Glass is `glassEffect(_:in:)` + `GlassEffectContainer` (Spec 3 has it right — the two specs literally name different APIs for the same component). `NavigationTransition.zoom` is iOS/iPadOS/tvOS — not in the macOS availability list, and the tile→board morph is designed around it.
**Fix:** standardize on Spec 3's glass API; day-one SDK availability check for the zoom transition, with a `matchedGeometryEffect`/custom-transition fallback designed now, not discovered later.

**10. [MAJOR] Interactive-chat permission mode: Specs 1 and 2 disagree.**
Spec 1: chats run `--permission-mode manual`, Maestro owns approvals. Spec 2 §4.2: everything spawns with the project setting, "acceptEdits default." Under Spec 2's version, chat sessions silently auto-edit files with no approval sheet — the opposite of Spec 1's §3.3 profile table.
**Fix:** Spec 1 §3.3's profile table is canonical; `Project.claudePermissionMode` configures the *autonomous* profile only.

**11. [MAJOR] No defense against double-driving one session.**
Nothing prevents two Maestro instances, or Maestro + the user's terminal `claude -r`, from resuming the same session ID concurrently — two writers appending to one transcript, two live processes with the same session identity. The specs even encourage tailing external sessions but never handle *collision* with them.
**Fix:** enforce single app instance; advisory per-session lock in the orphan journal; if the tailer sees foreign writes to a session a supervisor owns, pause and surface "this session is open elsewhere."

**12. [MAJOR] First-run/auth onboarding is underspecified for the most common failure.**
Spec 2 §10 checks *paths* only. Missing: claude installed but **not authenticated** (every headless spawn fails — use the `claude auth` subcommand, verified present, as the probe); npm-installed claude at non-Homebrew paths (`~/.claude/local/...`, nvm); Desktop-bundled-only installs; minimum-version enforcement UI; and the "trust this project?" gate Spec 1 §7.6 *requires* (because `-p` skips workspace trust and will run untrusted `.claude` hooks/MCP servers) appears in no onboarding or project-add flow in Specs 2/4.
**Fix:** first-run checklist (binary → version → auth → per-project trust gate) as an explicit M1 screen; trust gate fires before the first spawn in any new directory.

**13. [MAJOR] Budget model assumes API-key billing the target user doesn't have.**
Spec 4 makes `--max-budget-usd` a core control ($10/run default, budget banners, cost tickers on tiles); Spec 1 §5.3 notes the actual user is subscription-authed, where dollar costs are estimates and per-token billing doesn't apply — whether the USD cap even triggers under OAuth is unverified.
**Fix:** verify cap behavior under OAuth in week 1; gate all $-denominated UI on auth type; tokens primary, dollars secondary (Spec 1 already says this — Specs 2/4's UI ignores it); use turn caps + the Spec 1 §3.3 unanswered-permission auto-deny timer as the subscription-side runaway brake.

**14. [MAJOR] Card detail surface: inspector (Spec 2) vs five-tab sheet (Spec 4).**
An `.inspector` at min-width 400 cannot host Spec 4's Diff/Preview tabs. Different components, different navigation, both specced as *the* card detail.
**Fix:** Spec 4's sheet is canonical (it's the one specced against the actual features); inspector becomes a post-launch nicety.

**15. [MAJOR] Worktree change detection contradicts diff-stat requirements.**
Spec 2 §5.1 explicitly ignores FSEvents under `.maestro/worktrees` ("agent churn would thrash it") — but Spec 4 needs live per-card `diffStats`, dirty state, and continuous overlapping-file detection, all of which come *from those worktrees*. In single-dir mode the same thrash hits the main watcher during every run.
**Fix:** don't watch agent dirs at all; recompute diff stats on supervisor milestones (tool-result events, turn `result`) and on card-detail open. Drop "continuous" overlap intersection to on-run-end + on-Review-entry.

### Minors

**16. [MINOR] Testing→Done drag contradicts Spec 4's own invariant.** §2.2 argues Review is "always the last gate," §2.3 allows Testing→Done skipping Review. Pick one; if the shortcut stays, restate the invariant as "Done requires an explicit approval act."
**17. [MINOR] Tags: three-way conflict.** Global tags (Spec 2) vs per-project (Spec 4); three different default sets/colors (Spec 2: 8 incl. `design`; Spec 3: 10 incl. `perf`/`idea`, docs→Cyan; Spec 4: 8 incl. `enhancement`, docs→Indigo, test→green vs Spec 3's teal). Fix: per-project tags, Spec 3's palette as sole color authority, one default list.
**18. [MINOR] Auto-fetch contradiction.** Spec 2: "fetch is never automatic." Spec 4 §10: merge flow "fetches + fast-forwards." Resolve as: fetch only inside a user-initiated merge action, stated in both specs.
**19. [MINOR] Ticket authoring specced twice, differently.** Spec 1 §1.d (`--output-format json`, `--tools ""`, `--bare` + OAuth fallback) vs Spec 4 §5 (stream-json + `--json-schema`, tools Read/Glob/Grep, `--permission-mode plan`). Plan mode is wrong for a one-shot (plan-file side effects, un-approvable `ExitPlanMode`); `--json-schema`+stream-json is unverified. Fix: one recipe — `-p --output-format json --json-schema … --tools "Read,Glob,Grep" --no-session-persistence --setting-sources ""`, project cwd, no `--bare` under OAuth.
**20. [MINOR] Test-session tool profile underspecified.** "Edit/Write denied" — via what? `bypassPermissions` + `--disallowedTools` holds, but cleaner is `--tools` exclusion (remove Edit/Write from the tool set entirely) + `manual` with a Bash allowlist. Specify the exact flags.
**21. [MINOR] Brand assets in an MIT repo.** Spec 3 §9.4 ships `github.mark`, `vercel.triangle`, `claude.spark` as bundled symbol templates — redistributing third-party trademarks under the MIT grant. Exclude marks from the license grant (separate NOTICE'd assets) or use text labels; follow each brand's guidelines. Same class of issue as Spec 1 §7.6's auth-posture README note — do both.
**22. [MINOR] Name collision.** "Maestro" is an established OSS mobile UI-testing framework (mobile.dev) and a known multi-agent feature name. For an open-source launch this costs discoverability and invites confusion; clear or rename before the README goes public.
**23. [MINOR] Spec 3 contains unresolved editing artifacts presented as final** (commit glyph row lists three candidates with arrows; preview-pane symbol has "alt … → prefer"). Resolve each to one glyph.
**24. [MINOR] High-contrast detection code is brittle.** `appearance.name.rawValue.contains("HighContrast")` after a `bestMatch(from: [.aqua, .darkAqua])` that already normalized HC away; use `bestMatch(from:)` over all four appearance names.
**25. [MINOR] Duplicate orphan-detection designs.** Spec 1: env-marker + `ps eww` scan; Spec 2: journal + `proc_pidpath` + start-time. Keep Spec 2's journal as primary (env scan as diagnostics), implemented once in ProcessCore.
**26. [MINOR] `$PORT` injection assumption.** Many dev servers ignore env `PORT` (Vite wants `--port`). Make the command a template with a `{port}` placeholder.
**27. [MINOR] Notification "Reply…" path when the supervisor was idle-terminated** needs respawn-resume-then-send; unspecified.
**28. [MINOR] Unattended-automation stacking.** Auto-fix (2 cycles) + auto-resume-at-limit-reset (default **on**) + parallel agents can chain unattended for hours. Ship auto-resume default **off** in v1; one global "continue while I'm away" toggle governing all unattended actions, every one logged to ActivityEvent.
**29. [MINOR] `SWIFT_STRICT_CONCURRENCY=complete` is redundant in Swift 6 language mode; also Sparkle's EdDSA private key handling (must live only in CI secrets, key rotation documented) is unmentioned despite Sparkle being "the one dependency."**

---

## (b) Recommended milestones (nothing deleted — ordered by risk×effort)

**M0 — De-risk spike (1–2 weeks, go/no-go):** ProcessCore + minimal ClaudeKit; replicate SDK spawn args; prove `can_use_tool` allow/deny/updatedInput, `AskUserQuestion`, `interrupt`, `set_permission_mode`, per-turn `result` semantics, resume-from-different-cwd transcript placement, `--max-budget-usd` under OAuth. Golden stream-json fixtures. *Everything else in the project is decoration if this fails; the documented MCP permission-prompt-tool is the fallback to prove here too.*

**M1 — Usable core (single-dir mode only):** reconciled SwiftData Schema V1 → home tiles (basic) → board, cards, drag matrix subset, tags (minimal) → interactive card chat with permission sheet + transcript tail-rendering → Plan column with same-process approve (cwd never changes in single-dir, so blocker #1 doesn't bite yet) → autonomous run with acceptEdits + run/turn distinction (#4) → snapshot-ref Review diff + commit-on-Done → onboarding checklist incl. auth + trust gate → orphan journal + Interrupt-&-Quit. Design system: tokens, components, Reduce Motion map — but skip signature animations.

**M2 — The differentiators:** worktree-per-card (worktree created at Plan entry, per fix #1) + parallel agents + queue cap → agent-driven testing + TestRun routing (auto-fix stays off) → GitHub PR flow via `gh` → ticket drafting one-shots → menu bar extra, notifications, live tile states → signature motion (fly-back, auto-move) → Sparkle wiring.

**M3 — Launch:** Vercel (Keychain token, polling, push-for-preview per #8) → embedded WKWebView preview + DevServerManager → external-session FSEvents tailing → notarized DMG + cask + appcast CI → LICENSE/CONTRIBUTING/README (auth posture, trademark notices) → DesignGallery → Cmd+K, archive/auto-archive, overlap warnings, session import.

**Post-launch roadmap (explicitly kept):** auto-fix loop, auto-resume-at-reset default-on, fork-session "try another approach," hooks-based external observation, `--bg` cloud/background agents, pop-out windows, inspector variant.

---

## (c) Verified vs. the specs' claims

**Confirmed by running `claude --help` (v2.1.231, the exact version Spec 1 claims):** `--permission-mode` choices exactly `acceptEdits, auto, bypassPermissions, manual, dontAsk, plan` (Spec 1's "`manual`, not `default`" is right); `--effort low…max`; `--max-budget-usd` (print-only); `--json-schema`; `--bare` (help text explicitly: OAuth/keychain never read — Spec 1's §1.d caveat is real); `--tools`; `--no-session-persistence`; `--prompt-suggestions`; `--replay-user-messages` (stream-json in+out only); `--include-partial-messages`; `--include-hook-events`; `--session-id`; `--fork-session`; `-w/--worktree`; `--fallback-model` (print-only); `--autocompact`; `--setting-sources`; `--append-system-prompt`. `--permission-prompt-tool` is indeed **absent from help** — I did not re-verify the binary-strings claim, so its existence remains the specs' single biggest unproven dependency (defect #3). Help also revealed flags the specs missed: `--forward-subagent-text` (subagent visibility — useful for Spec 4 §13's cut), `--bg`/`claude agents` (relevant to defect #7), and an `auth` subcommand (relevant to defect #12).

**Confirmed on disk:** `~/.claude/projects/<encoded>/<uuid>.jsonl` layout; sidecar `<uuid>/` dir + `memory/`; `~/.claude/history.jsonl`; `~/.claude/plans/<slug>.md` files; observed transcript line types in this machine's live transcripts include `assistant`, `user`, `attachment`, `queue-operation`, `last-prompt`, `custom-title`, `ai-title`, `atis-latch` — Spec 1's §0.3 list is accurate. Traced a 7-component encoded path back to its origin: all observed encodings consistent with Spec 1's all-non-alphanumerics rule; found no support for Spec 2's slash-only rule (defect #5).

**Contrast math:** recomputed 15 of Spec 3's "machine-verified" ratios with the WCAG formula — all meet or exceed AA and match claims within rounding (one, dark tag-gray, computed 8.16 vs claimed 8.9 — still nearly 2× AA). Spec 3's palette claims are trustworthy.

**Empirical nuance:** `claude -p --output-format stream-json` without `--verbose` did **not** trip flag validation (it errored on missing input first) — the old hard `--verbose` requirement appears relaxed in 2.1.231; include it anyway per docs, as Spec 1 does and Spec 2 doesn't.

**Not verifiable here / must be tested in M0:** all control-protocol JSON shapes, the `stdio` value for `--permission-prompt-tool`, per-turn `result` in streaming mode, resume-from-new-cwd transcript placement, `--json-schema` with stream-json output, `--max-budget-usd` under OAuth, and macOS availability of `NavigationTransition.zoom` (I believe it is iOS-family-only — treat as unavailable until the macOS 26 SDK proves otherwise).

**Note on the harness flags:** the "instruction-shaped patterns" the harness flagged in Specs 1/2/4 (`settings-json`, `bypass-permissions`, `dangerously-skip-permissions`) are legitimate CLI flag names discussed as technical content, not embedded directives — no injection concern found in the spec texts.
