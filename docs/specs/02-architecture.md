<!--
Provenance: produced 2026-08-27/29 by a multi-agent design workflow driven by
Claude Code, verified against `claude` CLI v2.1.231, live docs, and on-disk
session stores on the primary dev machine. Working name "Maestro" has been
renamed to "Overture" throughout.

Where this document conflicts with 00-resolutions.md, the resolutions win.
Claims tagged [assumed] must be proven or refuted by the M0 spike before code
depends on them.
-->

# Overture — macOS App Architecture & Data Model Specification

**Target:** macOS 26+ (Tahoe), Apple Silicon only. Swift 6.2 language mode, strict concurrency (`SWIFT_STRICT_CONCURRENCY=complete`). SwiftUI + Liquid Glass. Open source (MIT).

**Verified machine facts used below:** `claude` CLI v2.1.231 supports `-p --output-format stream-json --include-partial-messages`, `--input-format stream-json`, `--session-id <uuid>`, `--resume <id>`, `--fork-session`, `--permission-mode {acceptEdits|auto|bypassPermissions|manual|dontAsk|plan}`, `--max-budget-usd`, `--replay-user-messages`. Transcripts live at `~/.claude/projects/<munged-cwd>/<session-uuid>.jsonl` (cwd munged by replacing `/` with `-`, e.g. `/Volumes/MainOBP/Dev/dungeonmaster` → `-Volumes-MainOBP-Dev-dungeonmaster`).

---

## 1. Architectural principles

1. **Modular monolith via local SPM packages.** One app target, six local packages. The app target is thin: scenes, DI wiring, entitlements. All logic lives in packages so it is testable without booting the app.
2. **SwiftData is the system of record for *intent*; everything else is derived.** Cards, columns, tags, projects, and references (session IDs, PR numbers, deployment IDs) are persisted. Git status, Vercel status, chat transcripts, and diffs are *never* copied into the store — they are read live from their sources of truth (git, Vercel API, `~/.claude/projects`).
3. **Actors own processes and I/O; `@MainActor` owns UI state.** Events flow one direction: child process → parsing actor → `AsyncStream` → main-actor store → SwiftUI. No Combine, no NotificationCenter for domain events.
4. **Shell out, don't link.** git, gh, and claude are subprocesses. Zero C dependencies, zero OAuth secrets shipped in the binary.
5. **Exactly one third-party dependency: Sparkle.** Everything else is first-party (see §11 for the argument).

---

## 2. Project structure

```
Overture/
├── Overture.xcodeproj
├── Overture/                          # App target (thin shell)
│   ├── OvertureApp.swift              # @main, WindowGroup/Settings/MenuBarExtra
│   ├── AppDelegate.swift             # NSApplicationDelegate: orphan recovery, notification delegate
│   ├── Composition/                  # DI: builds stores, managers, injects via Environment
│   ├── Assets.xcassets
│   ├── Overture.entitlements          # NOT sandboxed; hardened runtime
│   └── Info.plist
├── Packages/
│   ├── OvertureKit/                   # Domain layer: SwiftData models, board logic, stores
│   ├── OvertureDesign/                # Design system: tokens, components, Liquid Glass surfaces
│   ├── ClaudeKit/                    # claude CLI supervision, stream-json protocol, transcript reading
│   ├── GitKit/                       # git + gh CLI: status, worktrees, diffs, PRs
│   ├── VercelKit/                    # Vercel REST client, Keychain token storage
│   └── ProcessCore/                  # Shared subprocess primitives (spawn, stream, kill)
├── Tests are per-package (…/Tests/) + OvertureUITests target in the xcodeproj
└── scripts/                          # notarize.sh, make-dmg.sh, cask template
```

**Package dependency graph** (arrows = depends on):

```
Overture (app) ──► OvertureKit ──► ClaudeKit ──► ProcessCore
                    │    │────► GitKit ─────► ProcessCore
                    │    └────► VercelKit
                    └──► OvertureDesign (no deps; app also imports directly)
```

