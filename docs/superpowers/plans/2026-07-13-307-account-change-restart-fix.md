# #307 Account-Change Restart — Implementation Plan (plans the fix for #307)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This document **plans the fix for #307** — it is plan-only. No production code is changed by landing this document; implementation is a separate session.

**Goal:** Make `SyncEngineController` recover correctly from a CKSyncEngine account-change event — restart in place for the same iCloud user (the capture-proven common case), pause honestly when *confirmed* signed out, and offer a switch/combine/not-now choice for a *confirmed* different user — instead of stranding `state=.disabled` permanently while a live-but-orphaned driver limps sync (issue #307, confirmed H1).

**Architecture:** The controller stops *deciding* on account change. `handleAccountChange` (a) logs, (b) for `.signIn` suppresses sends (an `accountResolutionInFlight` gate) but does **not** tear down — so the ubiquitous same-account startup echo never flaps a running engine and no send leaks to a wrong account mid-decision — and for `.signOut`/`.switchAccounts` tears the driver down immediately, and (c) hands the `kind` to a facade-owned hook. `ProfileSyncManager` resolves the *actual* signed-in identity asynchronously using a **three-way** account availability signal (`available`/`noAccount`/`ambiguous`) plus a fresh `userRecordID` fetch, and only ever **disrupts on a confirmed change**: silent `start()` restart (confirmed same user, engine not operational), quiet surfaced pause (confirmed `noAccount`), or a three-choice reconstruction dialog (confirmed distinct real user). Every unconfirmed/transient/sentinel outcome leaves the running engine alone and schedules one bounded retry — never a teardown, never a destructive prompt. `requestSync`/`stop()`/purge are hardened so a non-operational (or mid-resolution) controller can never drive a live driver, a permanent state-transition log ships, and a facade-boundary invariant test enforces the orphan ban.

**Tech Stack:** Swift 6, `@MainActor` `SyncEngineController` + `ProfileSyncManager` + `CloudKitManager`, CKSyncEngine driver seam (`SyncEngineDriver`/`CKSyncEngineDriver`), SwiftData + UserDefaults-backed emergency state, `Log` (`.sync`/`.cloudKit`), XCTest (`FoqosTests`).

## Global Constraints

- **Plan-only. This session writes no production code.** Implementation is a separate session gated on this plan's review (AGENTS.md; issue #307 house rules). The PR that lands this document is titled/bodied "**plans the fix for #307**" — never "fixes".
- **Never force-commit/amend; new commits + Git revert only** (AGENTS.md).
- **No parallel build/test streams on this machine** — one implementation stream at a time (AGENTS.md).
- **Anchors are line-verified against `main` @ `9befa33` (post-#334/#336).** Re-run Task 0's citation refresh before editing — sibling PRs move line numbers.
- **`@SafeQuery` not `@Query`** in any view touched (AGENTS.md; pre-commit-enforced).
- **Logging:** `Log.…(…, category: .sync|.cloudKit)`; never log lock codes/PII. UUIDs, `userRecordName` values (CloudKit record ids, not personal identifiers), timestamps, and state values are acceptable.
- **Lock-check rule** (if lock/mode UI is touched): `== .child`, never `!= .parent`.
- **Tests:** boot the iPhone 17 simulator once by **UUID** (never device name), then `xcodebuild test … -destination 'platform=iOS Simulator,id=<UUID>'`. Pin time — one `let now = Date()` per test.
- **Scope guards (do not cross — escalate if forced):** the local wipe in the different-user "Switch" path is a **LOCAL wipe only** (SwiftData delete + UserDefaults emergency reset), never #310's server-wipe machinery. Do **not** touch the §8.1 reset sequence (`deleteZone`/`resetIntent`/reset command). Do **not** implement #316 — only expose the paused-state seam it will consume.

---

## Confirmed root cause (do not re-litigate)

`handleAccountChange` (`Foqos/CloudKit/SyncEngine/SyncEngineController.swift:321-326`) sets `state = .disabled`, bumps `namespaceGeneration`, cancels `startupTask`/`flushTask`, and **stops there** — never restarts, never nils `driver`, never touches `ProfileSyncManager.isEnabled`, never logs. The contract's designed other half — T7 "switch namespace (N11) → T1 for new user if enabled" (`docs/plans/2026-07-02-sync-engine-design.md:327`) — is unimplemented.

CKSyncEngine emits `accountChange(kind: .signIn)` shortly after `start()` reporting the current (same) account — capture-proven at ~35 ms (`docs/plans/FamilyFoqos-Logs-2026-07-13-122149.log`): `markSyncReadyAndFlush` `11:10:57.921` (`:73`) → `EVENT .accountChange kind=signIn` `11:10:57.956` (`:74`) → `state bootstrapping -> disabled caller=…handleAccountChange…`, `main=true`, same `tag=46335` (`:75`) → every later `Sync requested: state=disabled, driverNil=false` (`:79`–`:272`), healed only when the relaunch controller `tag=4aa6f` appears (`:299`–`:304`). Device A control (`…-121904.log`, `tag=376b9`) stays `steady`. Same `tag` ⇒ **H1 (stale `state` field)**. `requestSync` (`SyncEngineController+Cutover.swift:9-12`) reads `state` then **unconditionally** drives `driver?` — the only no-op is `driver == nil`, so `.disabled` + live driver = accidental sync. Because `.signIn` fires after *every* start, `disabled` became the most-common state.

---

## Design decisions (resolved in this plan)

### D-A — `requestSync` no-ops in non-operational OR mid-resolution states; never auto-recovers
`requestSync` drives the driver **only** when `state ∈ {.bootstrapping, .steady}` **and** no account resolution is in flight (`accountResolutionInFlight == false`). It never calls `start()` — recovery is driven exclusively by the account-change resolver (D-D/D-E). This honors the protocol warning: `.purged` is consent-scoped and is **never** auto-resumed (the resolver's same-user restart is restricted to `.disabled` — see D-E). The mid-resolution gate closes the cross-account send window (D-D). Treating `.disabled`/`.purged` uniformly as "off" for *not-syncing* is safe; the distinction that matters (whether to re-enable) lives in the resolver, which never re-enables `.purged`.

### D-B — `stop()` and purge tear the driver down (orphan ban)
Now that a real restart exists (`start()` rebuilds `driver`), `stop()` and the `.purged` branch call `driver?.shutdown()` then `driver = nil` **after** their best-effort final `sendChanges()`. So `state ∈ {.disabled, .purged} ⇒ no live driver` on every path — the testable form of decision #5.

### D-C — explicit driver teardown seam (`SyncEngineDriver.shutdown()`) + straggler guard
`CKSyncEngineDriver` holds the controller **weakly** (`:12 private weak var delegate`) and stores its `CKSyncEngine` **strongly** as a force-unwrapped IUO (`:11 private var engine: CKSyncEngine!`, `automaticallySync = false`, `:configuration`). Two consequences: (1) niling the controller's `driver` reference is not enough to guarantee the old `CKSyncEngine` releases, so add `func shutdown()` to the `SyncEngineDriver` protocol (real impl: change `engine` to optional and nil it; spy: bump a counter) called before every `driver = nil`; (2) the controller's ~20 non-optional `driver.…` derefs in event handlers would force-unwrap-crash if an event arrives after `driver = nil` — so add a straggler guard at the top of `handle(_:)`: `guard driver != nil else { return }`. With `automaticallySync = false` an orphaned engine performs no autonomous sync; `shutdown()` makes release deterministic and leak-free.

### D-D — decision moves to the facade; `.signIn` suppresses-but-doesn't-tear-down (no flap, no leak)
The `kind` alone cannot classify same-vs-different (`.signIn` is the same-account echo *and* a genuine new sign-in), and identity is async — so the synchronous handler must not decide. New `handleAccountChange(kind:)`:
- **`.signIn`** — log; call `beginAccountResolution()` (sets `accountResolutionInFlight`, which makes `requestSync` no-op) but **do not** tear down or bump the generation; invoke `onAccountChange(.signIn)`. The running engine is untouched (no flap) yet cannot leak a send to a possibly-new account while the async resolver runs. The resolver ends resolution (same-user/ambiguous) or tears down (different/noAccount).
- **`.signOut` / `.switchAccounts`** — log; tear down now via `prepareForAccountSwitch()`; invoke `onAccountChange(kind)`.

The facade owns `onAccountChange` (it already owns identity resolution and the `start()`/reconstruction levers).

### D-E — identity classification: three-way availability + fail-safe, disrupt only on confirmation (resolves escalation trigger #1)
`CloudKitManager.checkAccountStatus`/the network service currently flatten **every** non-`.available` status *and every thrown error* to `isSignedIn=false` (`CloudKitNetworkService+AccountAndZones.swift:16,34,37`) — so `.couldNotDetermine`/`.temporarilyUnavailable`/`.restricted`/errors are indistinguishable from a real sign-out. Since the resolver runs on essentially every launch (the `.signIn` echo), classifying any of those as "signed out" would tear down a healthy same-user engine on a transient glitch. Fix: add a **three-way** availability signal.

Resolver algorithm (only ever *disrupts* on a confirmed change; everything else leaves the engine alone + one bounded retry):
1. `let availability = await CloudKitManager.shared.accountAvailability()` → `enum AccountAvailability { case available(CKRecord.ID?); case noAccount; case ambiguous }` (maps the raw `CKAccountStatus`: `.available`→`available`, `.noAccount`→`noAccount`, everything else + thrown error →`ambiguous`).
2. `.noAccount` (**confirmed** sign-out) ⇒ pause.
3. `.ambiguous` ⇒ **do not tear down** — end resolution (engine keeps running if it was running), schedule one bounded retry.
4. `.available(id)` ⇒ `newName = await fetchUserRecordName()` (a *fresh* `CKContainer.userRecordID()` fetch, `ProfileSyncManager.swift:218-226`). Cached `currentUserRecordID` is **not** used to classify (`ensureUserRecordID` overwrites it unconditionally at `CloudKitManager.swift:49-54`, and the network layer returns the cached id when present at `CloudKitNetworkService+AccountAndZones.swift:43-45`, so it can be stale after a switch).
   - `newName == sentinel ("__default_user__")`, or the attached namespace key is the sentinel ⇒ **cannot confirm** ⇒ treat as ambiguous (end resolution + retry), never a dialog.
   - `newName == attachedUserRecordName` (both real) ⇒ **confirmed same user** ⇒ end resolution; restart **only if** `state == .disabled` (not `.purged` — consent-scoped), else the running engine resumes.
   - `newName != attachedUserRecordName` (both real, distinct) ⇒ **confirmed different user** ⇒ `prepareForAccountSwitch()` + `isSyncReady = false` (tear down now — closes the deferred-`.signIn` leak), then publish the three-choice conflict.

The load-bearing rule: **a teardown/pause or a destructive dialog happens only on a confirmed signal** (`noAccount`, or two confirmed distinct real names). Every transient/indeterminate/sentinel outcome keeps the engine running and retries once. This makes classification reliable on every path; no escalation required.

### D-F — the "Combine" union is the documented N11 union, forced-seeded so it fires for *any* target account (resolves escalation trigger #2)
Combine reconstructs the engine into the new user's namespace **without** wiping local data, and **forces a seed** so the union fires even for a previously-seen account. `applySeedDecision()` (`SyncEngineController.swift:918-926`) seeds only when `engineState == nil` *or* `pendingSeedIntent` is set; for a returning account `engineState[newName]` is non-nil (§7 "purges nothing"; nothing clears it on switch), so relying on `engineState == nil` would silently degrade Combine to fetch-only. Instead, set `store.pendingSeedIntent = true` for the new namespace **before** `start()` — this takes the I11 crash-recovery branch (`design:320` "`pendingSeedIntent` set ⇒ re-run I6 purge + I11 seed"), which runs the **I11** seed (`design:258`, `SyncEngineController.seedZoneAndRecords`/`restorableRecordNames` `:967-1005`): `saveZone` + save-all-restorable (profiles minus `isNewerSchemaVersion`, `SavedLocation`s, the emergency records) while `fetchChanges` pulls the new user's existing cloud records. Local SwiftData is account-agnostic; UUID keys make it collision-free (`design:497`). This *is* **N11** (`design:748`) — the contract's own accepted behavior — and touches **no** §8.1 machinery (verified against escalation trigger #3). Cross-device propagation is inherent; the dialog copy must say so.

### D-G — Switch is a full LOCAL wipe incl. UserDefaults emergency state
The I11 seed set includes UserDefaults-backed emergency records (`restorableRecordNames` appends `SyncedEmergencySettings.recordName` + `provider.restorableEmergencyRecordNames()`, `SyncEngineController.swift:1002-1004`; emergency state is `Codable` structs in `UserDefaults` via `EmergencyUnblockManager`, `SyncModels.swift:471,574`, `EmergencyUnblockManager.swift:35,44`). A SwiftData `ctx.delete` loop cannot remove them. So the Switch wipe must delete the SwiftData entities (`BlockedProfiles`, `SavedLocation`) **and** reset the emergency UserDefaults state via `EmergencyUnblockManager` — otherwise emergency budget/epoch/events survive and union up into the switched-to account, contradicting "adopt cloud". (On **Combine** they intentionally union up — the flagged passenger, Task 9.)

### D-H — `isEnabled` (consent) vs runtime pause; the invariant test's exact form
`isEnabled`/`SharedData.deviceSyncEnabled` stays persisted user consent (so same-user re-sign-in auto-resumes without re-consent). Runtime pause is a separate published `syncPausedReason`. The shipped facade-boundary invariant test asserts decision #5 in its always-true form:

> For the controller the facade routes to, `state ∈ {.disabled, .purged}` ⇒ `hasLiveDriver == false` (no `.disabled`/`.purged` controller with a live-but-orphaned driver), **and** after a *confirmed same-user* account-change with `isEnabled == true` and a previously `.disabled` engine, the routed controller returns to `.bootstrapping`/`.steady`.

*Flag for reviewer:* the literal "isEnabled always ⇒ operational" cannot hold during a legitimate confirmed-signed-out pause (consent preserved, runtime paused); the orphan-ban form forbids the dangerous configuration in that window too (driver nil). This is the one place the invariant's wording is interpreted rather than taken literally — confirm the reading.

---

## File structure

| File | Responsibility | Change |
|---|---|---|
| `Foqos/CloudKit/SyncEngine/SyncEngineController.swift` | state-log `didSet`; `handle(_:)` straggler guard; `handleAccountChange` reshape; `onAccountChange` hook; `beginAccountResolution`/`endAccountResolution`; `prepareForAccountSwitch`; driver-nil in `stop()`/purge; `hasLiveDriver`; `#if DEBUG forceStateForTest` | Modify |
| `Foqos/CloudKit/SyncEngine/SyncEngineController+Cutover.swift` | `requestSync` operational + resolution guard | Modify |
| `Foqos/CloudKit/SyncEngine/SyncEngineControlling.swift` | add `prepareForAccountSwitch()` + `beginAccountResolution()`/`endAccountResolution()` to the protocol (facade drives them through the weak seam) | Modify |
| `Foqos/CloudKit/SyncEngine/SyncEngineDriver.swift` | `shutdown()` protocol method | Modify |
| `Foqos/CloudKit/SyncEngine/CKSyncEngineDriver.swift` | `engine` → optional; `shutdown()` impl; nil-guard its own `engine` derefs | Modify |
| `Foqos/CloudKit/CloudKitManager.swift` + `CloudKitNetworkService+AccountAndZones.swift` | `accountAvailability()` three-way signal (surface raw `CKAccountStatus`) | Modify |
| `Foqos/Utils/EmergencyUnblockManager.swift` | `resetAllStateForAccountSwitch()` (clear UserDefaults emergency state) | Modify |
| `Foqos/CloudKit/ProfileSyncManager.swift` | retain attach context; wire `onAccountChange`; `reattachEngine(userRecordName:forceSeed:)`; `handleEngineAccountChange` + `resolveAccountChange`; three-choice API; `syncPausedReason`/`accountChangeConflict`/`pendingConflictName` seams | Modify |
| root-view alert modifier + Settings sync-section row | three-choice dialog bound to `accountChangeConflict`; Settings re-prompt when `syncPausedReason == .accountChanged` | Create/Modify |
| `FoqosTests/SyncEngineAccountChangeTests.swift` | controller reshape + guards + orphan-ban units | Create |
| `FoqosTests/ProfileSyncAccountResolverTests.swift` | resolver classification + three-choice + reattach units | Create |
| `FoqosTests/SyncEngineFacadeInvariantTests.swift` | the shipped facade-boundary invariant test | Create |

Follow existing patterns: `SyncEngineFacadeTests`/`SyncEngineAttachTests` reset `engineController` in setUp/tearDown; the driver is injected via `driverFactory`; a `SyncEngineDriver` spy already exists in the target (locate it in Task 0).

---

## Task 0: Citation refresh + baseline (do first)

**Files:** none — verification only.

- [ ] **Step 1: Re-locate every anchor** and record current lines:

```bash
cd <worktree>
grep -n "private(set) var state: SyncEngineState" Foqos/CloudKit/SyncEngine/SyncEngineController.swift   # ~:37
grep -n "var driver: SyncEngineDriver!"           Foqos/CloudKit/SyncEngine/SyncEngineController.swift   # ~:40
grep -n "func handle(_ event"                     Foqos/CloudKit/SyncEngine/SyncEngineController.swift   # ~:253
grep -n "func start()"                            Foqos/CloudKit/SyncEngine/SyncEngineController.swift   # ~:108 (guard permits .disabled/.purged, :109)
grep -n "func stop()"                             Foqos/CloudKit/SyncEngine/SyncEngineController.swift   # ~:204
grep -n "case .purged:"                           Foqos/CloudKit/SyncEngine/SyncEngineController.swift   # ~:299
grep -n "func handleAccountChange"                Foqos/CloudKit/SyncEngine/SyncEngineController.swift   # ~:321
grep -n "func applySeedDecision"                  Foqos/CloudKit/SyncEngine/SyncEngineController.swift   # ~:918
grep -n "func restorableRecordNames"              Foqos/CloudKit/SyncEngine/SyncEngineController.swift   # ~:998
grep -n "func requestSync"                        Foqos/CloudKit/SyncEngine/SyncEngineController+Cutover.swift  # ~:9
grep -n "protocol SyncEngineControlling"          Foqos/CloudKit/SyncEngine/SyncEngineControlling.swift # ~:6
grep -n "protocol SyncEngineDriver"               Foqos/CloudKit/SyncEngine/SyncEngineDriver.swift      # ~:18
grep -n "private var engine: CKSyncEngine!"       Foqos/CloudKit/SyncEngine/CKSyncEngineDriver.swift    # ~:11
grep -n "func attachEngine\|engineController = controller\|static func fetchUserRecordName" Foqos/CloudKit/ProfileSyncManager.swift  # ~:163/:197/:218
grep -n "func checkAccountStatus\|@Published var currentUserRecordID\|@Published var isSignedIn" Foqos/CloudKit/CloudKitManager.swift  # ~:37/:14/:15
grep -n "let status = try await container.accountStatus" Foqos/CloudKit/CloudKitNetworkService+AccountAndZones.swift  # ~:15
grep -n "class SavedLocation"                     Foqos/Models/SavedLocation.swift                      # ~:5
grep -n "private let defaults: UserDefaults\|struct SyncedEmergencySettings\|struct SyncedEmergencyEpoch" Foqos/Utils/EmergencyUnblockManager.swift Foqos/CloudKit/SyncModels.swift
```

- [ ] **Step 2: Locate the `SyncEngineDriver` test spy** (for `driverFactory` injection):

```bash
grep -rn "class .*: SyncEngineDriver" FoqosTests
```

- [ ] **Step 3: Confirm in-module reachability** (`@testable import FamilyFoqos`): `state` (`private(set) var` — readable), `driver` (`var` — read/write), `handle(_:)` (internal), `startupTask` (`private(set) var`). Note any `private` needing a minimal visibility bump.

- [ ] **Step 4: Enumerate the exact restorable seed set** (so the Switch wipe matches it): read `restorableRecordNames()` (`~:998-1005`) — `BlockedProfiles`, `SavedLocation`, `SyncedEmergencySettings.recordName`, `provider.restorableEmergencyRecordNames()` (epoch + unblock events). Record which are SwiftData (`BlockedProfiles`, `SavedLocation`) vs UserDefaults (emergency) — the wipe treats them differently (D-G).

- [ ] **Step 5: Boot the simulator once, baseline green:**

```bash
xcrun simctl list devices available | grep "iPhone 17"   # pick UUID
xcrun simctl boot <UUID>
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' \
  -only-testing:FoqosTests/SyncEngineFacadeTests -only-testing:FoqosTests/SyncEngineAttachTests | xcpretty
```
Expected: PASS. If red, stop and report.

- [ ] **Step 6:** Reconcile any drifted anchor into the tasks below. No commit.

---

## Task 1: Permanent state-transition log

**Files:** Modify `SyncEngineController.swift:~37`; Test `FoqosTests/SyncEngineAccountChangeTests.swift` (new).

**Interfaces:** Produces a `Log.debug` per transition; no API surface.

- [ ] **Step 1: Failing test** (behavioral proxy — the log is verified by inspection + the device run):

```swift
@MainActor
func testStopTransitionsToDisabled() throws {
  let (controller, _) = makeController()   // helper: builds controller with a spy driver; mirror SyncEngineFacadeTests
  controller.start()
  XCTAssertNotEqual(controller.state, .disabled)
  controller.stop()
  XCTAssertEqual(controller.state, .disabled)
}
```

- [ ] **Step 2: Run — FAIL** (`makeController` undefined); add the helper (mirror `SyncEngineFacadeTests` construction), re-run — the behavioral part PASSes.

- [ ] **Step 3: Add the `didSet` log:**

```swift
private(set) var state: SyncEngineState = .disabled {
  didSet {
    guard state != oldValue else { return }
    Log.debug("state \(oldValue) -> \(state) (main=\(Thread.isMainThread))", category: .sync)
  }
}
```
Lean, no call-stack, no PII (unlike the throwaway probe). `didSet` does not fire for the init default (acceptable — construction is `.disabled`).

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat(#307): permanent SyncEngineController state-transition log"`

---

## Task 2: `requestSync` operational + resolution guard (D-A, D-D)

**Files:** Modify `SyncEngineController+Cutover.swift:9-12`; add `accountResolutionInFlight` + `begin/endAccountResolution` + `hasLiveDriver` + `forceStateForTest` scaffolding on the controller; Test `SyncEngineAccountChangeTests.swift`.

**Interfaces:** Produces `requestSync()` drives the driver **iff** `state ∈ {.bootstrapping,.steady}` **and** `!accountResolutionInFlight`; `var accountResolutionInFlight: Bool`; `func beginAccountResolution()` / `func endAccountResolution()`; `var hasLiveDriver: Bool`.

- [ ] **Step 1: Failing tests:**

```swift
@MainActor
func testRequestSyncNoOpsWhenDisabledEvenWithLiveDriver() throws {
  let (controller, driver) = makeController()
  controller.start()                       // driver live, .bootstrapping
  controller.forceStateForTest(.disabled)
  driver.reset()
  controller.requestSync()                 // the #307 condition: .disabled + live driver
  XCTAssertEqual(driver.fetchChangesCallCount, 0)
  XCTAssertEqual(driver.sendChangesCallCount, 0)
}

@MainActor
func testRequestSyncNoOpsWhileResolvingAccountChange() throws {
  let (controller, driver) = makeController()
  controller.start(); controller.forceStateForTest(.steady)
  controller.beginAccountResolution()
  driver.reset()
  controller.requestSync()                 // suppressed during resolution
  XCTAssertEqual(driver.sendChangesCallCount, 0)
  controller.endAccountResolution()
  controller.requestSync()
  XCTAssertEqual(driver.sendChangesCallCount, 1)
}
```

- [ ] **Step 2: Run — FAIL** (symbols undefined; guard absent).

- [ ] **Step 3a: Add controller scaffolding** (near `state`):

```swift
private(set) var accountResolutionInFlight = false
func beginAccountResolution() { accountResolutionInFlight = true }
func endAccountResolution() { accountResolutionInFlight = false }
var hasLiveDriver: Bool { driver != nil }
#if DEBUG
func forceStateForTest(_ newValue: SyncEngineState) { state = newValue }
#endif
```

- [ ] **Step 3b: Add the guard** in `+Cutover.swift`:

```swift
func requestSync() {
  Log.debug("Sync requested: state=\(state), resetIntentActive=\(store.resetIntent != nil)", category: .sync)
  guard (state == .bootstrapping || state == .steady), !accountResolutionInFlight else {
    Log.debug("requestSync ignored: non-operational/resolving (state=\(state), resolving=\(accountResolutionInFlight))", category: .sync)
    return
  }
  driver?.fetchChanges()
  driver?.sendChanges()
}
```

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat(#307): requestSync no-ops in non-operational/resolving states"`

---

## Task 3: `stop()`/purge tear down the driver; `shutdown()` seam + straggler guard (D-B, D-C)

**Files:** Modify `SyncEngineDriver.swift` (protocol), `CKSyncEngineDriver.swift` (impl), the spy; `SyncEngineController.swift` (`handle` guard, `stop`, `.purged`); Test `SyncEngineAccountChangeTests.swift`.

**Interfaces:** Produces `SyncEngineDriver.shutdown()`; `handle(_:)` early-returns when `driver == nil`; post-condition `state ∈ {.disabled,.purged} ⇒ hasLiveDriver == false`.

- [ ] **Step 1: Failing tests:**

```swift
@MainActor
func testStopNilsDriverAndShutsItDown() throws {
  let (controller, driver) = makeController()
  controller.start()
  XCTAssertTrue(controller.hasLiveDriver)
  controller.stop()
  XCTAssertFalse(controller.hasLiveDriver)
  XCTAssertEqual(driver.shutdownCallCount, 1)
  XCTAssertGreaterThanOrEqual(driver.sendChangesCallCount, 1)  // best-effort final send before teardown
}

@MainActor
func testHandleIgnoresEventsAfterTeardown() throws {
  let (controller, _) = makeController()
  controller.start(); controller.stop()             // driver nil
  controller.handle(.didFetchChanges)               // must NOT crash (no force-unwrap on nil driver)
  XCTAssertFalse(controller.hasLiveDriver)
}
```

- [ ] **Step 2: Run — FAIL** (compile: `shutdown()` undefined; then crash without the guard).

- [ ] **Step 3a: Protocol** (`SyncEngineDriver.swift`): add `func shutdown()` with a doc-comment (quiesce/release the CKSyncEngine so a reconstructed engine doesn't race an orphaned old one, #307 D-C).

- [ ] **Step 3b: `CKSyncEngineDriver`** — make `engine` optional and nil it; nil-guard its own derefs:

```swift
private var engine: CKSyncEngine?         // was `CKSyncEngine!`
// … in init: self.engine = CKSyncEngine(configuration) (unchanged) …
func shutdown() { engine = nil }          // weak delegate already blocks stray delivery; automaticallySync=false ⇒ inert
// audit every `engine.` use in this file → `engine?.` (fetchChanges/sendChanges/add/remove/state accessors); post-shutdown they no-op, which is correct.
```
Add to the spy: `var shutdownCallCount = 0; func shutdown() { shutdownCallCount += 1 }`.

- [ ] **Step 3c: `handle(_:)` straggler guard** — first line of `handle`:

```swift
func handle(_ event: SyncEngineEvent) {
  guard driver != nil else { Log.debug("engine event ignored: driver torn down (\(event))", category: .sync); return }
  switch event { /* unchanged */ }
}
```
(Covers all ~20 non-optional `driver.…` derefs in the handlers — they only run below this guard.)

- [ ] **Step 3d: `stop()`** — shutdown+nil after the best-effort send, before `state = .disabled`:

```swift
func stop() {
  onStopReset?()
  store.resetIntent = nil
  store.pendingSeedIntent = false
  driver?.sendChanges()                     // best-effort final send (N5)
  namespaceGeneration += 1
  startupTask?.cancel(); flushTask?.cancel(); fetchCycleSweepTask?.cancel()
  store.engineState = nil
  driver?.shutdown(); driver = nil          // D-B/D-C
  state = .disabled
}
```

- [ ] **Step 3e: `.purged` branch** — same teardown after the notice:

```swift
case .purged:  // T6
  store.purgeAllSystemFields()
  store.transaction { s in s.engineState = nil; s.resetIntent = nil; s.pendingSeedIntent = false }
  SharedData.deviceSyncEnabled = false
  flushTask = Task { [weak self] in await self?.sessionSync.flushSessionCache() }
  NotificationCenter.default.post(name: .syncEnginePurged, object: nil)
  driver?.shutdown(); driver = nil
  state = .purged
```

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat(#307): stop()/purge tear down the driver; straggler-safe handle()"`

---

## Task 4: `handleAccountChange` reshape + hook + `prepareForAccountSwitch()` (D-D)

**Files:** Modify `SyncEngineController.swift:315-326` + `SyncEngineControlling.swift`; Test `SyncEngineAccountChangeTests.swift`.

**Interfaces:** Produces
- `var onAccountChange: (@MainActor (SyncEngineAccountChangeKind) -> Void)?`
- `func prepareForAccountSwitch()` — synchronous teardown (bump generation, cancel tasks, `driver.shutdown()`+nil, `endAccountResolution()`, `state = .disabled`).
- add `prepareForAccountSwitch()`, `beginAccountResolution()`, `endAccountResolution()` to the `SyncEngineControlling` protocol (so the weak facade seam can call them — see Task 6's `pauseSync`).
- `handleAccountChange`: `.signIn` suppresses (no teardown); `.signOut`/`.switchAccounts` tear down; all invoke the hook.

- [ ] **Step 1: Failing tests:**

```swift
@MainActor
func testSignInSuppressesButDoesNotTearDown() throws {
  let (controller, driver) = makeController()
  controller.start()
  var seen: SyncEngineAccountChangeKind?
  controller.onAccountChange = { seen = $0 }
  controller.handle(.accountChange(kind: .signIn))
  XCTAssertTrue(controller.hasLiveDriver)               // NOT torn down (no flap)
  XCTAssertTrue(controller.accountResolutionInFlight)   // sends suppressed until resolver ends it
  XCTAssertEqual(seen, .signIn)
}

@MainActor
func testSignOutTearsDownAndSignals() throws {
  let (controller, driver) = makeController()
  controller.start()
  var seen: SyncEngineAccountChangeKind?
  controller.onAccountChange = { seen = $0 }
  controller.handle(.accountChange(kind: .signOut))
  XCTAssertFalse(controller.hasLiveDriver)
  XCTAssertEqual(controller.state, .disabled)
  XCTAssertEqual(driver.shutdownCallCount, 1)
  XCTAssertEqual(seen, .signOut)
}
```

- [ ] **Step 2: Run — FAIL** (current code tears down on every kind; no hook).

- [ ] **Step 3: Rewrite + protocol additions:**

```swift
var onAccountChange: (@MainActor (SyncEngineAccountChangeKind) -> Void)?

/// Synchronous teardown for a CONFIRMED change (different user / sign-out). Purges nothing (§7).
func prepareForAccountSwitch() {
  namespaceGeneration += 1
  startupTask?.cancel(); flushTask?.cancel(); fetchCycleSweepTask?.cancel()
  driver?.shutdown(); driver = nil
  endAccountResolution()
  state = .disabled
}

/// The engine no longer decides here (#307 D-D). `.signIn` is ambiguous (same-account echo OR a real
/// new sign-in), so we SUPPRESS sends (no leak) but do NOT tear down (no flap) and let the facade
/// resolve identity async. `.signOut`/`.switchAccounts` are unambiguous: tear down now.
private func handleAccountChange(_ kind: SyncEngineAccountChangeKind) {
  switch kind {
  case .signIn:
    beginAccountResolution()
  case .signOut, .switchAccounts:
    prepareForAccountSwitch()
  }
  onAccountChange?(kind)
}
```
Add to `SyncEngineControlling`: `func prepareForAccountSwitch()`, `func beginAccountResolution()`, `func endAccountResolution()`; implement no-op-free versions on the spy (spy: track flags/counters).

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat(#307): defer account-change decision to the facade; suppress-not-flap on .signIn"`

---

## Task 5: `accountAvailability()` three-way signal + emergency reset (D-E, D-G)

**Files:** Modify `CloudKitNetworkService+AccountAndZones.swift`, `CloudKitManager.swift`, `EmergencyUnblockManager.swift`; Test `ProfileSyncAccountResolverTests.swift` (new).

**Interfaces:** Produces
- `enum AccountAvailability: Equatable { case available(CKRecord.ID?); case noAccount; case ambiguous }` (define at file scope, e.g. in `CloudKitManager.swift`).
- `CloudKitManager.accountAvailability() async -> AccountAvailability` (also refreshes `isSignedIn`/`currentUserRecordID` on `.available`/`.noAccount`; leaves them untouched on `.ambiguous`).
- `EmergencyUnblockManager.resetAllStateForAccountSwitch()` — clears the UserDefaults emergency counters/epoch/events.

- [ ] **Step 1: Failing tests** — network layer maps statuses (drive via a seam that injects the raw `CKAccountStatus`/error; if the network service isn't unit-injectable, test `AccountAvailability` mapping in isolation with a pure helper `AccountAvailability(from: CKAccountStatus, error: Error?)`):

```swift
func testAvailabilityMapping() {
  XCTAssertEqual(AccountAvailability(from: .available, recordID: rid, error: nil), .available(rid))
  XCTAssertEqual(AccountAvailability(from: .noAccount, recordID: nil, error: nil), .noAccount)
  XCTAssertEqual(AccountAvailability(from: .couldNotDetermine, recordID: nil, error: nil), .ambiguous)
  XCTAssertEqual(AccountAvailability(from: .temporarilyUnavailable, recordID: nil, error: nil), .ambiguous)
  XCTAssertEqual(AccountAvailability(from: .restricted, recordID: nil, error: nil), .ambiguous)
}
```

- [ ] **Step 2: Run — FAIL** (types/helper undefined).

- [ ] **Step 3a: Pure mapping helper** (`CloudKitManager.swift`):

```swift
enum AccountAvailability: Equatable { case available(CKRecord.ID?); case noAccount; case ambiguous
  init(from status: CKAccountStatus, recordID: CKRecord.ID?, error: Error?) {
    if error != nil { self = .ambiguous; return }
    switch status {
    case .available: self = .available(recordID)
    case .noAccount: self = .noAccount
    default: self = .ambiguous    // .couldNotDetermine / .temporarilyUnavailable / .restricted / future
    }
  }
}
```

- [ ] **Step 3b: `accountAvailability()`** — reuse the network path but return the raw status. Extend the network service to return `(status: CKAccountStatus, userRecordID: CKRecord.ID?, error: Error?)` (or add a sibling that does), then:

```swift
func accountAvailability() async -> AccountAvailability {
  let raw = await networkService.accountStatusDetailed()          // new: returns status+id+error, does not flatten
  let availability = AccountAvailability(from: raw.status, recordID: raw.userRecordID, error: raw.error)
  switch availability {                                            // keep published state coherent on confirmed signals
  case .available(let id): isSignedIn = true; if let id { currentUserRecordID = id }
  case .noAccount: isSignedIn = false; currentUserRecordID = nil
  case .ambiguous: break                                          // leave last-known state — do not act on a glitch
  }
  return availability
}
```
Leave the existing `checkAccountStatus()` intact for its other callers.

- [ ] **Step 3c: `EmergencyUnblockManager.resetAllStateForAccountSwitch()`** — set every emergency UserDefaults key back to its unset/default (counters, `resetPeriodInDays`, `lastResetDate`, epoch, and the stored unblock-events collection). Mirror the manager's existing setters; do not touch other defaults.

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat(#307): three-way account availability + emergency-state reset seam"`

---

## Task 6: Facade attach plumbing + resolver (D-D, D-E, D-F, D-H)

**Files:** Modify `ProfileSyncManager.swift`; Test `ProfileSyncAccountResolverTests.swift`.

**Interfaces:** Produces
- retained: `attachedUserRecordName`, `attachedModelContext`, `attachedEmergencyManager`, `attachedDriverFactory`; published `syncPausedReason: SyncPausedReason?`, `accountChangeConflict: AccountChangeConflict?`, `pendingConflictName: String?`.
- `func reattachEngine(userRecordName: String, forceSeed: Bool) async`
- `func handleEngineAccountChange(_ kind:)` (async entry) and `func resolveAccountChange(availability: AccountAvailability, newName: String?)` (pure classifier — inject both results so tests need no network).

- [ ] **Step 1: Failing tests** (pure classifier — pin identity, no network):

```swift
@MainActor func testConfirmedSameUserRestartsWhenDisabled() async throws {
  let mgr = makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .disabled)
  mgr.resolveAccountChange(availability: .available(recA), newName: "userA")
  XCTAssertNil(mgr.accountChangeConflict); XCTAssertNil(mgr.syncPausedReason)
  XCTAssertTrue(mgr.didCallStartForTest)                     // restart in place
}
@MainActor func testConfirmedSameUserPurgedDoesNotRestart() async throws {
  let mgr = makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .purged)
  mgr.resolveAccountChange(availability: .available(recA), newName: "userA")
  XCTAssertFalse(mgr.didCallStartForTest)                    // .purged is consent-scoped — never auto-resumed
}
@MainActor func testConfirmedNoAccountPauses() async throws {
  let mgr = makeAttachedManager(namespace: "userA", isEnabled: true)
  mgr.resolveAccountChange(availability: .noAccount, newName: nil)
  XCTAssertEqual(mgr.syncPausedReason, .signedOut); XCTAssertNil(mgr.accountChangeConflict)
}
@MainActor func testAmbiguousNeitherPausesNorPrompts() async throws {
  let mgr = makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
  mgr.resolveAccountChange(availability: .ambiguous, newName: nil)
  XCTAssertNil(mgr.syncPausedReason); XCTAssertNil(mgr.accountChangeConflict)  // engine left alone
  XCTAssertFalse(mgr.didTearDownForTest)
}
@MainActor func testSentinelTreatedAsAmbiguousNeverPrompts() async throws {
  let mgr = makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
  mgr.resolveAccountChange(availability: .available(nil), newName: "__default_user__")
  XCTAssertNil(mgr.accountChangeConflict); XCTAssertNil(mgr.syncPausedReason)
}
@MainActor func testConfirmedDifferentUserTearsDownAndPublishesConflict() async throws {
  let mgr = makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
  mgr.resolveAccountChange(availability: .available(recB), newName: "userB")
  XCTAssertEqual(mgr.accountChangeConflict?.newUserRecordName, "userB")
  XCTAssertEqual(mgr.syncPausedReason, .accountChanged)
  XCTAssertTrue(mgr.didTearDownForTest)                      // old driver released before the dialog (no leak)
  XCTAssertFalse(mgr.isSyncReady)
}
```

- [ ] **Step 2: Run — FAIL** (types/methods undefined).

- [ ] **Step 3a: Seams + retained context.** In `attachEngine`, after resolving `userRecordName`: set `attachedModelContext/attachedEmergencyManager/attachedDriverFactory/attachedUserRecordName`; after constructing `controller`, set `controller.onAccountChange = { [weak self] kind in self?.handleEngineAccountChange(kind) }`. Add:

```swift
enum SyncPausedReason: Equatable { case signedOut; case accountChanged }
struct AccountChangeConflict: Equatable { let newUserRecordName: String }
@Published private(set) var syncPausedReason: SyncPausedReason?
@Published private(set) var accountChangeConflict: AccountChangeConflict?
private var pendingConflictName: String?
```

- [ ] **Step 3b: Async entry + pure classifier:**

```swift
func handleEngineAccountChange(_ kind: SyncEngineAccountChangeKind) {
  Task { @MainActor [weak self] in
    guard let self else { return }
    let availability = await CloudKitManager.shared.accountAvailability()
    // Fetch the fresh namespace key only when the account is confirmed available.
    var newName: String?
    if case .available = availability { newName = await ProfileSyncManager.fetchUserRecordName() }
    self.resolveAccountChange(availability: availability, newName: newName)
  }
}

/// Pure, synchronous classifier. Disrupts ONLY on a confirmed change (D-E).
func resolveAccountChange(availability: AccountAvailability, newName: String?) {
  let sentinel = "__default_user__"
  switch availability {
  case .noAccount:
    pauseSync(reason: .signedOut)
  case .ambiguous:
    resumeAfterAmbiguity()
  case .available:
    guard let newName, newName != sentinel,
          let attached = attachedUserRecordName, attached != sentinel else {
      resumeAfterAmbiguity(); return                         // sentinel/unknown ⇒ never destructive
    }
    if newName == attached {
      clearPause()
      if let c = engineController as? SyncEngineController {
        if c.state == .disabled { startEngineAndMarkReadyWhenStartupCompletes() }  // NOT .purged (D-A)
        else { c.endAccountResolution() }                    // running engine: just resume sends
      }
    } else {
      (engineController as? SyncEngineController)?.prepareForAccountSwitch()  // tear down BEFORE dialog (no leak)
      isSyncReady = false
      pendingConflictName = newName
      accountChangeConflict = AccountChangeConflict(newUserRecordName: newName)
      syncPausedReason = .accountChanged
    }
  }
}

private func pauseSync(reason: SyncPausedReason) {
  isSyncReady = false
  (engineController as? SyncEngineController)?.prepareForAccountSwitch()
  syncPausedReason = reason
}
private func clearPause() { syncPausedReason = nil; accountChangeConflict = nil; pendingConflictName = nil }

/// Unconfirmed signal: leave the running engine untouched, resume its sends, retry once.
private func resumeAfterAmbiguity() {
  (engineController as? SyncEngineController)?.endAccountResolution()
  scheduleAccountResolutionRetry()
}
private var didRetryAccountResolution = false
private func scheduleAccountResolutionRetry() {
  guard !didRetryAccountResolution else { return }            // bounded: one retry
  didRetryAccountResolution = true
  Task { @MainActor [weak self] in
    try? await Task.sleep(nanoseconds: 5_000_000_000)         // 5s; a single re-check
    self?.handleEngineAccountChange(.signIn)                  // re-resolve; if still ambiguous, leaves engine running
  }
}
```
> Reset `didRetryAccountResolution = false` at the start of every fresh `.signOut`/`.switchAccounts` handling and on a confirmed resolution, so a later genuine change gets its own retry budget. Add `#if DEBUG` `didCallStartForTest`/`didTearDownForTest` counters for the tests. **`start()`'s own guard (`SyncEngineController.swift:109`) still admits `.purged`** — the resolver's `state == .disabled`-only gate is the load-bearing exclusion; do not loosen it.

- [ ] **Step 3c: `reattachEngine`** — factor a private `buildEngine(userRecordName:forceSeed:)` from `attachEngine`'s body (store/apply/provider/controller/hook + start). `reattachEngine` nils the **public** facade (clears the idempotency guard, `ProfileSyncManager.swift:173`) then rebuilds:

```swift
func reattachEngine(userRecordName: String, forceSeed: Bool) async {
  guard let modelContext = attachedModelContext, let emergencyManager = attachedEmergencyManager else { return }
  (engineController as? SyncEngineController)?.prepareForAccountSwitch()  // deterministic old-driver teardown
  ownedEngineController = nil
  engineController = nil                                     // public facade — required or attachEngine no-ops (:173)
  isSyncReady = false
  await buildEngine(userRecordName: userRecordName, modelContext: modelContext,
                    emergencyManager: emergencyManager, driverFactory: attachedDriverFactory, forceSeed: forceSeed)
}
```
In `buildEngine`, when `forceSeed`, set `store.pendingSeedIntent = true` **before** `controller.start()` so `applySeedDecision` runs the I11 purge+re-seed branch (D-F) even when `engineState[newName] != nil`. Note: `attachEngine`'s PreAttachDeleteBuffer replay (`:198-205`) re-runs on every build but `acknowledge` (`:203`) makes it idempotent.

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat(#307): account-change resolver + reattachEngine namespace switch"`

---

## Task 7: Different-user three-choice API + dialog + Settings re-prompt (decision #4, D-F, D-G)

**Files:** Modify `ProfileSyncManager.swift`; Create/Modify the root-view alert + Settings row; Test `ProfileSyncAccountResolverTests.swift`.

**Interfaces:** Produces
- `func resolveConflictSwitchToCloud() async` — LOCAL wipe (SwiftData `BlockedProfiles`+`SavedLocation` + `EmergencyUnblockManager.resetAllStateForAccountSwitch()`), then `reattachEngine(userRecordName:forceSeed:false)`.
- `func resolveConflictCombine() async` — `reattachEngine(userRecordName:forceSeed:true)` (N11 union, D-F), no wipe.
- `func resolveConflictNotNow()` — dismiss the dialog only; engine stays torn down; `syncPausedReason` stays `.accountChanged`; `pendingConflictName` retained for Settings re-prompt.

- [ ] **Step 1: Failing tests:**

```swift
@MainActor func testCombineReattachesWithForcedSeedWithoutWiping() async throws {
  let mgr = makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
  mgr.resolveAccountChange(availability: .available(recB), newName: "userB")
  seedLocalProfiles(count: 2, into: ctx)
  await mgr.resolveConflictCombine()
  XCTAssertEqual(mgr.attachedUserRecordName, "userB")
  XCTAssertEqual(try ctx.fetch(FetchDescriptor<BlockedProfiles>()).count, 2)   // local KEPT (unions up)
  XCTAssertTrue(mgr.lastReattachForceSeedForTest)                              // seed forced (union fires for any account)
  XCTAssertNil(mgr.accountChangeConflict)
}
@MainActor func testSwitchWipesLocalAndEmergencyThenReattaches() async throws {
  let mgr = makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
  mgr.resolveAccountChange(availability: .available(recB), newName: "userB")
  seedLocalProfiles(count: 2, into: ctx); setEmergencyBudget(spent: 3)
  await mgr.resolveConflictSwitchToCloud()
  XCTAssertEqual(mgr.attachedUserRecordName, "userB")
  XCTAssertEqual(try ctx.fetch(FetchDescriptor<BlockedProfiles>()).count, 0)   // SwiftData wiped
  XCTAssertEqual(try ctx.fetch(FetchDescriptor<SavedLocation>()).count, 0)
  XCTAssertEqual(emergencySpentBudget(), 0)                                    // UserDefaults emergency reset (D-G)
  XCTAssertNil(mgr.accountChangeConflict)
}
@MainActor func testNotNowLeavesEngineOffButRePromptable() throws {
  let mgr = makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
  mgr.resolveAccountChange(availability: .available(recB), newName: "userB")   // tore down, published conflict
  seedLocalProfiles(count: 2, into: ctx)
  mgr.resolveConflictNotNow()
  XCTAssertNil(mgr.accountChangeConflict)                                      // dialog dismissed
  XCTAssertEqual(mgr.syncPausedReason, .accountChanged)                        // still paused + re-promptable
  XCTAssertEqual(mgr.pendingConflictName, "userB")
  XCTAssertEqual(try ctx.fetch(FetchDescriptor<BlockedProfiles>()).count, 2)   // untouched
  XCTAssertEqual(mgr.attachedUserRecordName, "userA")                          // no switch
  XCTAssertFalse((mgr.engineController as? SyncEngineController)?.hasLiveDriver ?? true)  // engine stays off
}
```

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3a: The three methods:**

```swift
func resolveConflictSwitchToCloud() async {
  guard let conflict = accountChangeConflict else { return }
  wipeLocalSyncedDataDirectly()                     // LOCAL only — SwiftData + emergency UserDefaults
  await reattachEngine(userRecordName: conflict.newUserRecordName, forceSeed: false)
  clearPause()
}
func resolveConflictCombine() async {
  guard let conflict = accountChangeConflict else { return }
  await reattachEngine(userRecordName: conflict.newUserRecordName, forceSeed: true)  // N11 union
  clearPause()
}
func resolveConflictNotNow() { accountChangeConflict = nil }  // keep syncPausedReason + pendingConflictName
```

- [ ] **Step 3b: `wipeLocalSyncedDataDirectly()`** — direct delete (bypasses `MutationFunnel`; sync is funnel-driven — SwiftData CloudKit auto-sync is disabled, `cloudKitDatabase: .none` — so a raw delete never enqueues a server delete; the old driver is already torn down by the different-user resolver, but the funnel-bypass is what makes this LOCAL, not the driver's absence):

```swift
private func wipeLocalSyncedDataDirectly() {
  guard let ctx = attachedModelContext else { return }
  for p in (try? ctx.fetch(FetchDescriptor<BlockedProfiles>())) ?? [] { ctx.delete(p) }
  for l in (try? ctx.fetch(FetchDescriptor<SavedLocation>())) ?? [] { ctx.delete(l) }
  try? ctx.save()
  attachedEmergencyManager?.resetAllStateForAccountSwitch()   // emergency is UserDefaults, not SwiftData (D-G)
}
```
> Match this set to `restorableRecordNames()` (Task 0 Step 4): `BlockedProfiles` + `SavedLocation` (SwiftData) + emergency (UserDefaults). **Not** sessions (§6/N13).

- [ ] **Step 3c: The dialog** — `.alert`/`confirmationDialog` on the root view, presented when `accountChangeConflict != nil`, three buttons; copy makes Combine's cross-device propagation explicit (decision #4):
  - Title: "iCloud account changed"
  - Message: "Sync was turned off because this device signed into a different iCloud account."
  - **"Use this account's data"** (default) → `Task { await resolveConflictSwitchToCloud() }` — "Replaces this device's profiles with the ones already in the new account."
  - **"Combine my data"** → `Task { await resolveConflictCombine() }` — "Adds this device's profiles to the new account. They will appear on all devices signed into that account."
  - **"Not now"** → `resolveConflictNotNow()` — "Keeps sync off. You can decide later in Settings."

- [ ] **Step 3d: Settings re-prompt** — in the sync section, when `syncPausedReason == .accountChanged && pendingConflictName != nil`, show a row ("iCloud account changed — choose how to sync") that re-publishes `accountChangeConflict = AccountChangeConflict(newUserRecordName: pendingConflictName!)` to reopen the dialog. Use `@SafeQuery` for any SwiftData in the view.

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat(#307): switch/combine/not-now resolution + dialog + Settings re-prompt"`

---

## Task 8: Facade-boundary invariant test (decision #5, D-H)

**Files:** Test `FoqosTests/SyncEngineFacadeInvariantTests.swift` (new).

- [ ] **Step 1: Tests** — orphan ban across every non-operational path (with a positive state assertion so the `.purged` path cannot pass vacuously) + confirmed-same-user restart reaches operational:

```swift
private let syncZoneID = CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

@MainActor func testDisabledNeverHasLiveDriver_userDisable() throws {
  let (c, _) = makeController(); c.start(); c.stop()
  XCTAssertEqual(c.state, .disabled); XCTAssertFalse(c.hasLiveDriver)
}
@MainActor func testPurgedNeverHasLiveDriver() throws {
  let (c, _) = makeController(); c.start()
  c.handle(.fetchedDatabaseChanges(modifiedZoneIDs: [], deletedZones: [(zoneID: syncZoneID, reason: .purged)]))
  XCTAssertEqual(c.state, .purged)                 // positive: the branch actually fired (not vacuous)
  XCTAssertFalse(c.hasLiveDriver)
}
@MainActor func testSignOutPauseNeverHasLiveDriver() throws {
  let (c, _) = makeController(); c.start()
  c.handle(.accountChange(kind: .signOut))
  XCTAssertEqual(c.state, .disabled); XCTAssertFalse(c.hasLiveDriver)
}
@MainActor func testConfirmedDifferentUserLeavesNoLiveDriver() throws {
  let (c, _) = makeController(); c.start()
  c.prepareForAccountSwitch()                       // what the resolver's different-user branch calls
  XCTAssertEqual(c.state, .disabled); XCTAssertFalse(c.hasLiveDriver)
}
@MainActor func testConfirmedSameUserReturnsToOperational() async throws {
  let mgr = makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .disabled)
  mgr.resolveAccountChange(availability: .available(recA), newName: "userA")
  await (mgr.engineController as? SyncEngineController)?.startupTask?.value
  let c = mgr.engineController as! SyncEngineController
  XCTAssertTrue(c.state == .bootstrapping || c.state == .steady)
}
```
> Confirm the `.fetchedDatabaseChanges` label shape against `SyncEngineEvent.swift` in Task 0 (labels `modifiedZoneIDs:`/`deletedZones:`, tuple `(zoneID:,reason:)`); the `.purged` branch only fires `where deletedZoneID.zoneName == CloudKitConstants.syncZoneName` (`SyncEngineController.swift:292-293`) — that is why `syncZoneID` must use that exact zone name.

- [ ] **Step 2: Run — PASS.**
- [ ] **Step 3: Commit** — `git commit -m "test(#307): facade-boundary orphan-ban + operational invariants"`

---

## Task 9: Documented follow-ups (design notes — NO code) + full-suite green

**Files:** none (issue comments) + a final suite run.

- [ ] **Step 1: Terse notes on the relevant issues** (per user prefs — terse, plain product language, edit-in-place where a home issue exists) for the two account-swap passengers that ride the **Combine** path (NOT fixed here):
  - **Emergency-unblock budget (family-wide G-Set / union semantics):** Combine seeds this device's consumed-budget records into the new account and unions (grow-only) with the new family's budget — two families' spent budgets merge (no loss, but cross-family wrong). *Switch resets emergency state (D-G), so this is Combine-only.* Flag on the emergency-unblock G-Set issue. V2 family surface unreleased.
  - **Family-mode authority (child-managed profiles, lock codes):** lock codes sync via the shared-DB FamilyCommand channel, not the per-user private DB, so a locked child profile seeded (Combine) into a new namespace can arrive without its enforcing lock code; child/parent authority does not cleanly survive an account swap. Flag on the family-mode issue. V2 unreleased.
- [ ] **Step 2:** Confirm neither note implies code in this fix (both are V2-unreleased design follow-ups).
- [ ] **Step 3: Full `FoqosTests` suite** on the booted simulator — expect all green; capture the count.
- [ ] **Step 4: swift-format lint** touched files; fix violations.
- [ ] **Step 5: Commit** format-only changes — `git commit -m "chore(#307): swift-format"`

---

## Device verification (acceptance run — reuses the rev-2 capture protocol)

Same two-device protocol that diagnosed #307 (Section 2 of `docs/superpowers/plans/2026-07-12-307-state-divergence-diagnosis.md`), re-run on the **fix build** (Debug). The permanent state log (Task 1) replaces the probes. Acceptance bar: the steps that previously ended `state=disabled` now end `state=steady`. Device **A** stays signed in/untouched; Device **B** does the toggles and iCloud sign-out. Keep two simple profiles (no schedules); clear in-app logs; install the fix build on both.

| Step | Action (unchanged) | **Post-fix expected signature** |
|---|---|---|
| 1 | Manual "Sync Now" each | `Sync requested: state=steady …` both |
| 2 | B: airplane on; toggle sync off→on | `-> disabled` (stop, driver niled) then `-> bootstrapping`; requestSync during the hold logs `ignored: non-operational/resolving`, not accidental sync |
| 3 | B edits+Saves a profile offline; reconnect | Save's requestSync no-ops while non-operational; after reconnect `-> steady`, edit syncs |
| 4 | **B: iCloud sign out, then sign back in to the SAME account** | `.signOut` ⇒ `-> disabled` + `syncPausedReason=signedOut` surfaced; **`.signIn` ⇒ resolver confirms same user ⇒ `start()` ⇒ `-> bootstrapping -> steady`** (silent). **Acceptance delta: ends `steady`, NOT `disabled`.** A transient CloudKit status during this window ⇒ engine left running + one retry, never a spurious pause. |
| 5 | Foreground B twice | `Sync requested: state=steady …` — #307 symptom gone |
| 6 | Idle, foreground once; change on A, don't tap Sync on B | B stays `steady`; note whether A's change arrives unprompted (#335 rides along) |
| **7 (NEW)** | **B: sign into a DIFFERENT iCloud account** | engine torn down before any dialog (`hasLiveDriver=false`, no send to the new account pre-consent); **three-choice dialog** appears. Exercise each: **Combine** ⇒ B's profiles appear on the new account's other devices (verify on a third device / A re-signed to that account) — including when B had signed into that account before (forced seed); **Switch** ⇒ B shows only the new account's profiles, local ones + emergency budget gone; **Not now** ⇒ sync stays off, nothing changes, Settings offers the re-prompt |
| 8 | Export logs both | No `state=disabled` in any operational window; same-account run ends `steady` |

**Acceptance gate:** Steps 4–5 end `state=steady`; Step 7 classifies correctly and all three choices behave (Combine unions even for a returning account; Switch clears SwiftData **and** emergency budget; Not-now stays off + re-promptable); no `state=disabled`-with-sync-requested in any operational window. If any fail, the fix is incomplete — do not merge.

---

## Escalation check (all clear — none tripped)

- **Identity comparison unreliable on some path?** No — D-E: three-way availability + fresh name fetch; disrupt only on a confirmed signal (`noAccount`, or two confirmed distinct real names); every transient/indeterminate/sentinel outcome leaves the engine running + one bounded retry. The skeptic-found signed-out-flattening hole (`CloudKitNetworkService+AccountAndZones.swift:16,34,37`) is closed by the `accountAvailability()` seam (Task 5).
- **Union unsafe against the S0 contract?** No — D-F: Combine is the documented N11 union via the I11 seed, forced (`pendingSeedIntent`) so it fires for any target account, collision-free by UUID, and touches no §8.1 machinery.
- **Fix cannot avoid touching §8.1 reset?** No — same-user restart = `start()` resume; different-user = `reattachEngine`→T1 bootstrap (forced I11 seed) or local-wipe-then-bootstrap. None invoke `deleteZone`/`resetIntent`/the reset command.

Two design points flagged (not blockers): D-H (invariant's literal wording vs the orphan-ban form during a legitimate signed-out pause) and D-C (explicit driver teardown + straggler guard so a torn-down controller can't crash on a stray event).

---

## Self-review (writing-plans checklist)

- **Spec coverage:** decisions #1 (three-way identity check → D-E/Tasks 5-6), #2 (confirmed same-user silent restart, `.disabled`-only → Task 6), #3 (confirmed signed-out quiet+surfaced pause; #316 seam not built → `syncPausedReason`), #4 (different-user 3 choices, cross-device wording, LOCAL wipe incl. emergency not #310, forced-seed union verified → Task 7 + D-F/D-G), #5 (permanent state log + facade invariant test → Tasks 1, 8). Open questions: requestSync in .disabled/.purged (D-A/Task 2), stop() nils driver (D-B/Task 3). Passengers: G-Set budget + family authority (Task 9). Acceptance: rev-2 capture reused.
- **Skeptic findings folded:** signed-out fail-safe (D-E/Task 5), no-retry→bounded retry (Task 6), `SavedLocation` not `BlockedProfileLocation` + emergency-not-SwiftData (D-G/Task 7), Combine-only-first-seen→forced seed (D-F/Task 6), different-user-via-`.signIn` leak→tear-down-before-dialog + suppression gate (D-D/Task 6), IUO `driver` crash→`shutdown()` optional + `handle` guard (D-C/Task 3), protocol-typed `prepareForAccountSwitch`→added to `SyncEngineControlling` (Task 4), `.purged` restart contradiction→`.disabled`-only gate (D-A/Task 6), vacuous `.purged` test→`syncZoneID` + positive assertion (Task 8), citation/signature drift→corrected (`accountAvailability`, `resolveAccountChange(availability:newName:)`, `SavedLocation`, seed set).
- **Type consistency:** `hasLiveDriver`, `shutdown()`, `onAccountChange`, `beginAccountResolution`/`endAccountResolution`, `prepareForAccountSwitch()`, `reattachEngine(userRecordName:forceSeed:)`, `AccountAvailability`, `accountAvailability()`, `resolveAccountChange(availability:newName:)`, `SyncPausedReason`, `AccountChangeConflict`, `pendingConflictName`, `resolveConflict{SwitchToCloud,Combine,NotNow}`, `resetAllStateForAccountSwitch()` used consistently across tasks.
