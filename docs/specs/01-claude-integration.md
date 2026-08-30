<!--
Provenance: produced 2026-08-27/29 by a multi-agent design workflow driven by
Claude Code, verified against `claude` CLI v2.1.231, live docs, and on-disk
session stores on the primary dev machine. Working name "Maestro" has been
renamed to "Overture" throughout.

Where this document conflicts with 00-resolutions.md, the resolutions win.
Claims tagged [assumed] must be proven or refuted by the M0 spike before code
depends on them.
-->

# Overture × Claude Code — Integration Architecture Spec

**CLI verified against:** `claude` v2.1.231 (Homebrew cask, native arm64 Mach-O at `/opt/homebrew/Caskroom/claude-code/2.1.231/claude`), macOS 26.5, on 2026-08-27.
**Docs verified against:** live `code.claude.com/docs` (`docs.claude.com/en/docs/claude-code/*` 301-redirects there; the old `sdk/sdk-headless` path chains to `/docs/en/headless`).
**Session format verified against:** real transcripts in `~/.claude/projects/` on this machine.

Every claim below is tagged **[verified]** (ran the command / read the file / fetched the doc today) or **[assumed]** (from Agent SDK source knowledge or SDK reference docs; pin and test at build time).

---

## 0. Ground truth from research

### 0.1 Flags that exist in v2.1.231 [verified via `claude --help` / `claude -p --help`]

Relevant subset (both help outputs are identical — `-p` has no separate help):

| Flag | Notes |
|---|---|
| `-p, --print` | non-interactive mode; exit code 0 on success, non-zero on failure |
| `--output-format text\|json\|stream-json` | `-p` only |
| `--input-format text\|stream-json` | `-p` only; realtime streaming input |
| `--include-partial-messages` | token-level `stream_event` chunks; `-p` + stream-json only |
| `--replay-user-messages` | echoes stdin user messages back on stdout as acks; stream-json in+out only |
| `--include-hook-events` | hook lifecycle events in the stream |
| `--permission-mode` | choices: `acceptEdits, auto, bypassPermissions, manual, dontAsk, plan` — **note: `manual`, not `default`** (docs still say `default`; treat `manual` as its CLI name and feature-detect) |
| `--allowedTools / --disallowedTools` | permission-rule syntax, e.g. `"Bash(git diff *)"` |
| `--tools` | restrict the built-in tool set (`""` = none, `"default"` = all) |
| `-r, --resume [id]`, `-c, --continue`, `--fork-session`, `--session-id <uuid>` | session control |
| `--no-session-persistence` | `-p` only; no transcript written |
| `--model`, `--fallback-model` (print-only), `--effort low\|medium\|high\|xhigh\|max` | model/effort |
| `--max-budget-usd` | `-p` only, hard spend cap per run |
| `--json-schema` | structured output with `--output-format json` |
| `--bare` | skip hooks/plugins/CLAUDE.md/keychain; **API-key only** — see §7.6 |
| `--settings`, `--setting-sources`, `--mcp-config`, `--strict-mcp-config`, `--add-dir`, `--append-system-prompt`, `--agents`, `-w/--worktree`, `--autocompact`, `-n/--name`, `-d/--debug`, `--debug-file` | environment control |
| `--dangerously-skip-permissions`, `--allow-dangerously-skip-permissions` | bypass |
| `--prompt-suggestions` | emits `prompt_suggestion` message after each turn in print/SDK mode |

`--permission-prompt-tool` is **absent from `--help` but present in the binary** (20 string occurrences) [verified via `strings`]. It is the documented public mechanism for delegating permission prompts in `-p` mode and the hidden plumbing the official SDKs use.

### 0.2 The stdin/stdout control protocol exists in this binary [verified via `strings`]

The binary contains `control_request`, `control_response`, `control_cancel_request`, `can_use_tool`, `set_permission_mode`, `set_model`, `initialize`, `interrupt`, `hook_callback`, `mcp_message`, `permission_suggestions`, `updatedInput`, `"behavior"`, `request_id`. This is the protocol the official Agent SDKs speak over `--input-format stream-json --output-format stream-json`. The exact JSON shapes below are **[assumed]** from Agent SDK implementation; the names are [verified].