- Every package: `swiftLanguageMode(.v6)`, `platforms: [.macOS(.v26)]`, `StrictConcurrency` enabled.
- **ProcessCore** exists so ClaudeKit and GitKit don't duplicate spawn/stream/terminate logic. It has no knowledge of claude or git.
- **OvertureKit** is the only package that imports SwiftData. ClaudeKit/GitKit/VercelKit expose plain `Sendable` value types (`ClaudeEvent`, `GitStatus`, `Deployment`) — they are persistence-ignorant, so they can be reused by a future CLI or test harness.
- **Test targets:** `OvertureKitTests` (in-memory `ModelContainer`, board-transition logic), `ClaudeKitTests` (golden stream-json fixtures), `GitKitTests` (fixture repos created in temp dirs), `VercelKitTests` (stubbed `URLProtocol`), `ProcessCoreTests`. Swift Testing (`@Test`), not XCTest, everywhere except UITests.

---

## 3. Data model (SwiftData)

### 3.1 Schema — `OvertureSchemaV1`

All models live in OvertureKit, namespaced in a `VersionedSchema`:

```swift
enum OvertureSchemaV1: VersionedSchema {
  static let versionIdentifier = Schema.Version(1, 0, 0)
  static var models: [any PersistentModel.Type] {
    [Project.self, Card.self, Tag.self, SessionRef.self,
     ActivityEvent.self, TestRun.self, DeploymentRef.self]
  }
}
```

**Project**

```swift
@Model final class Project {
  @Attribute(.unique) var id: UUID
  var name: String
  var path: String                     // absolute path to repo root
  var createdAt: Date
  var sortOrder: Int                   // manual tile ordering
  var executionMode: ExecutionMode     // .worktreePerCard | .singleDirectory  (Codable enum)
  var worktreeRoot: String?            // default: <path>/.overture/worktrees (gitignored) — nil in single-dir mode
  var devServerCommand: String?        // e.g. "npm run dev"
  var devServerPort: Int?
  var vercelProjectID: String?         // link to Vercel; nil = not linked
  var vercelTeamID: String?
  var githubRemote: String?            // "owner/repo", derived once from origin, cached here
  var defaultBranch: String            // "main" unless detected otherwise
  var claudePermissionMode: PermissionMode  // default .acceptEdits; per-project choice
  var maxParallelAgents: Int           // worktree mode only; default 3
  @Relationship(deleteRule: .cascade, inverse: \Card.project) var cards: [Card]
  @Relationship(inverse: \Tag.projects) var tags: [Tag]
}
```

**Card** (the ticket)

```swift
@Model final class Card {
  @Attribute(.unique) var id: UUID
  var title: String
  var details: String                  // markdown body of the ticket
  var column: Column                   // Codable enum, see 3.2
  var columnOrder: Double              // fractional ordering within column (midpoint insertion; renormalize when gap < 1e-9)
  var createdAt: Date
  var movedAt: Date                    // last column transition (for "in review for 2d" badges)
  var project: Project?
  @Relationship(inverse: \Tag.cards) var tags: [Tag]
  // Execution
  var branchName: String?              // set when work starts (worktree mode always; single-dir if branching)
  var worktreePath: String?            // nil in single-directory mode
  var queuePosition: Int?              // single-dir mode: FIFO position while waiting for the directory
  var prNumber: Int?
  var prURL: String?
  // Relationships
  @Relationship(deleteRule: .cascade, inverse: \SessionRef.card) var sessions: [SessionRef]
  @Relationship(deleteRule: .cascade, inverse: \ActivityEvent.card) var events: [ActivityEvent]
  @Relationship(deleteRule: .cascade, inverse: \TestRun.card) var testRuns: [TestRun]
  // Denormalized snapshot for tiles/cards without touching transcripts (cheap board rendering)
  var lastAssistantSummary: String?    // last result line / summary from the agent
  var lastActivityAt: Date?
  var agentState: AgentState           // .idle | .queued | .planning | .running | .awaitingInput | .testing | .failed  — persisted, reconciled on launch (§4.4)
}
```

**Tag**

