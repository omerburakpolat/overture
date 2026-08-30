# M0 De-Risk Spike — Findings

**Verdict: GO.** Every [assumed] protocol claim in
[01-claude-integration.md](01-claude-integration.md) was proven live against
`claude` v2.1.231 on 2026-08-29 using [spikes/m0/harness.py](../../spikes/m0/harness.py).
Raw NDJSON captures (both directions) are in `spikes/m0/fixtures/` and seed
ClaudeKit's golden tests. Contract-of-record: `@anthropic-ai/claude-agent-sdk`
**0.3.251** (proprietary — kept as a local dev reference only, never vendored;
facts documented here independently).

## Proven claims

| # | Claim | Status | Evidence |
|---|---|---|---|
| 1 | SDK base spawn args are `--output-format stream-json --verbose --input-format stream-json` | **Confirmed** | sdk.mjs arg assembly |
| 2 | `canUseTool` is enabled by `--permission-prompt-tool stdio` | **Confirmed** | sdk.mjs: `Z.push("--permission-prompt-tool","stdio")`; live `can_use_tool` received |
| 3 | `can_use_tool` request shape `{tool_name, input, permission_suggestions?, blocked_path?, decision_reason?, decision_reason_type?, classifier_approvable?}` | **Confirmed live** | fixture `a-permissions.jsonl` |
| 4 | Response shape `{type:"control_response", response:{subtype:"success", request_id, response:{behavior:"allow", updatedInput}\|{behavior:"deny", message, interrupt?}}}` | **Confirmed live** | allow executed the tool; deny's `message` steered the model (`updatedInput` is *optional* in SDK 0.3.251 typings, but we always echo it) |
| 5 | `result` arrives **per turn** in streaming mode | **Confirmed live** | 3 results, 1 process — validates resolution #4 (`runKind` gating) |
| 6 | `interrupt` control request ends the turn | **Confirmed live** | ack `{still_queued:[]}` then `result subtype=error_during_execution, is_error=true` |
| 7 | `set_permission_mode` flips mid-session | **Confirmed live** | after flip to `acceptEdits`, Write ran with **no** permission request |
| 8 | Plan mode: `ExitPlanMode` arrives as `can_use_tool` with **both** `input.plan` (markdown) and `input.planFilePath` | **Confirmed live** | fixture `c-plan.jsonl`; approve + mode-flip continued the *same* session into build (README edited) — validates blocker #1's same-process design |
| 9 | Resume with `--resume <id>` from a **different cwd**: same session ID, and new transcript lines land in the **original** cwd's project dir | **Confirmed live** | glob found the transcript only under the original dir — `SessionRef` path handling is simpler than feared, but keep the glob-don't-derive rule |
| 10 | One-shot ticket-draft recipe (`--output-format json --json-schema … --tools "Read,Glob,Grep" --no-session-persistence --setting-sources ""`) returns `structured_output` | **Confirmed live** | fixture `e-oneshot.json` |
| 11 | `--max-budget-usd` **works under OAuth/subscription auth** | **Confirmed live** | `subtype=error_max_budget_usd, is_error=true, total_cost_usd=0.000592` — budget caps are a valid brake for subscription users (softens resolution #13: dollar *caps* work; dollar *displays* stay secondary) |

## Additional discoveries (feed into ClaudeKit design)

1. **Streaming-input startup is silent.** After spawn, *nothing* is emitted
   (not even `system/init`) until the first user message; `system/init`
   belongs to turn startup. The `initialize` control request IS answered
   pre-turn. → CardSupervisor must not gate "process healthy" on init; use the
   initialize round-trip as the liveness probe.
2. **The `initialize` response is a capability goldmine**: `commands` (slash
   commands for composer autocomplete), `agents`, **`models`** (populates the
   model picker — no hardcoded list), **`account`** (auth type for
   tokens-vs-dollars UI), `current_permission_mode`, `pid`, fast-mode state.
3. **Safe-command classification**: read-only Bash (`echo`, `ls`) is
   auto-approved and never reaches `can_use_tool`, even in default mode. Tests
   and UX copy must not assume every Bash call prompts.
4. **`--permission-mode manual` is accepted but reported as `default`** in
   `system/init` — treat the two names as aliases everywhere.
5. **`permission_suggestions` live shape** (3 entries for a Bash write):
   `addRules` (exact command rule, `destination:"localSettings"`),
   `addDirectories` (`destination:"session"`), `setMode`
   (`acceptEdits`, `destination:"session"`) — maps 1:1 onto the approval
   sheet's "Allow once / Always allow / Allow for this session" actions.
6. **Message types not in the spec**, observed live: `system/status`,
   `system/thinking_tokens` (thinking-progress ticks), `rate_limit_event`
   (usage telemetry — useful for the board's usage banner). Tolerant decoding
   is mandatory (already policy).
7. **Interrupt response** carries `still_queued` (+ optional `cancelled` with
   `cancel_queued:true`) — Overture's Stop button should send
   `{subtype:"interrupt", cancel_queued:true}` for stop-means-stop.
8. **Host→CLI control surface** (from SDK typings, available for later
   milestones): `set_model`, `set_max_thinking_tokens`, `rename_session`,
   `mcp_status`, `get_context_usage`, `get_session_cost`, `list_models`,
   `get_usage`, `get_binary_version`, `file_suggestions`, `rewind_files`,
   `cancel_async_message`. `get_context_usage`/`get_session_cost` power the
   card cost meter without transcript math.
9. **CLI→host requests to expect beyond `can_use_tool`**: `request_user_dialog`
   (render-a-dialog protocol; answer `{behavior:"cancelled"}` for unknown
   kinds), hook callbacks, MCP messages. Unanswered dialogs are bounded by a
   CLI-side park deadline — Overture must still answer what it can render.
10. **Env hygiene**: the harness strips `CLAUDE*` env vars when spawning
    (Overture-in-Overture / nested-CC sessions would otherwise leak context).
    ProcessCore should do the same.

## Consequences for the schema/design (no spec changes required)

- Resolution #4 stands: supervisor tracks `runKind`; per-turn results confirmed.
- Resolution #5 relaxes in practice (transcripts stay at the session's origin
  dir on resume) but the glob-based lookup stays — it is what made finding #9
  cheap to discover and survives future CLI changes.
- Resolution #13: keep tokens-primary UI, but `--max-budget-usd` is confirmed
  as a hard brake for all auth types — per-run caps ship in M1.