### 0.3 Session storage format [verified by reading real files]

- Path: `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl` where `<encoded-cwd>` = absolute cwd with every non-alphanumeric char replaced by `-` (e.g. `/Volumes/MainOBP/Dev/dungeonmaster` → `-Volumes-MainOBP-Dev-dungeonmaster`); names >200 chars are truncated + hashed [verified: docs + on-disk]. `CLAUDE_CONFIG_DIR` relocates the whole tree [verified: docs].
- Beside each `.jsonl`: a sidecar directory `<session-uuid>/` containing `subagents/`, `tool-results/` (large tool outputs spilled to files), `workflows/`; plus a shared `memory/` dir per project [verified on disk].
- Also relevant: `~/.claude/history.jsonl` (one line per submitted prompt: `{display, pastedContents, timestamp, project, sessionId}`) — a cheap global "recent activity" feed for home-screen tiles [verified].
- The `.jsonl` is **not** the same schema as stream-json output. It is a superset/envelope. Observed line `type`s [verified]:
  - `user` — envelope: `parentUuid`, `isSidechain`, `promptId`, `uuid`, `timestamp`, `sessionId`, `cwd`, `version`, `gitBranch`, `slug`, `permissionMode`, `origin` (`{"kind":"human"}`), `promptSource`, `entrypoint` (`claude-desktop` etc.), and `message: {role, content}` (string or block array). Tool-result user lines add `toolUseResult` and `sourceToolAssistantUUID`.
  - `assistant` — same envelope plus `requestId`, `effort`, and full API `message` (`model`, `id`, `content` blocks incl. `thinking`/`text`/`tool_use`, `stop_reason`, `usage` with `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens`, `output_tokens_details.thinking_tokens`).
  - `attachment` — system reminders (`deferred_tools_delta`, `skill_listing`, `plan_mode` **with `planFilePath`**, `total_tokens_reminder`, …).
  - `queue-operation` (enqueue/dequeue of prompts), `last-prompt`, `custom-title`, `ai-title` (**titles for tiles!**), `atis-latch`, `mode`, and (in other sessions) `summary`/compact markers.