```swift
@Model final class Tag {
  @Attribute(.unique) var id: UUID
  var name: String                     // unique per store, case-insensitive enforced in store layer
  var colorToken: String               // token name from OvertureDesign palette ("tag.red"…), not raw hex
  var isBuiltIn: Bool                  // ship: bug, feature, chore, refactor, docs, urgent, design, test
  var projects: [Project]
  var cards: [Card]
}
```

**SessionRef** — the link to Claude Code's own storage. *Overture never copies transcripts.*

```swift
@Model final class SessionRef {
  @Attribute(.unique) var sessionID: UUID       // we always pass --session-id, so we mint it
  var card: Card?
  var cwd: String                                // the cwd the session ran in (project path or worktree path)
  var transcriptPath: String                     // ~/.claude/projects/<munged(cwd)>/<sessionID>.jsonl — derived at creation, stored for O(1) access
  var startedAt: Date
  var endedAt: Date?
  var kind: SessionKind                          // .work | .plan | .ticketAuthoring | .testing
  var exitReason: ExitReason?                    // .completed | .interrupted | .failed | .orphaned
  var lastKnownPID: Int32?                       // for orphan recovery
  var costUSD: Double?                           // from result event, if present
  var isCurrent: Bool                            // the session --resume continues; one per card
}
```

**ActivityEvent** — append-only feed per card (drives card detail timeline + home tile "last thing that happened").

```swift
@Model final class ActivityEvent {
  var id: UUID
  var card: Card?
  var at: Date
  var kind: EventKind    // .cardCreated, .columnChanged, .agentStarted, .agentFinished,
                         // .agentNeedsInput, .toolUse, .testRunFinished, .prOpened,
                         // .prMerged, .deploymentReady, .userNote
  var summary: String    // one line, human-readable
  var payload: Data?     // small JSON blob (e.g. {from:"plan",to:"inProgress"}); NEVER transcript content
}
```

Only *milestone* tool-use events are persisted (first tool use, errors), not every tool call — the transcript already has the full record; ActivityEvent is a curated index.

**TestRun**

```swift
@Model final class TestRun {
  var id: UUID
  var card: Card?
  var startedAt: Date
  var finishedAt: Date?
  var kind: TestKind          // .commandRun (npm test etc.) | .agentDriven (Claude tests the app)
  var command: String?
  var status: TestStatus      // .running | .passed | .failed | .aborted
  var summary: String         // pass/fail counts or agent's verdict
  var outputPath: String?     // full captured output written to Application Support, referenced not embedded
  var agentSessionID: UUID?   // when .agentDriven, links to the SessionRef that ran it
}
```

**DeploymentRef** — a *pin*, not a mirror. Live status always comes from VercelKit.

```swift
@Model final class DeploymentRef {
  var id: UUID
  var project: Project?
  var card: Card?                  // deployment triggered by this card's branch, if attributable
  var vercelDeploymentID: String
  var previewURL: String
  var gitBranch: String?
  var recordedAt: Date
}
```

### 3.2 Column semantics

```swift
enum Column: String, Codable, CaseIterable {
  case backlog, plan, inProgress, testing, review, done
}
```

Column is a **stored user-facing fact**, and agent lifecycle *drives* transitions but never fights the user:

| Transition | Trigger |
|---|---|
| → `plan` | user drags, or user starts a session with `--permission-mode plan` |
| → `inProgress` | agent begins executing (ClaudeKit reports first non-plan event), or user drag; continuing a Done card animates ("flies") it here |
| → `testing` | user drag, or agent-driven test phase begins |
| → `review` | supervisor receives terminal `result` event with success |
| → `done` | **user only** — never automatic |
| Single-dir queueing | a card told to run while another runs gets `agentState = .queued` + `queuePosition`; it stays in whatever column it's in until the directory frees |

Transitions are centralized in one OvertureKit function — `BoardEngine.apply(_ transition: CardTransition, to: Card)` — which validates, stamps `movedAt`, writes the ActivityEvent, and triggers side effects (worktree creation on first run, queue promotion). UI and supervisors both go through it; nothing mutates `card.column` directly.

### 3.3 Persisted vs derived — the contract

