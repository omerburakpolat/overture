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

---

## M1 auth findings (verified live, CLI v2.1.236)

Measured by probing the shipped binary and by running `claude auth login` over
pipes in a scratch `CLAUDE_CONFIG_DIR`. Recorded so nobody re-derives them.
Items 1–11 were recorded on 2026-09-07; items 12–18, and the correction to
item 5, on 2026-09-13 — read item 12 before trusting any request-time result.

1. **`auth status --json` field set** is `loggedIn`, `authMethod`,
   `apiProvider`, `forcedLoginMethod?`, `apiKeySource?`, `email?`, `orgId?`,
   `orgName?`, `subscriptionType?`. Identity fields appear **only** when
   `authMethod == "claude.ai"`.
2. **Logged out prints valid JSON and then exits 1.** Parse stdout regardless
   of the exit code; only fall back to the exit code when there is nothing to
   parse. `{"loggedIn": false, "authMethod": "none", "apiProvider": "firstParty"}`.
3. **`forcedLoginMethod` is reported in the JSON**, so Overture must not parse
   `/Library/Application Support/ClaudeCode/managed-settings.json` itself. The
   CLI resolves the policy; Overture only reflects it.
4. **Env precedence, as the CLI actually reports it:**
   `CLAUDE_CODE_USE_BEDROCK` → `third_party`/`bedrock`; `ANTHROPIC_API_KEY` →
   an `apiKeySource` field; `CLAUDE_CODE_OAUTH_TOKEN` → `oauth_token` with
   **every identity field dropped**; `ANTHROPIC_AUTH_TOKEN` → **not reported
   at all** (yet sent — see 5).
5. **`ANTHROPIC_AUTH_TOKEN` is sent, even though it is never reported.** In a
   clean environment a `-p` turn with a deliberately bogus value fails with
   `401 Invalid bearer token`, so it does replace a signed-in account and
   Overture flags it as an override. *Corrected 2026-09-13:* this item
   originally said the token was ignored. That run happened inside a Claude
   Code desktop session, whose host masked it (item 12).
6. **`claude auth login` needs no TTY.** It is `readline` + `stdout.write`,
   not a full-screen UI. Over pipes with stdin at `/dev/null` it emits:

   ```
   Opening browser to sign in\u{2026}\n
   If the browser didn't open, visit: <URL>\n
   Paste code here if prompted >          ← no trailing newline
   ```

   The prompt's missing newline means a line-framed reader never delivers it,
   so readiness for a code is inferred from the URL line instead.
7. **The paste value is `code#state`.** The CLI splits on `#` and rejects
   anything without both halves, so it must be forwarded verbatim.
8. **Login failures are stderr-only** (`Login failed: …`,
   `Invalid code. Please make sure the full code was copied.`), which is why
   `Subprocess` grew an opt-in stderr stream.
9. **`auth logout` terminates cleanly over pipes** (~1 s, exit 0,
   `Successfully logged out from your Anthropic account.`). No timeout needed.
10. **`CLAUDE_CONFIG_DIR` genuinely re-keys the credential store.** With it
    set to an empty directory, `auth status` reports signed out while the
    default store stays signed in — which is why stripping it from a child
    (the pre-#13 behaviour) silently broke sign-in for anyone using it.
11. **Gateway policy refuses `auth login` outright**:
    `forceLoginMethod is 'gateway' in managed settings; run interactive
    /login to authenticate.` Those users get the terminal instructions only.
12. **Measure request-time behaviour in a clean environment.** A process
    started from inside a Claude Code desktop session inherits
    `CLAUDE_CODE_MESSAGING_SOCKET`/`_TOKEN`, and the host keeps the login fresh
    for it over that socket: an expired standalone login still works there,
    and an environment credential can be ignored. Use `env -i HOME="$HOME"
    PATH=/opt/homebrew/bin:/usr/bin:/bin …`, or the environment
    `ClaudeChildEnvironment.make()` builds — it strips those markers, so it
    behaves like a Dock launch (verified: identical results).
13. **An expired login arrives as an assistant message, not `api_retry`**:
    `{"type":"assistant","error":"authentication_failed", …}` whose text is
    `Failed to authenticate: OAuth session expired and could not be refreshed`,
    then a `result` with `subtype: "success"` **and** `is_error: true`, then
    exit 1.
14. **A rejected API key is retried ten times first**: ten `system/api_retry`
    events with `error: "authentication_failed"`, `error_status: 401`, delays
    growing to ~34 s, then the same assistant/result pair. Overture interrupts
    on the first retry.
15. **`auth status` reports an expired, unrefreshable login as signed out**
    (`loggedIn: false`, `authMethod: "none"`) in ~0.3 s, so a pre-flight check
    before an agent starts catches it without reading any credential. A
    *rejected* key, by contrast, still reports `loggedIn: true` — only a
    request reveals it.
16. **The status shape for an API key depends on what sits underneath**:
    observed as `claude.ai` + `apiKeySource` where the stored login worked,
    and as `authMethod: "api_key"` where it did not. Overture asks a second
    time with the credential variable names removed instead of inferring from
    the shape.
17. **`settings.json`'s `env` block selects a provider**: with
    `{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}` in a config dir, `auth status`
    reports `third_party`/`bedrock` however `claude` was launched.
18. **The Homebrew binary is signed `Developer ID Application: Anthropic PBC
    (Q6L2SF6YDW)`.** `codesign --verify --strict -R='anchor apple generic and
    certificate leaf[subject.OU] = "Q6L2SF6YDW"'` exits 0 for it, 3 for a
    binary signed by another team, and 1 for an unsigned one, in ~0.7 s.
19. **Each provider's setup page names the variables it needs** (fetched
    2026-09-13): Bedrock `CLAUDE_CODE_USE_BEDROCK` + `AWS_REGION` (optionally
    `AWS_PROFILE`), with a Mantle variant switched on by
    `CLAUDE_CODE_USE_MANTLE`; Vertex `CLAUDE_CODE_USE_VERTEX` +
    `CLOUD_ML_REGION` + `ANTHROPIC_VERTEX_PROJECT_ID`; Foundry
    `CLAUDE_CODE_USE_FOUNDRY` + `ANTHROPIC_FOUNDRY_RESOURCE` (or `_BASE_URL`),
    whose secrets are `ANTHROPIC_FOUNDRY_API_KEY` / `_AUTH_TOKEN`.
20. **A Claude Code host sets undocumented variables for the CLI it embeds**:
    `CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH`, `_SDK_HAS_OAUTH_REFRESH`,
    `_DESKTOP_APP_VERSION`, `_EAGER_FLUSH`, `_EMIT_TOOL_USE_SUMMARIES`,
    `_ENABLE_ASK_USER_QUESTION_TOOL`, `_ENABLE_SDK_FILE_CHECKPOINTING`,
    `_REPORT_FINDINGS`, `CLAUDE_PREVIEW_CLASSIFIER_FLOOR`, plus the documented
    host marker `CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST`. It also sets
    `CLAUDE_CODE_DISABLE_CRON`, `_DISABLE_TERMINAL_TITLE` and `_OAUTH_SCOPES`,
    which *are* documented user settings. With the messaging socket stripped,
    the refresh variables alone do not keep an expired login working.