- Lines form a DAG via `uuid`/`parentUuid` (branches happen after edits/forks); `isSidechain: true` marks subagent traffic.
- **Version drift is real and observed on this very machine**: transcripts written by CLI 2.1.246 (Claude Desktop's bundled CLI) coexist with Homebrew CLI 2.1.231 [verified]. Parsers must be tolerant (see §7.1).

---

## 1. Process model

One principle: **Overture is the "SDK host."** For anything interactive, spawn one long-lived CLI process per active session speaking bidirectional stream-json, and keep it attached to the card. For fire-and-forget utility calls, use one-shot `-p` runs. Never scrape the interactive TUI.

All processes are spawned by a Swift `ClaudeProcess` actor (Foundation `Process`), with:

- `currentDirectoryURL` = project dir **or the card's worktree path** (execution-mode dependent). This determines which `~/.claude/projects/<encoded-cwd>/` the transcript lands in.
- Environment: inherit user env + `OVERTURE=1`, `OVERTURE_CARD_ID=<uuid>`, `OVERTURE_PROJECT_ID=<uuid>` (marker vars for orphan reaping, §7.3; also usable in user hooks).
- stdout/stderr piped; NDJSON line-reassembly reader (lines can be very large — 8 KB+ observed; no size assumption).
- Pre-generated `--session-id` (Overture mints the UUID) on first runs so the transcript path is known before the first byte of output [verified flag exists].

### 1.a Interactive card chats — persistent streaming process

**Decision: persistent `--input-format stream-json --output-format stream-json` process per open card chat, NOT per-turn `claude -p --resume`.**

Rationale:
- Per-turn `-p --resume` pays full startup (hooks, MCP connect, settings, plugin sync — often 1–3 s+) on every message; the persistent process pays it once.
- Only streaming-input mode supports: interrupts mid-turn, queued messages, image attachments, mid-session `set_permission_mode`/`set_model`, and the `can_use_tool` permission callback [verified: docs, "streaming input mode is the preferred way… can_use_tool requires streaming mode"].
- Per-turn resume also can't surface permission prompts to a UI at all without an MCP prompt tool (§3).

Flag set:

```
claude -p \
  --input-format stream-json \
  --output-format stream-json \
  --verbose \
  --include-partial-messages \
  --replay-user-messages \
  --session-id <overture-uuid>            # first run; --resume <id> on reattach
  --permission-mode manual \             # Overture owns approvals via can_use_tool
  --model <card.model> --effort <card.effort>
```

(`--verbose` is included because the documented streaming examples pair it with stream-json output [verified: headless docs]; harmless otherwise.)

User turns are written to stdin as NDJSON [verified shape from streaming docs]:

```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"…"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"…"}}]}}
```

The process stays alive between turns. Idle policy: keep alive while the card's chat pane is open; after N minutes idle, terminate gracefully (close stdin → SIGINT if mid-turn → wait → SIGTERM) and reattach later via `--resume <session_id>` — reattach is cheap and lossless because the transcript is on disk. This bounds concurrent memory (each CLI process is a full Node/Bun runtime).

### 1.b Plan-mode sessions (Plan column)

Same persistent process shape, with:

```
--permission-mode plan
```

Plan mode is a permission mode, not a separate binary mode [verified]. Read-only tools run as in `manual`; file edits and shell-writes are **never auto-approved and route to `can_use_tool` even if allow rules match** (shell-write routing requires ≥ v2.1.212) [verified: permissions docs]. `AskUserQuestion` is common in plan mode and arrives through the same callback [verified]. Lifecycle in §4.

### 1.c Autonomous card execution (In Progress)

Same persistent streaming process — **not** a blind one-shot — so that escalations (ask-rules, `AskUserQuestion`, critical-path deletes) can still surface on the card instead of hanging or failing. Differences:

```
--permission-mode acceptEdits            # default autonomous profile
  # OR --permission-mode bypassPermissions   (per-card opt-in, scary-styled UI)
--allowedTools "Bash(git *)" "Bash(npm *)" ...   # project-configurable allowlist
--max-budget-usd <card.budget>           # optional per-card spend cap [verified flag]
--fallback-model sonnet                  # optional resilience [verified flag, print-only]
```

- `acceptEdits` auto-approves Edit/Write + filesystem commands (`mkdir`,`touch`,`rm`,`mv`,`cp`,`sed`) **inside cwd/additionalDirectories only**; other Bash/network still falls through → with no matching allow rule it reaches `can_use_tool` → Overture shows a card-level "Agent needs permission" badge + notification [verified: permission-evaluation docs].
- `bypassPermissions` approves everything except deny rules, explicit ask rules, hooks, and critical-path `rm`/`rmdir` (which still reach the callback) [verified]. Overture must handle `can_use_tool` even in bypass.
- Do **not** use `dontAsk` for card execution: it converts prompts to hard denials and never calls the callback — useful only for Overture's own utility calls.
- The run ends when the `result` message arrives → card animates to Testing/Review. Agent-driven testing is just another prompt/turn in the same session (or a fresh forked session) with test-running tools allowlisted.
- Worktree mode: Overture creates the worktree itself (own git plumbing, so it controls naming/branches) and spawns with cwd = worktree. The CLI's `-w/--worktree` exists [verified] but Overture shouldn't outsource lifecycle it must display.
- Single-dir mode: a per-project serial queue actor guarantees max one running process; queued cards show "queued" state.

### 1.d Ticket-writing assist (Backlog)

One-shot, stateless, cheap, no side effects:

```
claude -p --bare \
  --output-format json \
  --json-schema '{"type":"object","properties":{"title":{"type":"string"},"body":{"type":"string"},"tags":{"type":"array","items":{"type":"string"}},"acceptance_criteria":{"type":"array","items":{"type":"string"}}},"required":["title","body"]}' \
  --tools "" \
  --no-session-persistence \
  --max-budget-usd 0.50
```

Prompt = ticket draft + project context Overture supplies inline. Parse `.structured_output` from the JSON envelope [verified: headless docs]. **Caveat:** `--bare` requires `ANTHROPIC_API_KEY` (it never reads OAuth/keychain) [verified: headless docs]. If the user is subscription-authed (the common case), drop `--bare` and instead use `--setting-sources ""` + `--tools ""` to get near-bare startup with normal auth. For "refine this ticket with codebase context," allow `--tools "Read,Glob,Grep"` and run in the project dir.

---

## 2. Event detection

### 2.1 Stream-json message types Overture must parse (stdout, NDJSON)

| `type` | Meaning / key fields |
|---|---|
| `system`, `subtype:"init"` | First event (after any startup hook/plugin events). Carries `session_id`, model, tools, `mcp_servers[{name,status}]`, `mcp_server_errors` (≥2.1.219), `plugins`/`plugin_errors`, `permissionMode`, and a `capabilities` string array for feature detection (≥2.1.205) [verified: headless docs]. **Card state → Running.** |
| `assistant` | Full assistant API message (`message.content` blocks: `text`, `thinking`, `tool_use`; `message.usage`). `parent_tool_use_id` non-null ⇒ subagent traffic [verified: docs]. |
| `user` | Tool results echoed back (`tool_result` blocks); with `--replay-user-messages`, also acks of Overture's own inputs [verified: help text]. |
| `stream_event` | Token deltas when `--include-partial-messages` is set; `.event.delta.text` etc. — drives live-typing UI and tile progress [verified: docs]. |
| `result` | Terminal event per run: `subtype` (`success` \| `error_max_turns` \| `error_max_budget_usd` \| other error subtypes), `result` text, `session_id`, `total_cost_usd`, per-model usage breakdown, `num_turns`, `duration_ms`, `is_error`, `structured_output` [verified fields: headless + sessions docs; full list assumed from SDK reference]. **Card state → Review (or Error).** In persistent streaming mode a `result` arrives at the end of **each turn**, not just at process exit [assumed from SDK behavior — test]. |
| `system`, `subtype:"api_retry"` | Retry telemetry: `attempt`, `max_retries`, `retry_delay_ms`, `error_status`, `error` category (`rate_limit`, `overloaded`, `billing_error`, …) [verified: docs, full table]. Drives "retrying…" badge + backoff-aware queueing. |
| `system`, `subtype:"plugin_install"` | startup progress [verified]. |
| `prompt_suggestion` | if `--prompt-suggestions` on — can pre-fill the card's chat composer [verified: help]. |
| `control_request` / `control_response` / `control_cancel_request` | Protocol messages, §3 [verified strings; shapes assumed]. |
| hook events | `hook_started`/`hook_progress`/`hook_response` when `--include-hook-events` [verified: docs]. Off by default in Overture. |

State machine per card session:

- **started** = `system/init` received (also gives authoritative `session_id`).
- **working** = any `assistant`/`stream_event` since last `result`.
- **needs-attention** = pending `can_use_tool` control request (§3) or `AskUserQuestion`.
- **finished (turn)** = `result` received → move card per column rules.
- **errored** = `result.is_error` / error `subtype`, or process exit without `result` (crash path, §7.2), or stderr burst + non-zero exit.

### 2.2 Primary mechanism recommendation

**Primary: the stream-json stdout pipe.** Overture owns the process, so the pipe is lossless, ordered, zero-config, and needs no filesystem polling or injected configuration. Everything the Kanban board needs (started/working/needs-permission/finished/errored/cost) is derivable from §2.1.

**Secondary (passive): FSEvents on `~/.claude/projects/`** — not for Overture-spawned sessions, but to make home-screen tiles live when the user runs `claude` in a terminal or Desktop against the same project. Tail new/changed `.jsonl` files, render "last chat" from the trailing `user`/`assistant`/`ai-title`/`custom-title`/`last-prompt` lines. Read-only, version-tolerant (§7.1).

**Not recommended as primary: hooks.** Hooks (`Stop`, `PermissionRequest`, `Notification`, `SessionStart`/`SessionEnd`, HTTP-type hooks posting to a local Overture endpoint — all exist [verified: hooks docs]) would require Overture to inject configuration into user settings or `--settings`, entangle with the user's own hooks, and duplicate what the pipe already provides. Keep hooks as an opt-in v2 for observing *external* sessions with richer fidelity than file-tailing (an HTTP `Notification`/`Stop` hook posting to `localhost:<overture-port>` is the clean shape — hook type `"http"` with `url` is documented [verified]).

---

## 3. Permission handling

### 3.1 Mechanism: `can_use_tool` over the stream-json control protocol

With a persistent streaming process, the CLI can route permission prompts to the host as **control requests on stdout**, and Overture answers on stdin. This is exactly what the official SDKs' `canUseTool` does [verified: user-input docs describe the callback; binary contains `can_use_tool`, `permission_suggestions`, `updatedInput`, `behavior`].

- Enabling it: the SDKs pass the hidden `--permission-prompt-tool stdio` when a `canUseTool` callback is supplied **[assumed** — flag verified present in binary and documented for MCP-tool form; the `stdio` value is from SDK source knowledge. Build-time task: read the pinned `@anthropic-ai/claude-agent-sdk` source and replicate its exact spawn args; it is open source and is the contract-of-record].
- Wire shapes **[assumed — validate against SDK source + integration test]**:

CLI → Overture:
```json
{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"npm test"},"permission_suggestions":[…]}}
```
Overture → CLI (allow / deny):
```json
{"type":"control_response","response":{"subtype":"success","request_id":"r1","response":{"behavior":"allow","updatedInput":{"command":"npm test"},"updatedPermissions":[…]}}}
{"type":"control_response","response":{"subtype":"success","request_id":"r1","response":{"behavior":"deny","message":"User declined"}}}
```

Overture → CLI control requests (same envelope, Overture-generated `request_id`): `interrupt` (Stop button), `set_permission_mode` (plan→acceptEdits transition, "auto-accept" toggle), `set_model` / effort changes mid-session [names verified in binary; semantics verified in SDK docs "During streaming: setPermissionMode / setModel / interrupt"].

### 3.2 UI semantics (mirrors documented callback semantics [verified])

- The callback fires **only** for calls nothing earlier approved. Evaluation order: hooks → deny rules → ask rules → permission mode → allow rules → `can_use_tool` [verified: permissions docs, six-step flow].
- Overture's approval sheet on the card offers: **Allow once** (echo input back as `updatedInput` — required; pre-2.1.207 rejected omission [verified]), **Allow always** (echo back the matching `permission_suggestions` entry with `localSettings` destination → writes rule to `.claude/settings.local.json` [verified]), **Deny with reason** (free-text becomes the `message` Claude sees — doubles as a steering channel [verified]), **Edit & allow** (modify `updatedInput`).
- Requests can stay pending indefinitely; the turn is paused until answered [verified]. Surface as card badge + macOS notification; if the user quits Overture, close stdin/terminate — on `--resume` the turn continues (§7.2).
- `AskUserQuestion` arrives through the same channel with `tool_name == "AskUserQuestion"`; input is `{questions:[{question,header,options:[{label,description}],multiSelect}]}` and the answer is returned via `updatedInput: {questions, answers}` [verified: user-input docs, exact schema]. Render as native question cards, always include a free-text "Other".

### 3.3 Autonomous mode interaction

Per-card permission profile → flag mapping:

| Overture profile | CLI mode | `can_use_tool` traffic |
|---|---|---|
| Ask me (chat default) | `manual` | everything un-allowlisted |
| Plan | `plan` | writes always; `AskUserQuestion`; `ExitPlanMode` |
| Autonomous (default) | `acceptEdits` + project allowlist | non-filesystem Bash, network, out-of-cwd paths |
| Autonomous (full) | `bypassPermissions` | ask-rules, requires-interaction tools, critical-path `rm` [verified these still reach callback] |

Autonomous cards get a policy timer: a `can_use_tool` unanswered for N minutes ⇒ auto-deny with message "Overture: user unavailable; pick a safer approach or finish what you can" — keeps runs from hanging overnight while leaving Claude a path forward. (A `defer` hook decision exists for exit-and-resume-later flows [verified: docs mention]; v2 option.)

Guardrail note [verified: permissions docs]: `allowedTools` does **not** constrain `bypassPermissions`; to block things in full-auto, use `--disallowedTools` (scoped deny rules hold even in bypass). Managed setting `permissions.disableBypassPermissionsMode` may disable bypass entirely — detect via failed mode set and degrade to `acceptEdits`.

---

## 4. Plan-mode lifecycle

1. **Entry.** Card dragged to Plan (or created with "Plan first") ⇒ spawn per §1.b with `--permission-mode plan`. Confirm via `system/init.permissionMode` [assumed field name in init — present in SDK types; fallback: we set it, we know it].
2. **During planning.** Read-only tool stream renders as activity. `AskUserQuestion` → question cards (§3.2). Transcript `attachment` lines of type `plan_mode` carry `planFilePath` (`~/.claude/plans/<slug>.md`) [verified on disk — this very session's transcript]: current builds stream the plan into a markdown file as it's written. Overture watches that file to live-render the draft plan on the card.
3. **Exit request.** Claude calls the `ExitPlanMode` tool (name verified in binary; 24 hits). In `plan` mode it is not auto-approved, so it arrives at `can_use_tool` with the plan content in its input (`plan` field historically; on plan-file builds the file is authoritative) **[shape assumed — capture both: tool input and `planFilePath` contents, prefer the file when present]**.
4. **Approval UI.** Overture renders the plan as the card's "Plan" tab with three actions:
   - **Approve & build** → respond `allow`, then immediately send `set_permission_mode` → `acceptEdits` (or the card's autonomous profile). Card flies Plan → In Progress.
   - **Approve, manual mode** → `allow`, mode stays `manual`; user shepherds the build in chat.
   - **Request changes** → respond `deny` with the user's feedback as `message`; session stays in plan mode and revises. Card stays in Plan.
5. **Persistence.** Snapshot the approved plan markdown into the card record (cards outlive plan files), stamp `planned_at`, keep `planFilePath` for provenance.
6. **Detection redundancy.** If Overture ever renders plan sessions it didn't spawn (file-tailing path), plan entry/exit is recoverable from transcript `permissionMode` fields on user lines + `plan_mode` attachments [verified those exist].

---

## 5. Session management

### 5.1 Card ↔ session mapping

**1 card = 1 session *chain*** (ordered list of session IDs), not exactly one ID:

- First run: Overture mints UUID, spawns with `--session-id <uuid>` → deterministic transcript path immediately [verified flag].
- Every subsequent attach: `--resume <last-id>`. Resuming **continues the same session ID** in-place; **`--resume <id> --fork-session` mints a new ID** with copied history, leaving the original untouched [verified: sessions docs]. Overture records: `card.sessions = [id0, id1(fork)…]`, `card.activeSession`.
- Chain events that append a new ID: explicit "Try a different approach" (fork), "Fresh session with plan as context" (new session, plan pasted), post-compaction continuation (same ID, but record the compact boundary).
- Continuing a **Done** card = `--resume` its last ID (fly-back animation to In Progress). Works from any cwd — since v2.1.223 resume looks up the ID across all projects on the machine [verified: headless + sessions docs] — but Overture still spawns with the correct cwd (project dir or a fresh worktree) because cwd governs permissions scope and where *new* transcript lines land.
- Plan → build uses the **same** session (context continuity is the point); mode flips via control request (§4.4).

### 5.2 Reading history (`~/.claude/projects/`)

- **Card chat rendering:** parse the card's `.jsonl`s directly (schema §0.3): walk the `uuid`/`parentUuid` DAG, take the active branch (last line's ancestry), render `user`/`assistant` messages, group `tool_use`+`tool_result` into collapsible tool rows, hide `attachment`/`queue-operation`/`isSidechain` by default. Large tool outputs may be spilled to the sidecar `tool-results/` dir — treat `toolUseResult` as possibly file-backed [verified dir exists; linkage assumed].
- **Home tiles ("last chat"):** newest `.jsonl` in each project's encoded dir → `custom-title` ?? `ai-title` ?? first-user-message prefix; last message snippet from the trailing `assistant`/`user` line; `last-prompt` line as fallback; mtime for recency. `~/.claude/history.jsonl` as a cross-project index [all verified on disk].
- **Worktrees:** each worktree path encodes to its **own** projects dir. Overture knows every worktree it created and unions those dirs when listing a project's sessions.
- **Import:** on first open of a project, offer to link existing recent sessions to new cards (title + timestamp list).

### 5.3 Cost / token accounting per card

- Per turn/run: `result.total_cost_usd` + per-model usage breakdown [verified: headless docs "includes total_cost_usd and a per-model cost breakdown"]. Accumulate into `card.costLedger` keyed by session ID + turn.
- Token detail (incl. cache read/write and thinking tokens) from `assistant` lines' `message.usage` — available both live (stream) and retroactively (transcript) [verified fields on disk].
- Label costs as **estimates** in UI: docs state client-side estimates may differ from billing; subscription (OAuth) users don't pay per-token at all — show tokens primarily, dollars secondarily [verified caveat in docs].

---

## 6. Model/effort selection, slash commands, MCP

- **Per card:** `--model <alias|full-name>` and `--effort low|medium|high|xhigh|max` at spawn [verified flags]; mid-session via `set_model` / (effort control TBD — `/effort <level>` as a prompt works in print mode ≥2.1.205 [verified: headless docs note]) . Don't hardcode the model list: populate the picker from `claude --help` defaults + a user-editable list; aliases (`opus`, `sonnet`, `fable`) are stable-ish, full IDs drift.
- **Slash passthrough:** send the user's `/command args` verbatim as the user message text — skills/custom commands expand in `-p`/SDK mode [verified: "include /skill-name in the prompt string and Claude Code expands it"]. Terminal-only built-ins (`/login`, `/clear`…) don't work; Overture intercepts a small set (`/model`, `/effort` → control requests; `/clear` → new session for card) and passes everything else through. Custom commands live in `.claude/commands/` and skills in `.claude/skills/` — Overture can list them (read-only dir scan) for autocomplete in the composer.
- **MCP awareness (non-goal to manage):** do **not** pass `--strict-mcp-config`; let the user's `.mcp.json`/settings load normally. Surface `system/init.mcp_servers[].status` and `mcp_server_errors` as passive badges in card detail [verified fields]. MCP tools flow through the same permission pipeline (`mcp__server__tool` names); `requiresUserInteraction`-annotated tools always reach `can_use_tool` [verified]. First-turn wait: with `--mcp-config`, the CLI waits for pending servers up to `MCP_TIMEOUT` (30 s default) before turn 1 [verified] — show "connecting tools…" instead of a frozen spinner.

---

## 7. Failure modes & risks

### 7.1 CLI version drift (the top risk)

- Observed today: two CLI versions writing to the same store (2.1.231 Homebrew, 2.1.246 Desktop-bundled) [verified]. Docs are versioned by behavior gates ("requires ≥2.1.x") roughly weekly.
- Mitigations: (1) run `claude --version` at startup; enforce a tested minimum, warn on untested-newer, never hard-block. (2) Feature-detect via `system/init.capabilities` (≥2.1.205), never version-string compare [verified mechanism]. (3) Tolerant parsers everywhere: unknown NDJSON `type`s/fields are ignored, never fatal; every transcript line carries its writer `version` for diagnostics. (4) The stream-json + control protocol is the SDK's own contract — the least likely surface to break silently; the **transcript `.jsonl` is undocumented internal format** and is Overture's most fragile dependency → isolate in one `TranscriptDecoder` module with fixture tests against multiple versions, and degrade tiles to "history unavailable" rather than crash. (5) CI job replaying golden sessions against `claude@latest` nightly.
- The `manual`-vs-`default` mode-name discrepancy [verified] is a live example: accept both, prefer what `--help` advertises at runtime (parse the choices list).

### 7.2 Crashed / killed processes

- Exit without `result` ⇒ card → Error state with stderr tail. SIGTERM ⇒ exit 143, in-flight turn unfinished but **resumable** — resume continues the interrupted turn [verified: headless docs]. Graceful stop order: send `interrupt` control request (ends turn cleanly) → close stdin → SIGINT → SIGTERM after grace. Background Bash tasks the agent started are killed ~5 s after result/stdin-close [verified] — relevant for dev-server preview: Overture should run preview servers itself, not via the agent's shell.
- App crash/quit: card state + PID + session ID persist in Overture's store; on relaunch, orphan scan (§7.3) then offer "Resume" per card.

### 7.3 Orphaned processes & sessions

- Tag every spawn with `OVERTURE_CARD_ID` env; on launch, scan running `claude` processes (`pgrep` + env inspection via `ps eww`) for the marker; reattach is impossible mid-process (stdio is gone) ⇒ terminate gracefully and `--resume` fresh. Orphaned *sessions* (transcripts with no card) are harmless; offer linking (§5.2).
- Stale locks/queues: the `queue-operation` transcript lines imply CLI-side prompt queueing; Overture should never write to transcript files (read-only, always).

### 7.4 Rate limits / usage caps

- Signals: `system/api_retry` with `error: rate_limit|overloaded|billing_error` [verified schema]; error `result` subtypes; `StopFailure` hook matcher list confirms categories (`rate_limit`, `overloaded`, `authentication_failed`) [verified: hooks docs].
- Response: pause the project's autonomous queue on `rate_limit`, exponential backoff using `retry_delay_ms`, banner on the board ("Claude usage limit — resuming at ~HH:MM" when derivable), never auto-retry `billing_error`/`authentication_failed` (surface to user). Per-card `--max-budget-usd` prevents runaway spend on API-key auth; `error_max_budget_usd` result ⇒ card → Review with "budget exhausted" note, resumable with a raised cap [verified subtype].

### 7.5 Concurrency limits

- Each persistent process is a full runtime (~100–300 MB) plus its MCP children. Cap concurrent live processes (default 3–4; configurable); LRU-detach idle chats (§1.a) — reattach is cheap. Single-dir projects: hard cap 1 via the queue actor. Parallel worktrees also multiply MCP server instances (each session spawns its own stdio servers) — warn in project settings when heavy MCP configs meet high parallelism. API-side concurrent limits surface as `overloaded`/`rate_limit` retries (§7.4).

### 7.6 Auth & policy

- Subscription (OAuth/keychain) auth is what this user has; it flows through normally in non-bare mode — but `--bare` breaks it (API-key only) [verified], hence §1.d's fallback. Anthropic's docs state third-party products may not offer claude.ai login/rate limits without approval [verified note on SDK overview]; Overture's posture — an open-source local harness driving the **user's own installed CLI and existing login**, never proxying auth — is the same category as other OSS harnesses, but the README should state this and the project should avoid bundling/redistributing the CLI.
- `-p` mode skips the workspace-trust dialog and **will run a project's `.claude/settings.json` hooks and `.mcp.json` servers in untrusted folders** [verified: headless docs warning]. Overture adds its own first-open "Trust this project?" gate before ever spawning in a new directory.

### 7.7 Stream/pipe hygiene

- Piped stdin capped at 10 MB [verified] — large pastes/images: write to a temp file and reference by path instead. Slow stdout consumers: CLI waits up to 30 s for drain at exit [verified] — Overture's reader must never block the pipe (dedicated reader task, ring buffer to UI). NDJSON lines have no size bound (multi-MB tool results): reassemble by `\n` only, stream-parse.
- Duplicate-delivery: after crash-resume, the first events replay context; dedupe UI rendering by message `uuid`.

---

## 8. Build-order checklist (integration layer only)

1. `ClaudeProcess` actor: spawn/attach/terminate, NDJSON codec, typed `ClaudeEvent` enum (tolerant decoding).
2. Control-protocol client: pin the current `@anthropic-ai/claude-agent-sdk` release as contract-of-record; replicate spawn args + `initialize` handshake; integration tests: interrupt, set_permission_mode, can_use_tool allow/deny/updatedInput, AskUserQuestion round-trip. **(Resolves every [assumed] item above.)**
3. `TranscriptDecoder` + FSEvents tailer (tiles, history import).
4. Permission UI + per-card profiles; plan lifecycle (§4).
5. Queue/concurrency actors; cost ledger; failure-mode handlers (§7).