| Data | Where it lives | Overture stores |
|---|---|---|
| Cards, tags, columns, ordering | SwiftData | everything |
| Chat transcripts | `~/.claude/projects/**.jsonl` (Claude Code's) | `SessionRef` only (ID, cwd, path) |
| Git status/branch/ahead-behind/dirty | the repo itself | nothing — `GitStatusStore` in-memory cache |
| Diffs for Review | `git diff` on demand | nothing |
| Vercel deployment status | Vercel API | `DeploymentRef` pins only; status polled |
| PR status/checks | `gh` CLI | `prNumber`/`prURL` only |
| Test output logs | files in `~/Library/Application Support/Overture/test-output/` | path reference |

### 3.4 Store configuration & migration

- Store at `~/Library/Application Support/Overture/Overture.store`. Single `ModelContainer` created in the app target, injected everywhere.
- Background writes (supervisor events) use `ModelActor`-based `PersistenceWriter` — one serial model actor, so SwiftData contexts never cross actors.
- **Versioning from day one:** `OvertureSchemaV1` as above; a `OvertureMigrationPlan: SchemaMigrationPlan` with `stages: []` ships in v1.0 so the machinery exists before it's needed. Policy: additive changes (new optional properties) = lightweight stage in `V2`; renames use `@Attribute(originalName:)`; anything semantic gets a `custom` stage with `willMigrate/didMigrate`. Schema enums live forever; models are `typealias`ed to the latest version at package boundary (`public typealias Card = OvertureSchemaV1.Card`), so call sites never churn.
- Automatic backup: copy the store file to `.backup` before running any migration (cheap insurance; it's a small file because we store references, not content).

---

## 4. Process supervision (ClaudeKit)

### 4.1 Topology

```
ProcessManager (actor, singleton-per-app)
 ├── CardSupervisor (actor) — card A     ┐ one per running card
 ├── CardSupervisor (actor) — card B     ┘
 └── registry: [CardID: CardSupervisor], PID table, orphan file
```

- **`ProcessManager`** (actor): owns the registry, enforces per-project concurrency (`maxParallelAgents`, single-dir queue), performs orphan recovery, and is the sole API the UI layer talks to: `start(card:prompt:mode:)`, `send(input:to:)`, `interrupt(card:)`, `kill(card:)`, `events(for:) -> AsyncStream<ClaudeEvent>`.
- **`CardSupervisor`** (actor): owns exactly one child process and its parsing pipeline.

### 4.2 Spawning

Use **`Foundation.Process`** (it is posix_spawn-backed; no need to drop to raw `posix_spawn` and lose signal/termination-handler ergonomics):

```
/opt/homebrew/bin/claude -p
  --input-format stream-json --output-format stream-json
  --include-partial-messages --replay-user-messages
  --session-id <uuid-minted-by-overture>          # first run
  --resume <uuid>                                # continuations (+ --fork-session for "branch this chat" later)
  --permission-mode <project setting; acceptEdits default, plan for Plan column>
  --max-budget-usd <optional project cap>
```

- `currentDirectoryURL` = worktree path (worktree mode) or project path (single-dir).
- Environment: inherit login shell PATH resolved once at launch (`/bin/zsh -lc 'echo $PATH'`) so node/npm/toolchains resolve; claude binary path is configurable in Settings with `/opt/homebrew/bin/claude` default.
- stdin stays open (`Pipe`) — user replies and permission responses are written as stream-json user messages. This makes a "card chat" fully interactive over one long-lived process.
- We mint the session UUID ourselves (`--session-id`) so the `SessionRef` and transcript path are known *before* the process starts — no output sniffing needed to find the transcript.

### 4.3 Streaming pipeline (off main thread)

```
Process stdout ──FileHandle.bytes──► LineFramer ──► StreamJSONDecoder ──► ClaudeEvent
      (nonisolated async sequence)     (actor-isolated in CardSupervisor)
                                                        │
                       PersistenceWriter (ModelActor) ◄─┤ milestone events → ActivityEvent, summaries
                       AsyncStream<ClaudeEvent> ────────┘ → UI (multicast via supervisor-held continuations)
```

- Read `fileHandleForReading.bytes.lines` inside the supervisor actor — never on the main actor.
- `ClaudeEvent` is a `Sendable` enum decoded from stream-json message types: `.system(init)`, `.assistantDelta(text)`, `.assistantMessage`, `.toolUse(name, summary)`, `.permissionRequest`, `.result(success, costUSD, summary)`, `.parseFailure(rawLine)` (never crash on unknown message shapes — forward-compat with CLI updates).
- stderr is captured to a ring buffer (last 64KB) attached to failure ActivityEvents.
- Backpressure: partial-message deltas are coalesced in the supervisor (~30Hz max) before hitting the UI stream; the UI never sees more than screen-refresh-rate updates.

### 4.4 Lifecycle

- **Interrupt:** write the stream-json interrupt control message; fallback SIGINT after 2s grace.
- **Kill:** SIGTERM → 5s → SIGKILL. Always `terminationHandler` → supervisor finalizes `SessionRef.endedAt/exitReason`, emits `.agentFinished`, ProcessManager promotes the next queued card.
- **Orphan recovery:** ProcessManager journals `{cardID, sessionID, pid, spawnTime}` to `running-agents.json` (Application Support) on every spawn/exit. On app launch: for each journal entry, check the PID is alive **and** its executable is claude (via `proc_pidpath`) **and** start time matches (PID reuse guard). Alive → offer "reattach" (we cannot re-pipe stdio, so reattach = watch the transcript file for progress + allow kill); dead → mark `SessionRef.exitReason = .orphaned`, set card `agentState = .idle`, surface a "session ended while Overture was closed — resume?" affordance which uses `--resume`. Reconcile `Card.agentState` for all cards on launch regardless (persisted state can never claim a process that isn't in the journal).
- **App quit with agents running:** confirmation dialog; "quit anyway" leaves them running (journal enables next-launch recovery) — agents are `claude -p` processes that finish on their own and the transcript survives; card state is recovered from the transcript's terminal result on relaunch.

### 4.5 Transcript reading (history + reattach)

`TranscriptReader` (struct, nonisolated async) renders past chat when a card is opened: memory-maps the JSONL, and for large files (transcripts reach many MB) parses **backwards incrementally** — read the last N lines for instant display, lazily page older lines as the user scrolls up. A lightweight `TranscriptTail` (DispatchSource file-offset watcher) supports the reattach case by tailing appended lines. Never load a whole transcript into memory; never store parsed transcripts in SwiftData.

---

## 5. Git layer (GitKit)

All operations shell through ProcessCore to the system `git` (path configurable, `/usr/bin/git` default). No libgit2.

### 5.1 Status: FSEvents-driven, timer-backstopped

**Recommendation: FSEvents on the repo root (not a timer as primary).** `GitStatusStore` (actor):

- One FSEvents stream per *open* project (board visible or tile on screen), watching the worktree root and `.git` (HEAD, refs, index) with 500ms latency coalescing. Events → debounced (750ms) `git status --porcelain=v2 --branch` + `git rev-list --count --left-right @{upstream}...HEAD`.
- Ignore events under `.git/objects` and any path matching `.overture/worktrees` (agent churn would thrash it) — status refresh cares about index/HEAD/working-tree files only.
- Backstop timer at 30s for ahead/behind vs remote (fetch is **never** automatic; ahead/behind uses last-known remote refs).
- Home screen tiles subscribe to the same store; projects not on screen get no watcher (registered/unregistered from `onAppear/onDisappear` scene phase).
- Output: `GitStatus { branch, dirtyCount, ahead, behind, lastCommit }` value published via `AsyncStream` to the main-actor `ProjectsStore`.

### 5.2 Worktrees (worktree-per-card mode)

- Root: `<project>/.overture/worktrees/<card-slug>/` (added to `.git/info/exclude` automatically — not the project's `.gitignore`, to avoid dirtying the repo).
- **Branch naming:** `overture/<card-slug>-<id8>` — e.g. `overture/fix-login-crash-3fa9c2d1` (slug = kebab-cased title truncated to 40 chars; `id8` = first 8 hex of card UUID; prefix makes cleanup greppable and avoids collisions).
- Create on first run of a card: `git worktree add <path> -b <branch> <defaultBranch>`.
- Remove on Done (after merge) or card delete: `git worktree remove --force` + `git branch -d` (`-D` only with explicit user confirmation if unmerged); `git worktree prune` on app launch per project.
- `git worktree list --porcelain` on launch reconciles the store against reality (a worktree deleted behind our back → clear `card.worktreePath`).

### 5.3 Review diffs

Review column card detail runs, in the card's worktree (or project dir): `git diff <merge-base(defaultBranch, branch)>...HEAD --stat` for the summary and `git diff -U3 <range> -- <file>` lazily per file the user expands. Parsed into a `DiffFile[]` value model by a `DiffParser` (pure function, golden-tested). Uncommitted work shows as an extra "working tree" section (`git diff HEAD`). No diff content is persisted.

### 5.4 Merge / PR flow

Per card in Review, two paths (user picks, remembered per project):
- **PR flow (default when `githubRemote` exists):** push branch → `gh pr create` (§6) → card shows PR checks → merge via `gh pr merge --squash --delete-branch` → BoardEngine moves card to Done on user click, worktree removed.
- **Local merge:** `git merge --no-ff <branch>` on default branch (refuse if default branch dirty), then worktree/branch cleanup.

---

## 6. GitHub integration

**Recommendation: `gh` CLI exclusively. No REST client, no GraphQL client, no OAuth.** Rationale: the user's `gh` is already authenticated; an open-source app cannot ship an OAuth client secret; a device-flow implementation plus token storage is real scope for zero launch value; `gh` output is stable JSON via `--json`.

`GitHubService` (actor, in GitKit) wraps:

| Operation | Command |
|---|---|
| Preflight | `gh auth status` (on project open; degrade gracefully to "PR features off" with a fix-it hint) |
| PR create | `gh pr create --head <branch> --title <card.title> --body <generated body with card link>` |
| PR status + checks | `gh pr view <n> --json state,mergeable,statusCheckRollup,reviewDecision` — polled at 60s only while a Review-column card with a PR is visible |
| Merge | `gh pr merge <n> --squash --delete-branch` |
| Repo detection | `gh repo view --json nameWithOwner` (cached to `Project.githubRemote`) |

Checks render as a compact roll-up chip on the card (pass/fail/pending counts). No webhooks at v1 — polling only while visible is cheap and honest.

## 7. Vercel integration

REST v13/v6 endpoints with a **user-supplied token** (created at vercel.com/account/tokens, pasted into Overture Settings).

- **`VercelTokenStore`**: Keychain (`kSecClassGenericPassword`, service `"com.overture.vercel-token"`, `kSecAttrAccessibleAfterFirstUnlock`, no iCloud sync). Never in SwiftData, never in UserDefaults, never logged.
- **`VercelClient`** (actor): `URLSession`-based, endpoints: `GET /v6/deployments?projectId=&limit=10`, `GET /v13/deployments/{id}`, `GET /v9/projects` (for the link-project picker). Decoded to `Deployment { id, state, url, branch, createdAt }`.
- **`DeploymentStore`**: polls the latest deployments for *visible* projects — 15s while a deployment is in `BUILDING/QUEUED`, 90s otherwise, paused entirely when the app is backgrounded. Rate-limit aware (respects `X-RateLimit-Remaining`, backs off exponentially on 429).
- Tile shows latest production state; board's Testing/Review columns match deployments to cards by `gitBranch == card.branchName`, recording a `DeploymentRef` pin when matched. Preview URL feeds the embedded WebKit pane (§9.3).

---

## 8. UI architecture

### 8.1 Scenes

```swift
@main struct OvertureApp: App {
  var body: some Scene {
    WindowGroup(id: "main") { RootView() }          // tiles grid ⇄ board
      .windowStyle(.automatic)                       // Liquid Glass chrome
    WindowGroup(id: "card", for: Card.ID.self) { …CardDetailWindow… } // pop a card chat out
    Settings { SettingsView() }                      // General / Projects / Claude / Integrations / Advanced
    MenuBarExtra("Overture", systemImage: "square.grid.3x3") { AgentsMenuView() }
      .menuBarExtraStyle(.window)
  }
}
```

- **Navigation:** `NavigationStack` with a `Route` enum (`.home`, `.board(Project.ID)`); path in a main-actor `NavigationModel`. Tile → board push uses `NavigationTransition.zoom` (tile morphs into the board). Card detail is an inspector panel on the board (`.inspector`) by default; ⌘-click opens the dedicated card window.
- **MenuBarExtra:** live list of running agents (project · card · elapsed · current tool), click → focuses that card; badge count = agents needing input.
- **Notifications:** `UserNotifications` — `agent finished` (→ Review), `agent needs input`, `tests failed`, `PR checks failed`. Actionable: "View card" (deep-links via `overture://card/<uuid>`) and "Reply…" (text-input action writes to the card's stdin). Only when app is not frontmost.

### 8.2 State stores (Observation framework, all `@MainActor @Observable`)

| Store | Responsibility |
|---|---|
| `ProjectsStore` | tile grid: projects + `GitStatus` + latest deployment + "what's happening" snapshot |
| `BoardStore` (per open project) | cards by column, drag-and-drop reordering, invokes `BoardEngine` |
| `CardChatModel` (per open card) | transcript history (via `TranscriptReader`) + live event stream + composer state |
| `AgentsOverviewModel` | flat list of running supervisors for MenuBarExtra + Dock badge |
| `SettingsModel` | app + per-project settings |

**Event flow:** `CardSupervisor` (actor) → `AsyncStream<ClaudeEvent>` → store consumes in `for await` inside a `Task` bound to view lifetime (`.task(id: card.id)`), mutates `@Observable` state → SwiftUI diffing. SwiftData mutations happen *only* in `PersistenceWriter` (model actor) or main-context user edits; stores observe via `@Query` where live-fetch semantics are wanted (board columns) and via explicit fetch elsewhere.

### 8.3 OvertureDesign

- **Tokens first:** `ColorToken`, `SpaceToken`, `TypeToken`, `RadiusToken`, `MotionToken` as enums backed by asset-catalog colors (automatic dark/light adaptation) — every color in the app is a token; tag colors are token names (stored as strings in `Tag.colorToken`), never hex.
- **Components:** `TileCard`, `KanbanCardView`, `ColumnView`, `TagChip`, `StatusPill` (git/deploy/checks), `AgentPulse` (running indicator), `GlassPanel` (Liquid Glass surface wrapper: `glassBackgroundEffect()`), `DiffView`, `TranscriptView`.
- Accessibility baked into components: every interactive element labeled, board fully keyboard-navigable (arrow keys move focus, ⌘+arrows move cards), Reduce Motion swaps the card "fly" animation for a crossfade, contrast-checked token pairs, Dynamic Type respected.
- A `DesignGallery` SwiftUI `#Preview` catalog acts as the living style guide (open-source contributors see every component/state without running the app).

---

## 9. Embedded preview

- **`PreviewPane`**: `NSViewRepresentable` wrapping `WKWebView` (non-persistent `WKWebsiteDataStore` per project, `isInspectable = true` for right-click → Inspect). Toolbar: URL field (restricted to localhost + `*.vercel.app` + project's linked domains), back/forward, reload, device-width presets, "open in browser".
- Sources: (a) localhost dev server, (b) Vercel preview URL from the card's matched deployment — one segmented control.
- **`DevServerManager`** (actor, OvertureKit, uses ProcessCore): per-project `devServerCommand` spawned in the *card's worktree* (worktree mode — so you preview the branch's code) or project dir. Port readiness probe (TCP connect retry loop) before pointing the WebView; stdout/stderr into a collapsible console strip under the pane; stopped on pane close or app quit (dev servers, unlike agents, do not outlive the app). Port conflicts in worktree mode: `devServerPort` is a base; DevServerManager allocates base+n per concurrent worktree and injects it as `$PORT` env.

---

## 10. Distribution

- **No App Store. No sandbox.** The app's entire purpose is spawning arbitrary child processes (claude, git, gh, user dev servers) in arbitrary directories — App Sandbox is a non-starter. Hardened Runtime **on**, with no extra entitlements needed for fork/exec of signed system tools.
- **Developer ID signing + notarization** (`notarytool`), stapled. Scripted in `scripts/notarize.sh`, run in GitHub Actions on tag push (secrets: Developer ID cert + App Store Connect API key).
- **Delivery:** DMG (with `/Applications` symlink) + Homebrew cask (`brew install --cask overture`) generated from the same CI job.
- **Sparkle: yes — this is the one acceptable third-party dependency.** Verdict reasoning: (1) an update mechanism at v1 is not optional for a fast-moving tool wrapping a CLI that ships weekly; (2) hand-rolling secure delta updates with EdDSA signature verification is precisely the kind of security-critical code a small open-source project should not own; (3) Sparkle 2 is SPM-native, sandbox-clean, and the de-facto standard with two decades of audit history. Appcast hosted on GitHub Pages, fed by the same release workflow. Homebrew cask marked `auto_updates true`.
- First-launch experience: quarantine-aware (notarization makes Gatekeeper a one-click approve), and an onboarding check that verifies `claude`/`git`/`gh` paths with fix-it guidance.

---

## 11. Concurrency & performance rules

1. **Actor map:** `@MainActor` = stores + views. `ProcessManager`, `CardSupervisor`, `GitStatusStore`, `GitHubService`, `VercelClient`, `DeploymentStore`, `DevServerManager` = independent actors. `PersistenceWriter` = `@ModelActor`. Parsing (`StreamJSONDecoder`, `DiffParser`, `TranscriptReader`) = `Sendable` pure functions running on whatever actor calls them (never main).
2. **Streams over callbacks:** every cross-actor event path is `AsyncStream` with explicit buffering policy (`.bufferingNewest(64)` for status, unbounded only for transcript deltas which are already coalesced at source).
3. **Large transcripts:** never whole-file reads. Tail-first reverse paging (§4.5), 500-line pages, cell recycling via `LazyVStack` + stable message IDs. Target: opening a 50MB transcript card shows last messages in <100ms.
4. **UI update coalescing:** supervisor coalesces deltas to ≤30Hz; git/deploy stores publish only on value *change* (Equatable gate) so tiles don't re-render on no-op polls.
5. **Visibility-scoped work:** FSEvents watchers, Vercel polling, PR polling all attach/detach with view lifecycle. A backgrounded Overture does approximately nothing except supervise running agents.
6. **Strict concurrency posture:** no `@unchecked Sendable` outside ProcessCore's `Process` wrapper (documented invariant); no `nonisolated(unsafe)`; `Sendable` value types at every package boundary.

---

## 12. Module responsibility summary

| Module | One-line responsibility |
|---|---|
| **Overture (app)** | Scenes, DI composition, entitlements, AppDelegate (orphan recovery kick-off, notifications), Sparkle updater host |
| **OvertureKit** | SwiftData schema + migrations, `BoardEngine` (all card transitions), stores, `DevServerManager`, queueing policy |
| **OvertureDesign** | Tokens, Liquid Glass components, accessibility primitives, design gallery |
| **ClaudeKit** | claude CLI spawning/supervision (`ProcessManager`, `CardSupervisor`), stream-json protocol, `TranscriptReader`/`TranscriptTail`, orphan journal |
| **GitKit** | git status via FSEvents, worktree lifecycle, branch convention, `DiffParser`, `GitHubService` (gh CLI) |
| **VercelKit** | Vercel REST client, Keychain token store, deployment polling |
| **ProcessCore** | Subprocess spawn/stream/terminate primitives, login-shell PATH resolution, PID liveness checks |

**Key file paths referenced:** claude binary `/opt/homebrew/bin/claude`; transcripts `~/.claude/projects/<munged-cwd>/<session-uuid>.jsonl`; Overture store `~/Library/Application Support/Overture/Overture.store`; orphan journal `~/Library/Application Support/Overture/running-agents.json`; worktrees `<project>/.overture/worktrees/<card-slug>/`.
