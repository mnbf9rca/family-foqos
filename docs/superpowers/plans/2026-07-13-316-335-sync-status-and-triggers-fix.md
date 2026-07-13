# Honest Sync Status + Automatic Sync Triggers — Implementation Plan (plans the fix for #316, #335)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This document **plans the fix for #316 and #335** — it is plan-only. No production code is changed by landing this document; implementation is a separate session.

**Goal:** Make the Settings sync indicator tell the truth (derived from the real pending / deferred / failed queues plus `syncPausedReason`, never a hand-set "synced" flag), give "Sync Now" visible in-progress/finished feedback (#316), and add the two missing automatic triggers so queued and conflict-corrected changes sync without a manual poke — a network-reconnect trigger and a backoff-aware queued/post-conflict re-send (#335).

**Architecture:** The engine owner (`SyncEngineController`) already holds the truth CKSyncEngine exposes — `driver.pendingRecordZoneChanges` / `pendingDatabaseChanges`, `store.failedApplies`, fetch-cycle delimiters — but nothing surfaces it and nothing re-drives a send after a conflict re-add (with `automaticallySync = false` the engine never re-sends on its own). This plan (a) surfaces an *in-flight* signal + a *pending-change count* + a *last-successful-sync* stamp + a *status-changed* hook from the controller through the `SyncEngineControlling` seam; (b) adds a controller-internal, CKError-aware **queue-drain scheduler** that schedules `sendChanges()` (in a `Task` after the handler returns — §1.1) whenever a handler re-added pending changes — on the send side (`sentRecordZoneChanges`/`sentDatabaseChanges`) *and* the fetch/sweep side (equal-version / I9 auto-heal, failed-apply retry); (c) adds a `NetworkReachabilityMonitor` (NWPathMonitor) whose satisfied-edge fires a gated `syncNow()` and whose `isOnline` feeds the status; and (d) replaces the dead `syncStatus`/`isSyncing`/`lastSyncDate` UI fields with a single **derived** `SyncStatusSnapshot` recomputed on every status-changed tick. `automaticallySync` stays `false`; the reconnect trigger calls `syncNow()` → `requestSync` (the D-A gate, #341) and the queue-drain **replicates `requestSync`'s operational-state guard** (send-only) — so nothing drives a non-operational or mid-resolution engine.

**Tech Stack:** Swift 6, `@MainActor` `SyncEngineController` + `ProfileSyncManager` + `SettingsView`, CKSyncEngine driver seam (`SyncEngineDriver`/`CKSyncEngineDriver`), `Network.framework` `NWPathMonitor`, SwiftData, `Log` (`.sync`), XCTest (`FoqosTests`).

## Global Constraints

- **Plan-only. This session writes no production code.** Implementation is a separate session gated on this plan's review (AGENTS.md house rules). The PR that lands this document is titled/bodied "**plans the fix for #316, #335**" — never "fixes".
- **Never force-commit/amend; new commits + Git revert only** (AGENTS.md).
- **No parallel build/test streams on this machine** — one implementation stream at a time (AGENTS.md).
- **Anchors are line-verified against `main` @ `1219027` (post-#341 account-change fix).** Re-run Task 0's citation refresh before editing — sibling PRs move line numbers.
- **`@SafeQuery` not `@Query`** in any view touched (AGENTS.md; pre-commit-enforced).
- **Logging:** `Log.…(…, category: .sync)`; never log lock codes/PII. UUIDs, record names, timestamps, counts, and state values are acceptable.
- **Lock-check rule** (if lock/mode UI is touched — it is not here): `== .child`, never `!= .parent`.
- **Tests:** boot the iPhone 17 simulator once by **UUID** (never device name), then `xcodebuild test … -destination 'platform=iOS Simulator,id=<UUID>'`. Pin time — one `let now = Date()` per test; assert `lastSuccessfulSyncDate` becomes non-nil, never an exact value.
- **`automaticallySync = false` is a fixed S0 decision (§1.1 funnel discipline).** This plan does **not** flip it. If an implementer concludes it *must* be flipped, that is design-tier: **STOP and escalate** — do not plan around it.

---

## Confirmed grounding (do not re-litigate; re-cite in Task 0)

All references are `main` @ `1219027`.

### #316 — the status is cosmetic, the feedback fields are dead

1. **The "synced" lie.** `ProfileSyncManager.syncStatus` is assigned **only** `isEnabled ? .idle : .disabled` — at init (`ProfileSyncManager.swift:100`) and in the `$isEnabled` sink (`:108`). `SyncStatus.idle.displayText == "Synced"` (`:132-133`). It never reads any queue. This is exactly issue #316 point 1.
2. **`isSyncing` is never written.** `@Published var isSyncing` (`ProfileSyncManager.swift:28`) has **zero writers** in the repo. `SettingsView` binds the Sync-Now spinner and `.disabled(...)` to it (`SettingsView.swift:173, 211, 217`) — so the button never dims and nothing ever spins. This is issue #316 point 2.
3. **`lastSyncDate` is never written.** `@Published var lastSyncDate` (`ProfileSyncManager.swift:31`) has **zero writers**; the "Last Synced" row (`SettingsView.swift:187-196`) never renders.
4. **`connectedDeviceCount` (`:30`) and `error` (`:32`) are dead** (declarations only; no readers — `connectedDeviceCount` grep returns only its own line).
5. **The truth already exists.** `SyncEngineDriver.pendingRecordZoneChanges` / `pendingDatabaseChanges` (protocol `SyncEngineDriver.swift:20-21`; impl `CKSyncEngineDriver.swift:35-41`); `SyncEngineController.state` (`:37`) and `accountResolutionInFlight` (`:83`); `ProfileSyncManager.syncPausedReason` (`:35`, values `.signedOut`/`.accountChanged` `:142-145`); the facade's deferred sets `deferredProfileSaveIds`/`deferredLocationSaveIds`/`deferredDeleteRecordNames`/`deferredEmergency*` (`:55-60`). (`SyncEngineStore.failedApplies` (`:226`) exists but is **inbound** apply-failure state that self-heals via the §5.6 fetch-cycle sweep — it is deliberately **not** part of the user-facing "waiting to send" count; see D-6.)
6. **In-flight is NOT surfaced today.** `willSendChanges`/`didSendChanges` translate to `nil` (`CKSyncEngineDriver.swift:182-184`, never delivered to the controller). `willFetchChanges`/`didFetchChanges` *are* consumed (`SyncEngineController.swift:294-297`) but only for the §5.6 sweep / state transition, not exposed as status.

### #335 — two missing triggers (engine steady throughout; not an engine-state bug)

7. **Triggers that exist:** every facade enqueue verb does `if isSyncReady { engineController.requestSync() }` (`ProfileSyncManager.swift:567, 596, 613, 626, 639, 652, 669`, delete path `:577`); foreground `scenePhase == .active` → `syncNow()` (`FoqosApp.swift:153-159`); CloudKit push `didReceiveRemoteNotification` → `syncNow()` (`FoqosApp.swift:405-412`); account-resolution resume (`ProfileSyncManager.swift:338, 342, 460`); `markSyncReadyAndFlush` (`:716`).
8. **Missing trigger (a) — reconnect.** No `NWPathMonitor` / reachability exists anywhere in the app. An edit made offline sits in the queue until the *next* foreground / push / edit. Device evidence (#335): an offline edit at 20:05:44 only sent when the user pressed Sync Now.
9. **Missing trigger (b) — queued / post-conflict re-send.** `handleFailedSave` (`SyncEngineController.swift:554-596`), `handleFailedDelete` (`:600-619`) and `handleSentDatabaseChanges` (`:515`; re-adds `:532`/`:541`) call `driver.add(pendingRecordZoneChanges:/pendingDatabaseChanges:)` to re-enqueue (branch C local-wins `:578`, branch E via §5.1, branch R `:589`/`:613`, branch Z `:582`/`:610`, retriable zone save `:532` / zone delete `:541`) — and then **return with no subsequent `sendChanges()`**. Re-adds *also* occur on the fetch/sweep side — `handleFetchedRecordZoneChanges` equal-version-divergence / I9 auto-heal (`:419`, `:434`) and `retryFailedApplies` (`:812`, `:841`) — with the same no-send fate (`handleDidFetchChanges` `:692` never sends). The comments say "rely on the engine's own backoff" (`:513-514, :532`), but `CKSyncEngineDriver` sets `automaticallySync = false` (`CKSyncEngineDriver.swift:27`), so the engine never re-sends. Device evidence (#335): a `serverRecordChanged`-corrected record sat queued **26 minutes** (20:13 → 20:39) with no push, no retry, no timer, and sent within 1s of the next app foreground. `isRetriable` (`:621-629`) does not read `retryAfterSeconds`.
10. **The D-A gate (must compose with it).** `requestSync` (`SyncEngineController+Cutover.swift:9-19`) drives the driver **only** when `state ∈ {.bootstrapping, .steady}` **and** `!accountResolutionInFlight`; it never calls `start()`; `.purged` is consent-scoped and never auto-resumed. §1.1 prohibits calling `fetchChanges()`/`sendChanges()` from within `handleEvent` — explicit requests are scheduled in a `Task` after the handler returns.

---

## Design decisions (resolved in this plan)

### D-1 — Status is a pure derivation, recomputed on a controller "status-changed" tick
The facade publishes a single `SyncStatusSnapshot` computed by a **pure function** of: `pendingCount` (controller pending + facade deferred sets), `isInFlight`, `isOnline`, `syncPausedReason`, `lastSyncDate`, `isEnabled`. The controller fires `onStatusChanged` after every event that changes the truth (sent*, will/didFetch, will/didSend, stateUpdate, zone deletions) and after each enqueue; the facade recomputes and re-publishes only on change. This is the "trigger×status interaction" guarantee: when a trigger drains the queue, the very next `sentRecordZoneChanges` fires `onStatusChanged` → the snapshot flips to `.synced` with no manual refresh.

Precedence (first match wins): **disabled** (`!isEnabled`) → **paused** (`syncPausedReason != nil`) → **syncing** (`isInFlight`) → **offline** (`!isOnline && pendingCount > 0`) → **waiting(n)** (`pendingCount > 0`) → **synced**. Rationale: paused outranks syncing because a paused engine that briefly flushes a suppressed send must still read "Sync issue"; offline outranks waiting so a queued-while-offline device reads "Offline", not a bare "Waiting".

### D-2 — In-flight comes from real engine send/fetch brackets
Add `willSendChanges`/`didSendChanges` to `SyncEngineEvent` + `CKSyncEngineDriver.translate` (they currently return `nil`), and track `isSending` in the controller alongside a new `isFetching` (set by the already-handled `willFetchChanges`/`didFetchChanges`). `isInFlight = isSending || isFetching`. This adds a **soft delivery assumption** — that CKSyncEngine pairs `willSendChanges`/`didSendChanges` (symmetric to the AB-3 fetch-delimiter assumption already relied on) — whose *only* failure mode is cosmetic: a dropped `didSendChanges` would wedge the status at "Syncing…", never a data-correctness bug. Two defences: (a) `isSending`/`isFetching` are also cleared to `false` on any `sentRecordZoneChanges`/`sentDatabaseChanges` and `didFetchChanges` respectively (a completed sent/fetch event implies the bracket closed), and (b) both flags are reset to `false` on every teardown path (Task 3 §3d) so a torn-down controller never latches `isInFlight == true`. Task 0 records a manual confirmation that empty/error sends still deliver `didSendChanges`.

### D-3 — `lastSuccessfulSyncDate` = last clean round-trip **with progress**
The controller stamps `lastSuccessfulSyncDate = Date()` on `didFetchChanges` (a completed fetch cycle — an empty fetch is still a real round-trip that confirms this device is current) and on a `sentRecordZoneChanges` / `sentDatabaseChanges` that had **actual progress and no failures** (at least one `savedRecords`/`deletedRecordIDs`/`savedZones`/`deletedZoneIDs`, matching D-4's backoff-reset condition). An **empty** send is never stamped — otherwise an engine-aborted/no-op send would flip the UI to "Synced" while the queue is non-empty, the exact #316 lie. Tests assert non-nil, never an exact value (Global Constraints), so no `now` injection is required; if an implementer wants exactness, inject a `now: @escaping () -> Date = Date.init` seam.

### D-4 — Queue-drain scheduler: explicit, CKError-aware, gated, cancellable (the #335(b) fix)
A controller-internal scheduler re-sends changes the engine re-added but will never re-send itself (`automaticallySync = false`). At the **end of `handle(_:)`** (after the `switch` returns, so §1.1 is honored — the actual `sendChanges()` runs inside a `Task` body after suspension), if a handler that can re-enqueue set the `queueDrainNeedsSend` flag **and** `driver.pendingRecordZoneChanges`/`pendingDatabaseChanges` is non-empty, (re)arm a single `queueDrainTask`. The re-enqueue sites that set the flag span **both** the send side (`handleFailedSave`/`handleFailedDelete`/`handleSentDatabaseChanges`: `:532`/`:541`/`:578`/`:582`/`:585`/`:589`/`:610`/`:613`) **and** the fetch/sweep side (`handleFetchedRecordZoneChanges` equal-version-divergence / I9 auto-heal `:419`/`:434`; `retryFailedApplies` `:812`/`:841`) — so a conflict-corrected re-add produced by a *push-driven fetch* drains too, not only re-adds seen during an outbound send.

- **Delay** = `retryAfterSeconds` from the failing CKError when present, else exponential backoff `min(2 ^ attempt, 64)` seconds, `attempt` 0…6 (first delay 1s, cap 64s). *Note:* `retryAfterSeconds` is only populated on the retriable/rate-limited branches (R / `.serviceUnavailable` / `.zoneBusy`), never on `serverRecordChanged`, so branch C/E always falls through to the exponential path.
- **Gate:** the task re-checks `state ∈ {.bootstrapping,.steady} && !accountResolutionInFlight && driver != nil` after the sleep, then calls `driver.sendChanges()`. This is **send-only** and **replicates `requestSync`'s operational-state guard** (it does *not* call `requestSync`, which would also fetch) — branch C/E already merged the server tag from `error.serverRecord`, so no fetch is needed to converge, and a fetch-side re-add is already carrying fresh server state.
- **Backoff reset:** reset `attempt = 0` only on **real forward progress** — a `sentRecordZoneChanges` with at least one `savedRecords`/`deletedRecordIDs` **and** no re-add this batch (`queueDrainNeedsSend == false`). Gating the reset on "no re-add" prevents a stream of healthy edits (which keep confirming saves) from pinning a genuinely-stuck retriable record's delay at the 1s floor.
- **Convergence:** branch E is "one loser per server round; converges" (§5.3); branch F *removes* the change (never re-added), so the drain queue only ever holds retriable/conflict re-adds that converge. The 64s cap bounds worst-case to ≤1 send/64s. No max-attempts cliff (a genuine delete/save must eventually land); persistent inability to drain surfaces as a non-empty `pendingCount` → `.waiting`/`.offline` status.
- **Lifecycle:** `queueDrainTask?.cancel(); queueDrainTask = nil` is added to `stop()` (`:244-245`, next to the existing `flushTask?.cancel()`/`fetchCycleSweepTask?.cancel()`), `prepareForAccountSwitch()` (`:97-98`, likewise), and the `.purged` branch (`:349` — which has **no** sibling task-cancels, so the drain cancel goes in standalone beside `driver?.shutdown()`). Cancelling is defence-in-depth: the post-sleep `driver != nil` guard already no-ops once teardown nils the driver.

**Contract delta (explicit, non-escalation):** §5.5 ("rely on the engine's own scheduling/backoff … no explicit `sendChanges()`") and §5.3 branch R ("honour `retryAfterSeconds`") assumed the engine reschedules; under `automaticallySync = false` that assumption is false and the device evidence proves it (26-min stall). D-4 is the named amendment: an explicit, backoff-aware re-send that only drains changes the funnel/conflict handler **already enqueued** (never a new mutation — I2/I1 untouched) — funnel discipline (§1.1) is preserved and `automaticallySync` stays `false`. Task 3 also **corrects the now-false in-code comments** ("rely on engine backoff", `:513-514`/`:532`) to point at this explicit gated re-send. This is *not* a revisit of `automaticallySync`; if the maintainer wants that revisited, that is design-tier (see MD-2).

### D-5 — Reconnect trigger via `NWPathMonitor`, satisfied-edge only, gated, no polling
A new `NetworkReachabilityMonitor` wraps `NWPathMonitor` on a background queue and hops to the main actor. It publishes `isOnline` and fires `onReconnect` **only on an unsatisfied → satisfied edge** (never on the first satisfied sample, so launch-while-online does not double-fire with the foreground trigger). The facade owns one instance, starts it when sync is enabled/attached, cancels it on disable. `onReconnect` calls `syncNow()` (→ gated `requestSync`), so it composes with D-A: no send while disabled / purged / mid-resolution. Event-driven, zero polling (proportionality / battery). The same `isOnline` feeds the status's `.offline` branch — one monitor, two consumers.

### D-6 — Pending count is outbound-only; deferred sets count too; purged is out-of-band
`pendingCount` = `controller.pendingChangeCount` (driver `pendingRecordZoneChanges.count + pendingDatabaseChanges.count` — **outbound only**) + the facade's own deferred-set sizes (pre-attach buffer, #294). It deliberately **excludes** `store.failedApplies`: those are *inbound* apply failures that self-heal via the §5.6 fetch-cycle sweep, not work a send / Sync Now / reconnect can drain — surfacing them as "Waiting to sync (N changes)" would both mislabel (nothing the user can flush) and go stale (the sweep mutating `failedApplies` runs in a detached `Task` outside `handle(_:)`, so it can't fire `onStatusChanged`). The issue's own truth list is "pending queue + deferred-change sets + in-flight" — inbound apply retries are out of scope for the display. `.purged` is **not** a status case: `handleZoneDeletions` sets `SharedData.deviceSyncEnabled = false` (`SyncEngineController.swift:346`), so `isEnabled` flips false and the section collapses to the disabled toggle; the purge already has its own one-time notice (`.syncEnginePurged`, `:348`). Status `paused` covers only `.signedOut`/`.accountChanged`.

---

## Maintainer decisions (UX forks — recommendation first; implement the recommendation unless the maintainer overrides on the PR)

- **MD-1 — Status wording & cause specificity.** Recommendation: adopt the issue's labels verbatim — **Synced** (+ "Last synced X ago"), **Waiting to sync (N changes)**, **Syncing…**, **Offline** (when offline with a non-empty queue), **Sync issue** — and make "Sync issue" name the cause for the two known paused reasons ("Signed out of iCloud" / "iCloud account changed") while staying generic otherwise. Alternative: a single generic "Sync issue" for all paused states (less informative). *Low-stakes; plan implements the recommendation.*
- **MD-2 — Re-send aggressiveness.** Recommendation **A (event-driven only):** reconnect edge + post-send CKError-aware backoff (2→64 s cap, honour `retryAfterSeconds`) + the existing foreground/push/enqueue triggers; **no periodic timer** (battery; "no busy polling"). Alternative **B:** add a low-frequency foreground-only flush timer (e.g. 60 s while `pendingCount > 0`) for extra resilience at a battery cost. Alternative **C (design-tier):** flip `automaticallySync = true` and let CKSyncEngine schedule — this abandons §1.1 funnel discipline and is **out of scope / escalate** if desired. *Plan implements A.*
- **MD-3 — Reconnect fetch scope.** Recommendation **A:** on the reconnect edge do a full `syncNow()` (fetch **and** send) — a device that was offline likely also missed inbound pushes (the #335(a) missed-push class), so the fetch is warranted. Alternative **B:** send-only when `pendingCount > 0` (lighter, but misses inbound changes). *Plan implements A.*

---

## File structure

| File | Responsibility | Change |
|---|---|---|
| `Foqos/Utils/NetworkReachabilityMonitor.swift` | `NWPathMonitor` wrapper: `isOnline`, satisfied-edge `onReconnect`, testable `handlePathUpdate(isSatisfied:)` | Create |
| `Foqos/CloudKit/SyncEngine/SyncEngineEvent.swift` | add `willSendChanges` / `didSendChanges` cases | Modify |
| `Foqos/CloudKit/SyncEngine/CKSyncEngineDriver.swift` | translate `willSendChanges`/`didSendChanges` (were `nil`, `:182-184`) | Modify |
| `Foqos/CloudKit/SyncEngine/SyncEngineController.swift` | `isSending`/`isFetching`/`isInFlight`; `pendingChangeCount`; `lastSuccessfulSyncDate`; `onStatusChanged`; `queueDrainTask`+backoff; cancel in `stop`/`prepareForAccountSwitch`/`.purged`; fire hook in `handle` | Modify |
| `Foqos/CloudKit/SyncEngine/SyncEngineControlling.swift` | add read-only status accessors + `onStatusChanged` to the seam | Modify |
| `Foqos/CloudKit/ProfileSyncManager.swift` | own `NetworkReachabilityMonitor`; `SyncStatusSnapshot` + pure `deriveStatus(...)`; publish `syncStatus`+`isSyncing`+`lastSyncDate` from it; wire `onStatusChanged` + `onReconnect`; count deferred sets; retire dead fields | Modify |
| `Foqos/Views/SettingsView.swift` | render the derived snapshot (label/color/spinner/last-synced); Sync-Now spinner+disable from real in-flight | Modify |
| `FoqosTests/Mocks/MockSyncEngineControlling.swift` | implement the new seam accessors + `onStatusChanged` | Modify |
| `FoqosTests/Mocks/MockSyncEngineDriver.swift` | add settable pending record/database arrays (both are `private(set)`, `:24-29` — Task 0 confirms) | Modify |
| `FoqosTests/SyncEngineFacadeTests.swift` | migrate `:52`/`:62` `syncStatus == .idle/.disabled` assertions onto `syncStatusSnapshot.status` (the old field is retired) | Modify |
| `FoqosTests/NetworkReachabilityMonitorTests.swift` | edge-detection + callback units | Create |
| `FoqosTests/SyncEngineStatusTests.swift` | in-flight, pending count, last-sync, hook-fires units | Create |
| `FoqosTests/SyncEngineQueueDrainTests.swift` | drain scheduling, backoff, gating, cancellation units | Create |
| `FoqosTests/SyncStatusDerivationTests.swift` | pure `deriveStatus` table + facade wiring + reconnect trigger units | Create |

Follow existing patterns: `SyncEngineControllerTests`/`SyncEngineControllerCutoverTests` build a controller with `MockSyncEngineDriver` via `driverFactory`; `SyncEngineFacadeTests`/`SyncEngineAttachTests` reset `engineController` in setUp/tearDown and inject `MockSyncEngineControlling`.

---

## Task 0: Citation refresh + baseline (do first)

**Files:** none — verification only.

- [ ] **Step 1: Re-locate every anchor** and record current lines:

```bash
cd <worktree>
grep -n "@Published var isSyncing\|@Published var lastSyncDate\|@Published var connectedDeviceCount\|@Published var syncStatus\|enum SyncStatus\|var displayText\|syncStatus = isEnabled\|syncStatus = enabled" Foqos/CloudKit/ProfileSyncManager.swift
grep -n "deferredProfileSaveIds\|deferredLocationSaveIds\|deferredDeleteRecordNames\|deferredEmergency\|func syncNow\|syncPausedReason\|func markSyncReadyAndFlush\|func attachEngine\|func buildEngine" Foqos/CloudKit/ProfileSyncManager.swift
grep -n "profileSyncManager.isSyncing\|profileSyncManager.syncStatus\|profileSyncManager.lastSyncDate\|syncStatusColor\|syncErrorMessage\|Sync Now\|Sync Status" Foqos/Views/SettingsView.swift
grep -n "private(set) var state\|var driver: SyncEngineDriver!\|func handle(_ event\|func start()\|func stop()\|case .purged\|func prepareForAccountSwitch\|func handleSentRecordZoneChanges\|func handleSentDatabaseChanges\|func handleFailedSave\|func handleFailedDelete\|func handleDidFetchChanges\|func isRetriable\|flushTask\|fetchCycleSweepTask\|accountResolutionInFlight\|func requestSync" Foqos/CloudKit/SyncEngine/SyncEngineController.swift Foqos/CloudKit/SyncEngine/SyncEngineController+Cutover.swift
grep -n "willSendChanges\|didSendChanges\|willFetchChanges\|didFetchChanges\|case .stateUpdate\|func translate" Foqos/CloudKit/SyncEngine/CKSyncEngineDriver.swift Foqos/CloudKit/SyncEngine/SyncEngineEvent.swift
grep -n "pendingRecordZoneChanges\|pendingDatabaseChanges" Foqos/CloudKit/SyncEngine/SyncEngineDriver.swift
grep -n "var failedApplies" Foqos/CloudKit/SyncEngine/SyncEngineStore.swift
grep -n "protocol SyncEngineControlling" Foqos/CloudKit/SyncEngine/SyncEngineControlling.swift
```

- [ ] **Step 2: Confirm dead-field readers across BOTH targets** so retirement is safe:
```bash
grep -rn "connectedDeviceCount\|profileSyncManager.error\|\.syncStatus\|\.isSyncing\|\.lastSyncDate\|SyncStatus" Foqos FoqosTests
```
Expect: `connectedDeviceCount`/`error` are declarations only (retire them); `syncStatus`/`isSyncing`/`lastSyncDate` are read by `SettingsView` (Task 6 rewrites) **and** asserted by `FoqosTests/SyncEngineFacadeTests.swift:52` (`== .idle`) / `:62` (`== .disabled`) — those two assertions **must be migrated** onto `syncStatusSnapshot.status` in Task 4, not left dangling. Any *other* reader found ⇒ keep that field; note it.

- [ ] **Step 3: Inspect `MockSyncEngineDriver`** (`FoqosTests/Mocks/MockSyncEngineDriver.swift`): confirm `pendingRecordZoneChanges`/`pendingDatabaseChanges` are `private(set)` (`:24, :29`) and thus **not** test-settable today — Task 2b/3 add `setPendingRecordZoneChangesForTest(_:)` and `setPendingDatabaseChangesForTest(_:)`. Confirm the send-counter is named `sendChangesCount` (`:24`), **not** `sendChangesCallCount` (the tasks' tests use `sendChangesCount`). Confirm how tests drive events (`controller.handle(_:)` passthrough).

- [ ] **Step 4: Confirm `store.failedApplies` + `CKError.retryAfterSeconds` API shapes:** read `SyncEngineStore.swift:224-242` — `func addFailedApply(_ entry: FailedApply)` takes the **struct** (`FailedApply(recordName:recordType:op:)`), not named args. Confirm `CKError.retryAfterSeconds` compiles (`error.retryAfterSeconds` returns `Double?` on the Swift `CKError` overlay); **if it does not**, Task 3 uses the fallback `(error as NSError).userInfo[CKErrorRetryAfterKey] as? Double` via a small private helper.

- [ ] **Step 5: Confirm in-module reachability** (`@testable import FamilyFoqos`): `state`, `driver`, `handle(_:)`, `store` are all readable/callable from tests (they are `internal` / `private(set) var` per the Phase-F widening comment `SyncEngineController.swift:43-45`). Note any `private` needing a minimal bump.

- [ ] **Step 6: Boot the simulator once, baseline green:**

```bash
xcrun simctl list devices available | grep "iPhone 17"   # pick UUID
xcrun simctl boot <UUID>
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' \
  -only-testing:FoqosTests/SyncEngineControllerTests -only-testing:FoqosTests/SyncEngineFacadeTests | xcpretty
```
Expected: PASS. If red, stop and report.

- [ ] **Step 7:** Reconcile any drifted anchor into the tasks below. No commit.

---

## Task 1: `NetworkReachabilityMonitor` (D-5)

**Files:** Create `Foqos/Utils/NetworkReachabilityMonitor.swift`; Test `FoqosTests/NetworkReachabilityMonitorTests.swift`.

**Interfaces:**
- Produces `@MainActor final class NetworkReachabilityMonitor: ObservableObject` with `@Published private(set) var isOnline: Bool`, `var onReconnect: (@MainActor () -> Void)?`, `func start()`, `func stop()`, and the test seam `func handlePathUpdate(isSatisfied: Bool)`.

- [ ] **Step 1: Failing tests** (drive the pure edge logic; never touch a real `NWPathMonitor`):

```swift
import XCTest
@testable import FamilyFoqos

@MainActor
final class NetworkReachabilityMonitorTests: XCTestCase {
  func testReconnectFiresOnlyOnUnsatisfiedToSatisfiedEdge() {
    let m = NetworkReachabilityMonitor()
    var reconnects = 0
    m.onReconnect = { reconnects += 1 }
    m.handlePathUpdate(isSatisfied: true)   // first sample: adopt, do NOT fire
    XCTAssertTrue(m.isOnline)
    XCTAssertEqual(reconnects, 0)
    m.handlePathUpdate(isSatisfied: false)  // go offline
    XCTAssertFalse(m.isOnline)
    XCTAssertEqual(reconnects, 0)
    m.handlePathUpdate(isSatisfied: true)   // edge: fire once
    XCTAssertTrue(m.isOnline)
    XCTAssertEqual(reconnects, 1)
    m.handlePathUpdate(isSatisfied: true)   // still satisfied: no re-fire
    XCTAssertEqual(reconnects, 1)
  }
}
```

- [ ] **Step 2: Run — FAIL** (type undefined). Run:
`xcodebuild test … -only-testing:FoqosTests/NetworkReachabilityMonitorTests | xcpretty` → FAIL.

- [ ] **Step 3: Implement.** First satisfied sample adopts state without firing (`lastKnownSatisfied` starts `nil`); fire only on `false → true`.

```swift
import Foundation
import Network

/// Wraps NWPathMonitor to (a) publish `isOnline` for the sync-status UI and (b) fire
/// `onReconnect` exactly once per offline→online edge so a queued-while-offline change
/// re-drives sync without a manual poke (#335). Event-driven; no polling. The NWPathMonitor
/// plumbing is integration-only — `handlePathUpdate(isSatisfied:)` holds the pure logic the
/// unit tests drive (mirrors how CKSyncEngineDriver isolates its untestable SDK edge).
@MainActor
final class NetworkReachabilityMonitor: ObservableObject {
  @Published private(set) var isOnline: Bool = true
  var onReconnect: (@MainActor () -> Void)?

  private var monitor: NWPathMonitor?
  private let queue = DispatchQueue(label: "com.cynexia.family-foqos.reachability")
  private var lastKnownSatisfied: Bool?

  func start() {
    guard monitor == nil else { return }
    let monitor = NWPathMonitor()
    self.monitor = monitor
    monitor.pathUpdateHandler = { [weak self] path in
      let satisfied = path.status == .satisfied
      Task { @MainActor in self?.handlePathUpdate(isSatisfied: satisfied) }
    }
    monitor.start(queue: queue)
  }

  func stop() {
    monitor?.cancel()
    monitor = nil
    lastKnownSatisfied = nil
  }

  /// Pure transition logic (unit-tested). Adopts the first sample silently; fires
  /// `onReconnect` only on a genuine unsatisfied→satisfied edge.
  func handlePathUpdate(isSatisfied: Bool) {
    let wasSatisfied = lastKnownSatisfied
    lastKnownSatisfied = isSatisfied
    isOnline = isSatisfied
    if wasSatisfied == false && isSatisfied == true {
      Log.info("Network reconnected; re-driving sync", category: .sync)
      onReconnect?()
    }
  }
}
```

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat(#335): NetworkReachabilityMonitor with offline→online reconnect edge"`

---

## Task 2a: In-flight signal — `willSendChanges`/`didSendChanges` + fetch brackets (D-2)

**Files:** Modify `SyncEngineEvent.swift`, `CKSyncEngineDriver.swift`, `SyncEngineController.swift`; Test `FoqosTests/SyncEngineStatusTests.swift` (new).

**Interfaces:** Produces `SyncEngineController.isInFlight: Bool` (computed from `isSending || isFetching`), driven by the new send brackets + the existing fetch brackets.

- [ ] **Step 1: Failing tests** (drive the controller with `MockSyncEngineDriver` via `driverFactory`; mirror `SyncEngineControllerTests` construction — Task 0 recorded the helper):

```swift
@MainActor
func testInFlightTracksSendAndFetchBrackets() throws {
  let (controller, _) = makeStartedController()   // helper mirrors SyncEngineControllerTests
  XCTAssertFalse(controller.isInFlight)
  controller.handle(.willSendChanges)
  XCTAssertTrue(controller.isInFlight)
  controller.handle(.sentRecordZoneChanges(savedRecords: [], failedRecordSaves: [],
                                           deletedRecordIDs: [], failedRecordDeletes: []))
  controller.handle(.didSendChanges)              // Task 0: confirm SDK delivers didSendChanges even on empty send
  XCTAssertFalse(controller.isInFlight)
  controller.handle(.willFetchChanges)
  XCTAssertTrue(controller.isInFlight)
  controller.handle(.didFetchChanges)
  XCTAssertFalse(controller.isInFlight)
}
```

- [ ] **Step 2: Run — FAIL** (`willSendChanges`/`didSendChanges`/`isInFlight` undefined).

- [ ] **Step 3a: Event cases** — `SyncEngineEvent.swift`, after `didFetchChanges`:

```swift
  case willSendChanges  // in-flight bracket (status, #316)
  case didSendChanges   // in-flight bracket (status, #316)
```

- [ ] **Step 3b: Translate** — `CKSyncEngineDriver.translate`, replace the `willSendChanges`/`didSendChanges` arm of the `.willFetchRecordZoneChanges, …` `nil` group (`:182-184`) so those two now map:

```swift
case .willSendChanges: return .willSendChanges
case .didSendChanges: return .didSendChanges
case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
  return nil  // not consumed by the controller
```

- [ ] **Step 3c: Controller flags + handling** — add near `state` (`SyncEngineController.swift:~37`):

```swift
private(set) var isSending = false
private(set) var isFetching = false
var isInFlight: Bool { isSending || isFetching }
```
In `handle(_:)`'s switch add `.willSendChanges` → `isSending = true`; `.didSendChanges` → `isSending = false`. In `handleWillFetchChanges` set `isFetching = true`; in `handleDidFetchChanges` set `isFetching = false` (both already exist — add the one line). **Defensive close (D-2):** also set `isSending = false` at the top of `handleSentRecordZoneChanges`/`handleSentDatabaseChanges` — a completed sent event implies the send bracket closed, so a dropped `didSendChanges` cannot wedge "Syncing…". (The symmetric teardown reset of both flags lands in Task 3 §3d.) Keep all existing behavior in those handlers.

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat(#316): surface engine in-flight state via send/fetch brackets"`

---

## Task 2b: `pendingChangeCount`, `lastSuccessfulSyncDate`, `onStatusChanged` + seam (D-1, D-3)

**Files:** Modify `SyncEngineController.swift`, `SyncEngineControlling.swift`, `FoqosTests/Mocks/MockSyncEngineControlling.swift`; Test `SyncEngineStatusTests.swift`.

**Interfaces:** Produces on the controller (and the `SyncEngineControlling` seam):
- `var pendingChangeCount: Int` — `driver.pendingRecordZoneChanges.count + driver.pendingDatabaseChanges.count` (**outbound only**, D-6; 0 when `driver == nil`).
- `var lastSuccessfulSyncDate: Date?`
- `var isInFlight: Bool` (from Task 2a — add to the seam here).
- `var onStatusChanged: (@MainActor () -> Void)?`

- [ ] **Step 1: Failing tests** (Task 0 confirmed `MockSyncEngineDriver` needs `setPendingRecordZoneChangesForTest`/`setPendingDatabaseChangesForTest`; add them here):

```swift
@MainActor
func testPendingChangeCountCountsOutboundRecordAndDatabaseChanges() throws {
  let (controller, driver) = makeStartedController()
  driver.setPendingRecordZoneChangesForTest([.saveRecord(sampleRecordID()), .deleteRecord(sampleRecordID())])
  driver.setPendingDatabaseChangesForTest([.saveZone(CKRecordZone(zoneName: "z"))])
  XCTAssertEqual(controller.pendingChangeCount, 3)   // failedApplies (inbound) deliberately NOT counted (D-6)
}

@MainActor
func testDidFetchStampsLastSyncAndFiresStatusHook() throws {
  let (controller, _) = makeStartedController()
  var ticks = 0
  controller.onStatusChanged = { ticks += 1 }
  XCTAssertNil(controller.lastSuccessfulSyncDate)
  controller.handle(.didFetchChanges)
  XCTAssertNotNil(controller.lastSuccessfulSyncDate)
  XCTAssertGreaterThanOrEqual(ticks, 1)
}

@MainActor
func testSentStampsLastSyncOnlyWithProgressAndNoFailure() throws {
  let (controller, _) = makeStartedController()
  // Empty send: NO stamp (an aborted/no-op send must not read "Synced").
  controller.handle(.sentRecordZoneChanges(savedRecords: [], failedRecordSaves: [],
                                           deletedRecordIDs: [], failedRecordDeletes: []))
  XCTAssertNil(controller.lastSuccessfulSyncDate)
  // Progress + no failure: stamp.
  controller.handle(.sentRecordZoneChanges(savedRecords: [sampleRecord()], failedRecordSaves: [],
                                           deletedRecordIDs: [], failedRecordDeletes: []))
  let afterProgress = controller.lastSuccessfulSyncDate
  XCTAssertNotNil(afterProgress)
  // Progress but WITH a failure: no new stamp.
  controller.handle(.sentRecordZoneChanges(savedRecords: [sampleRecord()],
                                           failedRecordSaves: [(sampleRecord(), CKError(.serviceUnavailable))],
                                           deletedRecordIDs: [], failedRecordDeletes: []))
  XCTAssertEqual(controller.lastSuccessfulSyncDate, afterProgress)
}
```

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3a: Controller accessors** (outbound-only count — D-6):

```swift
var pendingChangeCount: Int {
  guard let driver else { return 0 }
  return driver.pendingRecordZoneChanges.count + driver.pendingDatabaseChanges.count
}
private(set) var lastSuccessfulSyncDate: Date?
var onStatusChanged: (@MainActor () -> Void)?

private func notifyStatusChanged() { onStatusChanged?() }
```

- [ ] **Step 3b: Stamp + fire.** In `handleDidFetchChanges` set `lastSuccessfulSyncDate = Date()` (an empty fetch is still a real round-trip). In `handleSentRecordZoneChanges`, stamp only when `!savedRecords.isEmpty || !deletedRecordIDs.isEmpty` **and** `failedRecordSaves.isEmpty && failedRecordDeletes.isEmpty`; in `handleSentDatabaseChanges`, stamp only when `!savedZones.isEmpty || !deletedZoneIDs.isEmpty` **and** `failedZoneSaves.isEmpty && failedZoneDeletes.isEmpty` (D-3: progress + no failure — an empty send never stamps). Fire `notifyStatusChanged()` at the **end of `handle(_:)`** (single call site, after the `switch`) so every event that could change pending/in-flight/last-sync re-publishes — the "trigger×status" guarantee.

- [ ] **Step 3c: Seam** — add to `SyncEngineControlling` (`SyncEngineControlling.swift`, after `requestSync()`):

```swift
var isInFlight: Bool { get }
var pendingChangeCount: Int { get }
var lastSuccessfulSyncDate: Date? { get }
var onStatusChanged: (@MainActor () -> Void)? { get set }
```
Implement on `MockSyncEngineControlling`: stored `var isInFlight = false`, `var pendingChangeCount = 0`, `var lastSuccessfulSyncDate: Date?`, `var onStatusChanged: (@MainActor () -> Void)?` + a `func fireStatusChangedForTest() { onStatusChanged?() }` helper.

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat(#316): expose pendingChangeCount, lastSync, and onStatusChanged via the facade seam"`

---

## Task 3: Queue-drain re-send scheduler (D-4, the #335(b) fix)

**Files:** Modify `SyncEngineController.swift`; Test `FoqosTests/SyncEngineQueueDrainTests.swift` (new).

**Interfaces:** Produces a controller-internal `queueDrainTask`/backoff that (re)arms after a `sentRecordZoneChanges`/`sentDatabaseChanges` event that left pending changes, and re-sends via `driver.sendChanges()` after a CKError-aware delay, gated on operational state and cancelled on teardown. No new public API.

- [ ] **Step 1: Failing tests** (inject a **zero delay** via a debug seam so the test does not sleep; mirror the `#if DEBUG` delay-override pattern used for `accountResolutionRetryDelayNanoseconds` in `ProfileSyncManager`). **Use a retriable error** (`.serviceUnavailable`), not `.serverRecordChanged`: `handleFailedSave` returns early on `guard let server = error.serverRecord else { return }` (`SyncEngineController.swift:563`) and a test-built `CKError(.serverRecordChanged)` carries no `serverRecord`, so it would never re-add; a retriable error hits **branch R** (`:588-589`) and re-adds unconditionally, which is what arms the drain:

```swift
@MainActor
func testRetriableReAddSchedulesADrainSend() async throws {
  let (controller, driver) = makeStartedController()
  controller.setQueueDrainDelayForTest(0)                     // #if DEBUG seam
  driver.reset()
  // A retriable failed save re-adds the change (branch R) then the handler returns.
  controller.handle(.sentRecordZoneChanges(
    savedRecords: [], failedRecordSaves: [(sampleRecord(), CKError(.serviceUnavailable))],
    deletedRecordIDs: [], failedRecordDeletes: []))
  await controller.drainTaskForTest?.value                    // await the scheduled drain
  XCTAssertGreaterThanOrEqual(driver.sendChangesCount, 1)     // it re-sent without a manual poke
}

@MainActor
func testDrainDoesNotSendWhenNothingReAdded() async throws {
  let (controller, driver) = makeStartedController()
  controller.setQueueDrainDelayForTest(0)
  driver.reset()
  controller.handle(.sentRecordZoneChanges(savedRecords: [sampleRecord()], failedRecordSaves: [],
                                           deletedRecordIDs: [], failedRecordDeletes: []))
  await controller.drainTaskForTest?.value
  XCTAssertEqual(driver.sendChangesCount, 0)                  // clean send, no re-add ⇒ no drain
}

@MainActor
func testFetchSideReAddAlsoDrains() async throws {
  let (controller, driver) = makeStartedController()
  controller.setQueueDrainDelayForTest(0)
  // Force a fetch-side re-add: an equal-version-divergence / I9 auto-heal path leaves a pending
  // save (setup mirrors the SyncEngineController §5.1 tests — seed the local+incoming versions so
  // handleFetchedRecordZoneChanges re-enqueues at :419/:434). Then close the cycle.
  seedEqualVersionDivergence(controller)   // helper: produces a fetch re-add (see SyncEngineControllerTests §5.1)
  driver.reset()
  controller.handle(.didFetchChanges)
  await controller.drainTaskForTest?.value
  XCTAssertGreaterThanOrEqual(driver.sendChangesCount, 1)     // fetch/sweep re-adds drain too, not only sent* ones
}

@MainActor
func testDrainGatedOffWhenNonOperational() async throws {
  let (controller, driver) = makeStartedController()
  controller.setQueueDrainDelayForTest(0)
  controller.forceStateForTest(.disabled)                     // #307 debug seam — leaves driver live
  driver.reset()
  controller.handle(.sentRecordZoneChanges(
    savedRecords: [], failedRecordSaves: [(sampleRecord(), CKError(.serviceUnavailable))],
    deletedRecordIDs: [], failedRecordDeletes: []))          // needsSend IS set (branch R re-add) …
  await controller.drainTaskForTest?.value
  XCTAssertEqual(driver.sendChangesCount, 0)                 // … but the D-A gate blocks the send
}

@MainActor
func testStopCancelsPendingDrainAndClearsInFlight() async throws {
  let (controller, driver) = makeStartedController()
  controller.setQueueDrainDelayForTest(1_000_000_000)        // 1 s so cancel can win
  controller.handle(.willSendChanges)                        // isSending = true
  controller.handle(.sentRecordZoneChanges(
    savedRecords: [], failedRecordSaves: [(sampleRecord(), CKError(.serviceUnavailable))],
    deletedRecordIDs: [], failedRecordDeletes: []))
  controller.stop()
  XCTAssertNil(controller.drainTaskForTest)                  // drain torn down, not left running
  XCTAssertFalse(controller.isInFlight)                      // in-flight flags reset on teardown (D-2)
}
```

- [ ] **Step 2: Run — FAIL** (seams/scheduler undefined).

- [ ] **Step 3a: Scheduler state + seams** (near the other `Task` fields, `SyncEngineController.swift:~54-56`):

```swift
private var queueDrainTask: Task<Void, Never>?
private var queueDrainAttempt = 0
private var queueDrainNeedsSend = false
private var queueDrainRetryAfter: TimeInterval?
private static let queueDrainMaxDelaySeconds: Double = 64
#if DEBUG
  private var queueDrainDelayOverrideNanos: UInt64?
  func setQueueDrainDelayForTest(_ nanos: UInt64) { queueDrainDelayOverrideNanos = nanos }
  var drainTaskForTest: Task<Void, Never>? { queueDrainTask }
#endif
```

- [ ] **Step 3b: Mark re-adds (send AND fetch/sweep sides).** At each re-add site set `queueDrainNeedsSend = true`:
  - send side — `handleFailedSave`/`handleFailedDelete`/`handleSentDatabaseChanges` `driver.add(...)` at `:532, 541, 578, 582, 585, 589, 610, 613`;
  - fetch/sweep side — `handleFetchedRecordZoneChanges` equal-version / I9 auto-heal `:419, 434`; `retryFailedApplies` `:812, 841`.

  Where the failing error is available (the send-side branches), capture `queueDrainRetryAfter = max(queueDrainRetryAfter ?? 0, retryAfterSeconds(error) ?? 0)` (keep the max seen this event; `retryAfterSeconds(_:)` is the helper from Step 3e). **Backoff reset (D-4 refinement):** in `handleSentRecordZoneChanges`, reset `queueDrainAttempt = 0` **only** when there was progress (`!savedRecords.isEmpty || !deletedRecordIDs.isEmpty`) **and** no re-add this batch (`queueDrainNeedsSend == false` at that point) — real forward movement, so a stream of healthy edits can't pin a stuck record's delay at the floor.

- [ ] **Step 3c: Arm after the handler.** At the **end of `handle(_:)`** (after `notifyStatusChanged()`), for the re-enqueue-bearing events (`sentRecordZoneChanges`, `sentDatabaseChanges`, `didFetchChanges`):

```swift
if queueDrainNeedsSend { scheduleQueueDrain() }
queueDrainNeedsSend = false
```

```swift
/// §1.1-safe: the actual sendChanges runs in the Task body, after this handler returns. Send-only;
/// replicates requestSync's operational-state guard (does NOT call requestSync — no fetch needed).
private func scheduleQueueDrain() {
  guard driver != nil, state == .bootstrapping || state == .steady, !accountResolutionInFlight
  else { return }
  guard !driver.pendingRecordZoneChanges.isEmpty || !driver.pendingDatabaseChanges.isEmpty
  else { return }
  queueDrainTask?.cancel()
  let attempt = queueDrainAttempt
  let delayNanos = drainDelayNanos(attempt: attempt, retryAfter: queueDrainRetryAfter)
  queueDrainRetryAfter = nil
  queueDrainAttempt = min(attempt + 1, 6)   // caps exponent at 2^6 = 64 s
  queueDrainTask = Task { @MainActor [weak self] in
    do { try await Task.sleep(nanoseconds: delayNanos) } catch { return }
    guard let self, self.driver != nil,
          self.state == .bootstrapping || self.state == .steady,
          !self.accountResolutionInFlight else { return }
    guard !self.driver.pendingRecordZoneChanges.isEmpty
       || !self.driver.pendingDatabaseChanges.isEmpty else { return }
    Log.debug("queue-drain re-send (attempt \(attempt))", category: .sync)
    self.driver.sendChanges()
  }
}

private func drainDelayNanos(attempt: Int, retryAfter: TimeInterval?) -> UInt64 {
  #if DEBUG
    if let override = queueDrainDelayOverrideNanos { return override }
  #endif
  let base = retryAfter ?? min(pow(2.0, Double(attempt)), Self.queueDrainMaxDelaySeconds)
  return UInt64(max(0, base) * 1_000_000_000)
}
```

- [ ] **Step 3d: Cancel + clear in-flight on teardown.** Add `queueDrainTask?.cancel(); queueDrainTask = nil` **and** `isSending = false; isFetching = false` to `stop()` (next to the existing `flushTask?.cancel()`/`fetchCycleSweepTask?.cancel()` at `:244-245`), `prepareForAccountSwitch()` (likewise, `:97-98`), and the `.purged` branch (**standalone** beside `driver?.shutdown()` at `:349` — that branch has **no** existing task-cancels). This keeps `state ∈ {.disabled,.purged} ⇒ isInFlight == false` and no orphaned drain, symmetric with the #307 orphan-ban.

- [ ] **Step 3e: `retryAfterSeconds` helper + correct the stale comments.** Add a private helper (Task 0 decided which form compiles):

```swift
private func retryAfterSeconds(_ error: CKError) -> TimeInterval? {
  error.retryAfterSeconds ?? (error as NSError).userInfo[CKErrorRetryAfterKey] as? TimeInterval
}
```
Then update the now-false in-code comments that D-4 supersedes: `SyncEngineController.swift:513-514` ("re-added and left to the engine's own backoff") and `:532` ("// rely on engine backoff") → reference the explicit gated queue-drain (D-4) instead. No behavior change; keeps code and the §5.5 amendment consistent.

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat(#335): backoff-aware queue-drain re-send after conflict/retriable re-adds"`

---

## Task 4: Facade — derived `SyncStatusSnapshot` + wiring (D-1, D-3, D-6)

**Files:** Modify `ProfileSyncManager.swift`; Test `FoqosTests/SyncStatusDerivationTests.swift` (new).

**Interfaces:** Produces
- `enum SyncDisplayStatus: Equatable { case disabled, synced, waiting(Int), syncing, offline, paused(SyncPausedReason) }`
- `struct SyncStatusSnapshot: Equatable { let status: SyncDisplayStatus; let lastSyncDate: Date?; var isSyncing: Bool { status == .syncing } }`
- `static func deriveStatus(isEnabled:pausedReason:isInFlight:isOnline:pendingCount:) -> SyncDisplayStatus` (pure)
- `@Published private(set) var syncStatusSnapshot: SyncStatusSnapshot`
- retire the dead fields (D-6): remove `connectedDeviceCount` and `error` if Task 0 found no readers; keep `syncStatus`/`isSyncing`/`lastSyncDate` only if some non-Settings reader survives — otherwise the snapshot replaces them and SettingsView reads the snapshot (Task 6).

- [ ] **Step 1: Failing tests** (pure derivation table + a hook-driven publish):

```swift
func testDeriveStatusPrecedence() {
  typealias M = ProfileSyncManager
  XCTAssertEqual(M.deriveStatus(isEnabled: false, pausedReason: nil, isInFlight: false, isOnline: true, pendingCount: 5), .disabled)
  XCTAssertEqual(M.deriveStatus(isEnabled: true, pausedReason: .signedOut, isInFlight: true, isOnline: true, pendingCount: 5), .paused(.signedOut))
  XCTAssertEqual(M.deriveStatus(isEnabled: true, pausedReason: nil, isInFlight: true, isOnline: true, pendingCount: 5), .syncing)
  XCTAssertEqual(M.deriveStatus(isEnabled: true, pausedReason: nil, isInFlight: false, isOnline: false, pendingCount: 5), .offline)
  XCTAssertEqual(M.deriveStatus(isEnabled: true, pausedReason: nil, isInFlight: false, isOnline: false, pendingCount: 0), .synced)
  XCTAssertEqual(M.deriveStatus(isEnabled: true, pausedReason: nil, isInFlight: false, isOnline: true, pendingCount: 3), .waiting(3))
  XCTAssertEqual(M.deriveStatus(isEnabled: true, pausedReason: nil, isInFlight: false, isOnline: true, pendingCount: 0), .synced)
}

@MainActor
func testSnapshotRepublishesWhenControllerFiresStatusHook() async throws {
  let (mgr, controller) = makeAttachedManagerWithMockControlling()   // helper mirrors SyncEngineFacadeTests
  controller.pendingChangeCount = 2
  controller.isInFlight = false
  controller.fireStatusChangedForTest()
  XCTAssertEqual(mgr.syncStatusSnapshot.status, .waiting(2))
  controller.pendingChangeCount = 0
  controller.lastSuccessfulSyncDate = Date()
  controller.fireStatusChangedForTest()
  XCTAssertEqual(mgr.syncStatusSnapshot.status, .synced)
  XCTAssertNotNil(mgr.syncStatusSnapshot.lastSyncDate)
}
```

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3a: Types + pure derivation:**

```swift
enum SyncDisplayStatus: Equatable {
  case disabled, synced, waiting(Int), syncing, offline
  case paused(SyncPausedReason)
}
struct SyncStatusSnapshot: Equatable {
  let status: SyncDisplayStatus
  let lastSyncDate: Date?
  var isSyncing: Bool { status == .syncing }
}
static func deriveStatus(
  isEnabled: Bool, pausedReason: SyncPausedReason?, isInFlight: Bool,
  isOnline: Bool, pendingCount: Int
) -> SyncDisplayStatus {
  guard isEnabled else { return .disabled }
  if let pausedReason { return .paused(pausedReason) }
  if isInFlight { return .syncing }
  if !isOnline && pendingCount > 0 { return .offline }
  if pendingCount > 0 { return .waiting(pendingCount) }
  return .synced
}
```

- [ ] **Step 3b: Published snapshot + recompute.**

```swift
@Published private(set) var syncStatusSnapshot = SyncStatusSnapshot(status: .disabled, lastSyncDate: nil)

private var totalPendingCount: Int {
  let deferred = deferredProfileSaveIds.count + deferredLocationSaveIds.count
    + deferredDeleteRecordNames.count + (deferredEmergencySave ? 1 : 0)
    + deferredEmergencyUnblockEvents.count + (deferredEmergencyEpochSave ? 1 : 0)
  return (engineController?.pendingChangeCount ?? 0) + deferred
}

func recomputeSyncStatus() {
  let status = Self.deriveStatus(
    isEnabled: isEnabled, pausedReason: syncPausedReason,
    isInFlight: engineController?.isInFlight ?? false,
    isOnline: reachabilityMonitor.isOnline, pendingCount: totalPendingCount)
  let next = SyncStatusSnapshot(status: status, lastSyncDate: engineController?.lastSuccessfulSyncDate)
  if next != syncStatusSnapshot { syncStatusSnapshot = next }   // publish only on change (no SwiftUI thrash)
}
```

- [ ] **Step 3c: Wire the hook + monitor.** Add `let reachabilityMonitor = NetworkReachabilityMonitor()`. Subscribe to the monitor's `$isOnline` **once in `init()`** (Combine `.sink { [weak self] _ in self?.recomputeSyncStatus() }`, stored in `cancellables`) — **not** in `buildEngine`, which re-runs on every `reattachEngine` account switch (`ProfileSyncManager.swift:373`) and would leak a duplicate sink each time (`cancellables` is append-only, `:117`). In `buildEngine`, after `engineController = controller`, set `controller.onStatusChanged = { [weak self] in self?.recomputeSyncStatus() }`. Call `recomputeSyncStatus()` after each facade enqueue and in `markSyncReadyAndFlush`/`pauseSync`/`clearPause` so deferred-count and paused-reason changes publish immediately.

- [ ] **Step 3d: Retire dead fields + migrate the facade test.** Remove `connectedDeviceCount`/`error` (Task 0 confirmed no readers). Remove `syncStatus`/`isSyncing`/`lastSyncDate` and the `SyncStatus` enum, replacing the two writes at `ProfileSyncManager.swift:100, 108` with a `recomputeSyncStatus()` call. **Migrate `FoqosTests/SyncEngineFacadeTests.swift:52, 62`** (which assert `manager.syncStatus == .idle` / `== .disabled`) onto the snapshot: `XCTAssertEqual(manager.syncStatusSnapshot.status, .synced)` (enabled, empty queue) / `.disabled` — otherwise the baseline goes red.

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat(#316): derive an honest SyncStatusSnapshot from real queues + paused reason"`

---

## Task 5: Facade — reconnect trigger + monitor lifecycle (D-5, MD-3)

**Files:** Modify `ProfileSyncManager.swift`; Test `FoqosTests/SyncStatusDerivationTests.swift`.

**Interfaces:** Consumes `NetworkReachabilityMonitor.onReconnect`. Produces: the monitor is started when sync is enabled/attached and stopped on disable; `onReconnect` calls `syncNow()` (gated).

- [ ] **Step 1: Failing tests:**

```swift
@MainActor
func testReconnectDrivesSyncNowWhenReady() async throws {
  let (mgr, controller) = makeAttachedManagerWithMockControlling()
  mgr.isSyncReady = true
  controller.requestSyncCount = 0
  mgr.reachabilityMonitor.handlePathUpdate(isSatisfied: true)   // adopt
  mgr.reachabilityMonitor.handlePathUpdate(isSatisfied: false)  // offline
  mgr.reachabilityMonitor.handlePathUpdate(isSatisfied: true)   // edge → onReconnect → syncNow
  XCTAssertGreaterThanOrEqual(controller.requestSyncCount, 1)
}

@MainActor
func testDisableStopsMonitor() async throws {
  let (mgr, _) = makeAttachedManagerWithMockControlling()
  mgr.isEnabled = false
  XCTAssertFalse(mgr.reachabilityMonitor.isMonitoringForTest)   // #if DEBUG: monitor != nil
}
```
> `syncNow()` throwing `.notAttached` in the reconnect path is swallowed (log-only) — a reconnect is a best-effort nudge, never user-facing.

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Wire lifecycle.** In `buildEngine` (or `attachEngine`), set `reachabilityMonitor.onReconnect = { [weak self] in self?.reconnectDrivenSync() }` and `reachabilityMonitor.start()` when `isEnabled`. In the `$isEnabled` sink (`ProfileSyncManager.swift:103-117`): on enable, `reachabilityMonitor.start()`; on disable, `reachabilityMonitor.stop()`.

```swift
private func reconnectDrivenSync() {
  guard isEnabled, isSyncReady else { return }
  do { try syncNow() } catch {
    Log.warning("reconnect syncNow skipped: \(error.localizedDescription)", category: .sync)
  }
  recomputeSyncStatus()   // reflect that we're now online / draining
}
```
Add a `#if DEBUG var isMonitoringForTest: Bool` to `NetworkReachabilityMonitor` (`monitor != nil`) for the lifecycle test.

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat(#335): re-drive sync on network reconnect"`

---

## Task 6: Settings UI — render derived status + real Sync-Now feedback (#316)

**Files:** Modify `Foqos/Views/SettingsView.swift`. (UI; verified in the device section — no unit test, but the render must compile and preview.)

**Interfaces:** Consumes `profileSyncManager.syncStatusSnapshot`.

- [ ] **Step 1: Replace `syncStatusColor`** (`SettingsView.swift:33-…`) to switch on `profileSyncManager.syncStatusSnapshot.status`: `.synced` → green; `.syncing` → theme; `.waiting` → yellow/orange; `.offline` → gray; `.paused` → orange; `.disabled` → gray.

- [ ] **Step 2: Replace the status HStack** (`:167-196`) to render from the snapshot: spinner when `syncStatusSnapshot.isSyncing`, else the status dot; the label per MD-1 (`statusLabel(for:)` — "Synced" / "Waiting to sync (N changes)" / "Syncing…" / "Offline" / "Signed out of iCloud" / "iCloud account changed"); the "Last Synced" row bound to `syncStatusSnapshot.lastSyncDate` (`style: .relative`).

- [ ] **Step 3: Sync-Now feedback** — bind the button's trailing `ProgressView` and `.disabled(...)` (`:211, 217`) to `profileSyncManager.syncStatusSnapshot.isSyncing`. Keep the existing `syncErrorMessage` alert for a thrown `.notAttached` (`:198-217, 437-443`).

- [ ] **Step 4: Build + preview.** `xcodebuild … build | xcpretty` (PASS) and render the Settings preview to confirm each status string.

- [ ] **Step 5: Commit** — `git commit -m "feat(#316): render honest sync status + live Sync Now feedback in Settings"`

---

## Device verification (two devices, same iCloud account; reuse the #335 evidence scenarios as acceptance)

Run after the branch builds green. Boot the app on Device A and Device B, both signed into the **same** iCloud account, Profile Sync ON, foregrounded, with log export ready (Home → version footer "Debug mode" → Export Logs).

| # | Scenario (issue) | Steps | Pass criteria |
|---|---|---|---|
| DV-1 | **#335(a) offline edit** | On A: enable Airplane Mode. Edit a synced profile (name change). Confirm A shows **"Waiting to sync (1 change)"** then **"Offline"**. Disable Airplane Mode; **do not** tap Sync Now, keep A foregrounded. | Within a few seconds of reconnect, A's logs show `Network reconnected; re-driving sync` → `Sync requested` → a send; A's status flips **Offline/Waiting → Syncing… → Synced**; B receives the edit. **No manual poke.** |
| DV-2 | **#335(b) post-conflict re-send** | Force a `serverRecordChanged`: edit the same profile on A and B while B is briefly offline, then bring B online so A's next send loses the CAS. Keep A foregrounded and idle (no foreground transition, no new edit). | A's logs show the conflict (`older_remote_noop` / branch C-E re-add) followed **within the backoff window (≤~64 s), not 26 min,** by `queue-drain re-send` → a send that confirms; A ends **Synced**; no manual Sync Now. |
| DV-3 | **Honest status** | On A: queue an edit while offline (DV-1 setup) and read the indicator before reconnect. | Reads **"Waiting to sync (N changes)"** / **"Offline"** — never "Synced" — while the queue is non-empty; flips to **Synced** only after the queue drains. |
| DV-4 | **Sync Now feedback** | On A with something queued, tap **Sync Now**. | Button dims + spinner shows for the send/fetch; status reads **Syncing…**; on completion returns to the derived status (Synced or what remains). |
| DV-5 | **Paused honesty (regression)** | On A: sign out of iCloud (Settings → iCloud) to trigger `.signedOut`; then reproduce a different-account sign-in for `.accountChanged`. | Status reads **"Signed out of iCloud"** / **"iCloud account changed"** (per MD-1), not "Synced"; the #307/#341 account-change dialog/pause path still works; no send is driven while paused (D-A). |
| DV-6 | **Battery/proportionality sanity** | Leave A foregrounded and idle with an empty queue for 5 min; export logs. | **No** periodic sync sends and **no** repeated drain attempts on an empty queue (no busy polling). |

---

## Self-review checklist (run before opening the PR)

1. **Spec coverage:** #316 point 1 (honest status) → Tasks 2b/4/6; #316 point 2 (Sync-Now feedback) → Tasks 2a/6; #335(a) reconnect → Tasks 1/5; #335(b) queued/post-conflict re-send → Task 3 (arms after **both** `sent*` and `didFetchChanges`, so send-side *and* fetch/sweep re-adds drain). ✔
2. **D-A composition:** the reconnect trigger calls `syncNow()` → `requestSync`; the drain **replicates** `requestSync`'s operational-state guard (send-only, does not call it); no `start()`; `.purged` untouched. ✔
3. **§1.1:** the drain's `sendChanges()` runs in a `Task` body after `handle` returns; no fetch/send synchronously inside a handler; the drain only re-sends already-enqueued changes (no new mutation → I2/I1 clean). ✔
4. **automaticallySync stays false;** D-4 documents the §5.5 amendment and flags a real flip as design-tier (MD-2). ✔
5. **Placeholder scan / type consistency:** `SyncStatusSnapshot`, `SyncDisplayStatus`, `deriveStatus`, `pendingChangeCount`, `isInFlight`, `lastSuccessfulSyncDate`, `onStatusChanged`, `NetworkReachabilityMonitor.handlePathUpdate/onReconnect/isOnline` are named identically across the tasks that define and consume them. ✔
6. **MDs surfaced** (MD-1 wording, MD-2 aggressiveness, MD-3 reconnect scope) with recommendations, not silent choices. ✔
