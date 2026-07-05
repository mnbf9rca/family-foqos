# D2 — Remote Session Handling Implementation Plan (#203, #204, #237)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make cross-device / cross-process session handling *safe by construction* — a remote profile deletion tears down the local block and never leaves a zombie session (#203); a remote session start restores every local side-effect the normal start path performs (#204); and an in-app session mutator can never clobber a session the DeviceActivity extension owns (#237).

**Architecture:** Three independent defect surfaces, each fixed by reusing an existing seam rather than adding a parallel path:
1. **#203** — `SyncApplyService.deleteLocalProfile` (the §5.2 fetched-deletion apply path) deletes a profile without stopping the session it owns, leaving `ManagedSettings` shields applied and `StrategyManager.activeSession` pointing at a deleted `@Model` (zombie → `EXC_BREAKPOINT`). Fixed by calling the **already-present** `SessionController.stopRemoteSession` seam — the exact mechanism the sibling `ProfileSessionRecord`-deletion branch already uses — *before* deleting the profile.
2. **#204** — `StrategyManager.startRemoteSession` hand-rolls a subset of `activateSession`'s side-effects, so a device receiving a remote start gets no elapsed timer, no Live Activity, no local stop-schedule `DeviceActivity`, no widget reload, no heartbeat. Fixed by routing the remote-start path through `activateSession` (its CloudKit echo is already suppressed by `processingRemoteChange`).
3. **#237** — every in-app `SharedData` session mutator (`setEndTime`, `flushActiveSession`, `setBreakStartTime`, `setBreakEndTime`, `setOneMoreMinuteStartTime`, `clearOneMoreMinuteStartTime`) mutates `activeSharedSession` with **no identity check**, so stopping a stale in-app session wipes an extension-created scheduled session and loses its `endTime`. Fixed by threading an `expectedSessionId` into each mutator and no-op'ing on mismatch (inside the existing `withLock`).

**Tech Stack:** Swift 6, SwiftUI, SwiftData, CloudKit / `CKSyncEngine`, DeviceActivity / FamilyControls / ManagedSettings, XCTest. App target module is `FamilyFoqos`; cross-process shared state lives in the `FoqosShared` local Swift package (app-group `UserDefaults`).

---

## Plan provenance & Phase 0 re-triage (READ FIRST)

- **Planned against `main` @ `bd71958`** ("docs(#263/C1): DeviceActivity interval validation plan (#212, #228) (#272)"). All file:line citations below are from this commit.
- **These three issues predate PR #269** (2026-07-04), which replaced the entire CKQuery sync transport with `CKSyncEngine`. Their original file:line anchors (`SyncCoordinator.swift`, pre-package `SharedData.swift`) are **stale**. A mandatory Phase 0 re-triage (three deep code-grounding agents + manual cross-check against real code) re-established each defect against post-#269 `main`:

| Issue | Verdict | Why #269 did **not** close it | Current anchor |
|---|---|---|---|
| **#203** | **still-present** | #269 deleted deletion-by-absence reconciliation, but the *same* teardown gap is faithfully reproduced in the new explicit-deletion path. The `(#203)`-tagged line in the design contract (§5.2) is `stopSessionForDeletedRecord`, which fires **only** for `ProfileSessionRecord` deletions — the *profile*-deletion branch (`deleteLocalProfile`) has no session teardown. | `Foqos/CloudKit/SyncEngine/SyncApplyService.swift:104-125` |
| **#204** | **still-present** | `startRemoteSession`, `applySessionState`, `stopRemoteSession` all survived the rewrite unchanged; the hand-rolled subset of `activateSession` is still there. | `Foqos/Utils/StrategyManager.swift:1131-1177` |
| **#237** | **still-present** | S0's "SharedData clobber" fixes were elsewhere (`profileSnapshots` / `SyncEngineStore`). `git blame` dates the mutator bodies to 2026-02 and the flush call to 2025-08; the #124 package extraction only *moved* the file. The extension side is identity-gated; the **app side is entirely unguarded**. | `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift:415-465` + `Foqos/Models/BlockedProfileSessions.swift:67-95` |

- **None are obsolete; none are closed.** The re-triage verdict + evidence has been posted as a comment on each issue (#203/#204/#237). Do not re-open the classification — implement the surviving gap.

---

## Global Constraints

Copied verbatim from `AGENTS.md`; every task's requirements implicitly include these.

- **Never force-commit, amend, or force-push.** New commits only; use `git revert` to undo. The *plan* lives on branch `docs/263-d2-remote-session-plan`; **implementation goes on a NEW branch off `main`** named `fix/263-d2-remote-session`.
- **Request code review before merging.** Never merge unreviewed.
- **Worktrees:** this plan was authored in a read-only worktree (AGENTS.md permits worktrees for read-only sessions). **Implementation must NOT use a worktree** — use the `fix/263-d2-remote-session` feature branch in the main checkout.
- Views must use `@SafeQuery` (never raw `@Query`); non-query `PersistentModel` arrays filtered with `.valid`. *(No view queries are added or changed in this plan.)*
- Lock-code restriction checks must use `appModeManager.currentMode == .child`; the pattern `!= .parent` is forbidden. *(No lock/mode logic is added in D2 — MAINTAINER DECISION 2 keeps delete handling uniform; the lock guarantee is enforced by the local gate, tracked as the #194 prerequisite. If #194's fix touches this, it uses `== .child`.)*
- Use `Log.<level>(_, category:)` — never `print()`. Never log lock codes or personal identifiers. Session/sync logs use `category: .session`, `.sync`, `.strategy`, or `.timer` as appropriate.
- **swift-format** is enforced by a pre-commit hook (2-space indent, ~100–120 col). Run `swift-format --in-place --recursive .` before each commit; `swift-format lint --recursive .` must be clean.
- **Tests:** name `testGivenX_WhenY_ThenZ()`. Pin time — capture one `let now = Date()` per test and inject via `now:` parameters; never call `Date()` more than once per test where an assertion depends on it.

### Running tests (do this ONCE per session)

```bash
# 1. Find and boot the simulator ONCE (boot takes 3–5 min; tests take <3 s)
xcrun simctl list devices available | grep "iPhone 17"
xcrun simctl boot <UUID>          # e.g. B9E4A679-BDF3-4541-A59F-DA4BE21F80ED

# 2. Run a single test class by UUID (NEVER by device name — name clones a new sim each run)
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' \
  -only-testing:FoqosTests/<ClassName> | xcpretty

# 3. Full suite before the final commit
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty
```

Reuse the same booted UUID for every run in the session. Substitute the class name in `-only-testing:` per task.

---

## Binding contract compliance (the S0 design contract is normative)

The `CKSyncEngine` design contract — `docs/plans/2026-07-02-sync-engine-design.md` — is normative. **No D2 change may violate a contract invariant or bypass the `MutationFunnel` push funnel.** Each task below reuses an existing S0 seam:

- **#203** lives entirely inside the §5.2 fetched-deletion apply path. Stopping the session is driven by an **explicit fetched deletion event naming the profile** — this satisfies **I1** ("no inferred destruction"; deletion by explicit event, not absence). It reuses the injected `SessionController` seam and `stopRemoteSession`, which does **not** bump a version or enqueue a push — so **I2** (remote applies never bump/enqueue) holds and the funnel is not bypassed. `stopRemoteSession` internally suppresses its own session-stop CAS echo via `processingRemoteChange`.
- **#204** does not touch CloudKit at all. Routing through `activateSession` re-runs `syncSessionStart`, but that is `guard shouldSyncSessionChange`'d and `processingRemoteChange == true` throughout `startRemoteSession`, so **no** session record is pushed — **I2** holds, no echo loop.
- **#237** is pure cross-process `SharedData` (app-group `UserDefaults`); it never interacts with `CKSyncEngine`, the funnel, or §5.1/§5.2 routing. Do **not** route it through the funnel. The id-gate *strengthens* **I1** by refusing to destroy a shared session this incarnation never created.

**Cross-process rule (same as D1):** DeviceActivity / extension callback delivery is flaky (see the #260 verdict). Every handler this plan adds or reroutes is idempotent and safe under duplicate/dropped callbacks: `stopRemoteSession` is guard-gated and idempotent; the `expectedSessionId` no-op is safe to call any number of times.

---

## Coordination & sequencing (MANDATORY — read before implementing)

D2 shares surface area with other in-flight bundles. As of planning (`main` @ `bd71958`) **no** D1 plan PR is open yet.

- **D1 (background-stop policy) implements FIRST** and also touches `StrategyManager` and `SharedData` session semantics. If a D1 plan PR is raised before D2 implements, read it and reconcile: D1 must not have changed the `SharedData` mutator signatures or `activateSession`'s body in a way that conflicts with Tasks 1–2. If it did, adapt the exact edits below to the post-D1 code (the *approach* — id-gate the mutators, route remote start through `activateSession`, stop the session before deleting the profile — is unaffected).
- **Bundles F, I, and C2 also merge before D2 implements. C2 touches `StrategyManager`.** C2 (issue #214 / break-timer sub-15 + #260 break-end re-apply) may reshape the timer/`activateSession`/break paths.
- **PREREQUISITE (#194 ↔ Task 3):** per [MAINTAINER DECISION 2](#maintainer-decision-2--203-remote-delete-policy--settled-2026-07-05), the uniform-delete policy is safe *only* if the **local** delete-gate for locked profiles works. It currently does not — **[#194](https://github.com/mnbf9rca/family-foqos/issues/194)** lets a child delete a locked profile locally (and crash). **#194 must be fixed before or together with Task 3** (tracked on epic #263 as a D2 prerequisite). There is **no** child-mode special-case in `SyncApplyService` — delete handling is uniform.

Because of the above, **the first task of the implementing session is [Task 0](#task-0-refresh-citations--re-run-phase-0-spot-checks-against-post-c2-main) — refresh every file:line citation in this plan and re-run the Phase 0 spot-checks against then-current `main`.** Do not skip it; every line number below is from `bd71958` and *will* have drifted.

---

## File Structure

| File | Responsibility | Task |
|------|----------------|------|
| `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift` | Add `expectedSessionId: String` param + `withLock` identity guard to the six in-app session mutators. | 1 |
| `Foqos/Models/BlockedProfileSessions.swift` | `startBreak` / `startOneMoreMinute` / `endSession` pass `self.id` to the gated mutators. | 1 |
| `Packages/FoqosShared/Sources/FoqosShared/Timers/BreakTimerActivity.swift` | `start` / `stop` pass the in-hand `activeSession.id` (closes their read-then-write TOCTOU). | 1 |
| `Packages/FoqosShared/Sources/FoqosShared/Timers/OneMoreMinuteTimerActivity.swift` | `stop` passes `activeSession.id`. | 1 |
| `FoqosTests/OneMoreMinuteTests.swift` | Update two existing call sites for the new param; add an id-mismatch no-op test. | 1 |
| `FoqosTests/SharedDataSessionIdentityTests.swift` | **NEW.** The clobber regression: extension session survives an in-app stop of a different session. | 1A |
| `Foqos/Utils/StrategyManager.swift` (`toggleBlocking`) | Reconcile the on-screen session against `SharedData` before stopping; on mismatch reload + surface (MD3). | 1B |
| `FoqosTests/StrategyManagerReconcileTests.swift` | **NEW.** Stale-session Stop reloads + surfaces instead of ending the wrong session. | 1B |
| `Foqos/Utils/StrategyManager.swift` (`startRemoteSession`) | `startRemoteSession` routes through `activateSession` instead of setting `activeSession` directly. | 2 |
| `FoqosTests/StrategyManagerRemoteSessionTests.swift` | **NEW.** Remote start restores the timer + active session (the `activateSession` discriminator). | 2 |
| `Foqos/CloudKit/SyncEngine/SyncApplyService.swift` | `deleteLocalProfile` stops the owned session (via `stopRemoteSession`) before deleting the profile. | 3 |
| `FoqosTests/SyncApplyServiceTests.swift` | Add the remote-profile-deletion-with-active-session test (mirrors the existing session-record test). | 3 |

---

## MAINTAINER DECISIONS (✅ ALL SETTLED 2026-07-05)

All three decisions were ratified by the maintainer on 2026-07-05 (recorded on issues #203 and #237). Each task is written against the settled option; the alternatives are retained only as rationale/record. **The one remaining gate is a *prerequisite*, not an open decision: #194 must be fixed before/with Task 3 (see MD2).**

### MAINTAINER DECISION 1 — #203: stop-immediately vs run-to-natural-end (✅ SETTLED = A)

When a remote `SyncedProfile` deletion arrives for a profile that currently owns the active blocking session, the receiving device **stops the session immediately, then deletes** (MD1 = A, ratified).

- **(A) Stop the session immediately, then delete — ✅ SETTLED (Task 3 implements this).** Mirrors the existing `ProfileSessionRecord`-deletion branch (`stopSessionForDeletedRecord`) exactly, and is crash-safe (clears the zombie `@Model` and drops the shields before the profile is deleted). Consequence: a delete on device A instantly unblocks device B (the block vanishes with the profile). **Atomicity caveat (verified):** the stop is *not* part of the profile-delete transaction — `ManualBlockingStrategy.stopBlocking` calls `session.endSession()` + `context.save()` + `deactivateRestrictions()` *before* `deleteProfile`/`commit()` run. If the delete then throws, the catch's `modelContext.rollback()` leaves a self-healing husk (profile still present, its session already ended + persisted, shields already down, `activeSession` already nil in-memory, a `FailedApply` queued for §5.6 retry). This is acceptable (retry re-drives `deleteLocalProfile` idempotently) but is **not** all-or-nothing — do not describe it as atomic.
- **(B) Let the session run to its natural end, then delete.** *Rejected.* Would require deferring the local profile delete while a session is live, complicating I12 tombstone bookkeeping and §5.6 retry, and re-opening the zombie window.

### MAINTAINER DECISION 2 — #203: remote delete policy (✅ SETTLED 2026-07-05)

**= (A) Honor all remote deletes uniformly — no child-mode deferral, no origin-trust mechanism. The deferral option is DEAD.** Task 3 stops+deletes regardless of mode/lock.

*Maintainer rationale (app philosophy):* parents do **not** remotely manage child profiles — they lock profiles **physically on the child's device**. Every delete therefore originates on a device in the child's own account, where deletion of a locked profile must be **lock-code-gated locally**. If the local gate holds on every device, every propagated delete was authorized at its origin, so the wire needs no trust metadata. No per-mode special case in `SyncApplyService`.

> **⚠️ PREREQUISITE — #194 (Task 3 blocker).** The uniform-delete rationale *depends on the local delete-gate actually working*, and it currently does **not**: **[#194](https://github.com/mnbf9rca/family-foqos/issues/194)** — a child device can delete a locked profile via Manage → Edit/Move → Delete (and crash). **#194 must be fixed before or together with Task 3** (now tracked on epic #263 as a D2 prerequisite). Without it, a locked profile deleted locally propagates and unblocks other devices — the lock-bypass. This replaces the earlier "B1 merge gate" framing.

*Accepted residual (recorded, not fixed):* a fresh device on the child's account set up in **Individual** mode is not blocked by locked items (per the AGENTS.md mode table) and could delete a locked profile. Accepted per app philosophy — parental conversations, not DRM.

### MAINTAINER DECISION 3 — #237: behavior on identity mismatch (✅ SETTLED 2026-07-05, Design Q1)

**= (c) Reload and surface.** On identity mismatch the mutator write no-ops (the identity gate stays as the data-loss floor — Task 1 Part A), **and** the user Stop path refreshes state from `SharedData` and tells the user what is actually running now (or that the session already ended). Never act on a target the user didn't see (rules out silently stopping the *real* session); never fail silently (rules out a bare no-op). The user's next tap goes through the same identity gate against fresh state. **The mismatch itself is the reconciliation trigger — no dependence on any cross-process callback having fired.** Implemented as Task 1 **Part B** (reconcile-and-surface on `toggleBlocking`). *(Rejected: bare no-op — leaves stale UI + "nothing happened"; append-safe end of the foreign session — overreach.)*

---

## Task 0: Refresh citations & re-run Phase 0 spot-checks against post-C2 `main`

**This is a mandatory gate, not optional.** Every line number in Tasks 1–3 is from `bd71958`. Bundles D1, F, I, and C2 merge before D2 implements; C2 touches `StrategyManager`. Verify the ground has not shifted before writing any code.

- [ ] **Step 1: Branch off current `main`.**

```bash
git checkout main && git pull
git checkout -b fix/263-d2-remote-session
```

- [ ] **Step 2: Re-confirm each defect still exists** (they were confirmed at `bd71958`; C2/D1 may have altered them). For each, open the file and check the cited symbol still has the gap:
  - **#203:** `Foqos/CloudKit/SyncEngine/SyncApplyService.swift` → `deleteLocalProfile(recordName:)` still calls `BlockedProfiles.deleteProfile` with **no** `sessionController.stopRemoteSession` / active-session guard. If a prior bundle already added it, STOP — re-triage and report.
  - **#204:** `Foqos/Utils/StrategyManager.swift` → `startRemoteSession(...)` still sets `self.activeSession = <created session>` directly and does **not** call `activateSession(...)`. Confirm `activateSession(_:context:)` still exists with that signature and still calls `startTimer()`, `liveActivityManager.startSessionActivity`, `DeviceActivityCenterUtil.scheduleStopActivity`, `WidgetCenter…reloadTimelines`. Confirm `shouldSyncSessionChange == profileSyncManager.isEnabled && !processingRemoteChange` and that `syncSessionStart` is `guard shouldSyncSessionChange`'d.
  - **#237:** `Packages/FoqosShared/.../SharedData.swift` → the six mutators still take no `expectedSessionId`; `flushActiveSession` still does not append to `completedSessionsInScheduler`. Confirm `SessionSnapshot.id: String` and `BlockedProfileSession.id: String` are still the identity key.

- [ ] **Step 3: Refresh every `file:line` in Tasks 1–3** to the post-C2 line numbers. Use symbol search (function names), not raw line numbers — names are stable, lines are not. Task 1 has two parts (1A the identity gate; 1B the `toggleBlocking` reconcile); confirm `toggleBlocking`'s stop branch (`StrategyManager.swift:116-136`) still has the geofence-then-`stopBlocking` shape shown in Task 1 Part B.

- [ ] **Step 4: Confirm the #194 prerequisite status.** Task 3's uniform-delete policy depends on the local locked-profile delete-gate. Check whether **#194** ("can delete a profile while locked") is fixed on current `main`. If it is **not**, Task 3 must not merge until it is — either fix #194 in this bundle or coordinate its landing (tracked on epic #263). Record the status in the PR.

- [ ] **Step 5: Boot the simulator once and run the full suite green** to establish a clean baseline before changing anything (see Running tests). If it is not green on fresh `main`, STOP and report — do not build on a red baseline.

No commit for Task 0 (it is verification only). Proceed to Task 1.

---

## Task 1: #237 — SharedData session-identity gating + stale-session reconcile

**Two parts, committed separately.** **Part A** (Steps 1–9) is the data-loss floor: gate the six mutators by session identity so a stale in-app action can never clobber an extension-created session. **Part B** (Steps 10–13, MAINTAINER DECISION 3 = *reload and surface*) makes the user-facing Stop path reconcile against cross-process state and tell the user what is actually running — so the gate's no-op is never a silent "nothing happened."

### Part A — identity gate (data-loss floor)

**Files:**
- Modify: `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift:415-465` (six mutators)
- Modify: `Foqos/Models/BlockedProfileSessions.swift:67-95` (`startBreak`, `startOneMoreMinute`, `endSession`)
- Modify: `Packages/FoqosShared/Sources/FoqosShared/Timers/BreakTimerActivity.swift:43,72`
- Modify: `Packages/FoqosShared/Sources/FoqosShared/Timers/OneMoreMinuteTimerActivity.swift:55`
- Modify: `FoqosTests/OneMoreMinuteTests.swift:285,296`
- Create: `FoqosTests/SharedDataSessionIdentityTests.swift`

**Interfaces:**
- Produces (new signatures, consumed by callers in this task and by any future caller):
  - `SharedData.setEndTime(date: Date, expectedSessionId: String)`
  - `SharedData.flushActiveSession(expectedSessionId: String)`
  - `SharedData.setBreakStartTime(date: Date, expectedSessionId: String)`
  - `SharedData.setBreakEndTime(date: Date, expectedSessionId: String)`
  - `SharedData.setOneMoreMinuteStartTime(date: Date, expectedSessionId: String)`
  - `SharedData.clearOneMoreMinuteStartTime(expectedSessionId: String)`
  - Each is a no-op unless `activeSharedSession?.id == expectedSessionId`, evaluated inside the existing `withLock`.
- Consumes: `BlockedProfileSession.id: String` (the app session identity) and `SharedData.SessionSnapshot.id: String` (the shared identity) — the two are equal for an app-created session because `createSession` writes `newSession.toSnapshot()` whose `id == session.id`.

**Context / current offending code:** the six mutators (`SharedData.swift:415-465`) mutate `activeSharedSession` unconditionally, taking no identity. `flushActiveSession` (`:415`) sets `activeSharedSession = nil` **without** appending to `completedSessionsInScheduler` (contrast `endActiveSharedSession` at `:392`, which *does* append). `endSession` (`BlockedProfileSessions.swift:80`) calls `setEndTime` then `flushActiveSession` with no id. If the monitor extension replaced the shared session with a *different* profile's scheduled session (`createSessionForScheduler`, fresh UUID id), the in-app stop stamps + discards it → its `endTime` never reaches SwiftData. The extension side (`BreakTimerActivity`, `OneMoreMinuteTimerActivity`) already self-guards on `blockedProfileId`; **the app side is the unguarded clobber source.** Per MAINTAINER DECISION 3, the mutator itself no-ops on mismatch (this Part A) — and Part B adds the *reload-and-surface* on the Stop path so the no-op is observable to the user.

> **DRY note:** all three shared timers read `SharedData.getActiveSharedSession()` at the top of `start`/`stop` and already hold `activeSession`. Passing `activeSession.id` into the (now-gated) mutator both satisfies the new signature **and closes the read-then-write TOCTOU window** (if the shared session changed between the read and the write, the id no longer matches and the mutation no-ops).

- [ ] **Step 1: Write the failing regression test.** Create `FoqosTests/SharedDataSessionIdentityTests.swift`:

```swift
@preconcurrency import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SharedDataSessionIdentityTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!
  private var suiteName: String!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "SharedDataSessionIdentityTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    container = try TestModelContainer.create()
    context = container.mainContext
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  // #237: an in-app stop of session A must NOT clobber an extension-created session B.
  func testGivenExtensionSessionForOtherProfile_WhenInAppSessionEnds_ThenExtensionSessionUntouched()
    throws
  {
    let now = Date()
    let profileA = BlockedProfiles(name: "A")
    let profileB = BlockedProfiles(name: "B")
    context.insert(profileA)
    context.insert(profileB)
    // App session for A (its snapshot is NOT the shared active session — the extension replaced it).
    let sessionA = BlockedProfileSession(tag: "A", blockedProfile: profileA)
    context.insert(sessionA)
    try context.save()

    // Extension replaced the shared active session with B's scheduled session (fresh id).
    SharedData.createSessionForScheduler(for: profileB.id)
    let sharedBefore = SharedData.getActiveSharedSession()
    XCTAssertEqual(sharedBefore?.blockedProfileId, profileB.id)
    XCTAssertNotEqual(sharedBefore?.id, sessionA.id, "precondition: shared session is B, not A")

    // Act: user taps Stop on the still-displayed A.
    sessionA.endSession(now: now)

    // Assert: B's shared session is intact — not end-stamped, not flushed.
    let sharedAfter = SharedData.getActiveSharedSession()
    XCTAssertEqual(sharedAfter?.blockedProfileId, profileB.id, "B must survive the A stop (#237)")
    XCTAssertNil(sharedAfter?.endTime, "B must not be end-stamped by A's stop")
    // A's own SwiftData row still receives its endTime (the local mutation is unconditional).
    XCTAssertEqual(sessionA.endTime, now)
  }

  // The matching case still works: ending the session that owns the shared snapshot clears it.
  func testGivenOwnSharedSession_WhenInAppSessionEnds_ThenSharedSessionFlushed() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Own")
    context.insert(profile)
    let session = BlockedProfileSession(tag: "own", blockedProfile: profile)
    context.insert(session)
    try context.save()
    // App start wrote the shared snapshot with session.id.
    SharedData.createActiveSharedSession(for: session.toSnapshot())
    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, session.id)

    session.endSession(now: now)

    XCTAssertNil(SharedData.getActiveSharedSession(), "own shared session is flushed on stop")
    XCTAssertEqual(session.endTime, now)
  }
}
```

- [ ] **Step 2: Run to verify it fails.**

Run: `xcodebuild test … -only-testing:FoqosTests/SharedDataSessionIdentityTests`
Expected: `testGivenExtensionSessionForOtherProfile…` FAILS — on current code `endSession` calls the unguarded `setEndTime`+`flushActiveSession`, so B is end-stamped and flushed (`sharedAfter` is nil). (`testGivenOwnSharedSession…` passes on current code too.)

- [ ] **Step 3: Add the identity guard to the six SharedData mutators.** In `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift`, replace the six mutator bodies (`flushActiveSession` at `:415`; `setBreakStartTime`/`setBreakEndTime`/`setEndTime`/`setOneMoreMinuteStartTime`/`clearOneMoreMinuteStartTime` at `:432-465`):

```swift
  public static func flushActiveSession(expectedSessionId: String) {
    withLock {
      guard activeSharedSession?.id == expectedSessionId else { return }
      activeSharedSession = nil
    }
  }

  public static func setBreakStartTime(date: Date, expectedSessionId: String) {
    withLock {
      guard activeSharedSession?.id == expectedSessionId else { return }
      activeSharedSession?.breakStartTime = date
    }
  }

  public static func setBreakEndTime(date: Date, expectedSessionId: String) {
    withLock {
      guard activeSharedSession?.id == expectedSessionId else { return }
      activeSharedSession?.breakEndTime = date
    }
  }

  public static func setEndTime(date: Date, expectedSessionId: String) {
    withLock {
      guard activeSharedSession?.id == expectedSessionId else { return }
      activeSharedSession?.endTime = date
    }
  }

  public static func setOneMoreMinuteStartTime(date: Date, expectedSessionId: String) {
    withLock {
      guard var session = activeSharedSession, session.id == expectedSessionId else { return }
      session.oneMoreMinuteStartTime = date
      session.oneMoreMinuteUsed = true
      activeSharedSession = session
    }
  }

  public static func clearOneMoreMinuteStartTime(expectedSessionId: String) {
    withLock {
      guard var session = activeSharedSession, session.id == expectedSessionId else { return }
      session.oneMoreMinuteStartTime = nil
      activeSharedSession = session
    }
  }
```

- [ ] **Step 4: Update the app-side callers** in `Foqos/Models/BlockedProfileSessions.swift` to pass `self.id` (`startBreak` `:68`, `startOneMoreMinute` `:77`, `endSession` `:82` and `:94`):

```swift
  func startBreak(now: Date = Date()) {
    SharedData.setBreakStartTime(date: now, expectedSessionId: id)
    self.breakStartTime = now
  }

  func startOneMoreMinute(now: Date = Date()) {
    oneMoreMinuteUsed = true
    oneMoreMinuteStartTime = now

    // Sync to SharedData for background/foreground transitions
    SharedData.setOneMoreMinuteStartTime(date: now, expectedSessionId: id)
  }

  func endSession(now: Date = Date()) {
    // Set the end time in shared data in case its being saved
    SharedData.setEndTime(date: now, expectedSessionId: id)
    self.endTime = now

    // If this was a schedule-started session, record when it stopped.
    // The reader in ScheduleTimerActivity compares this against today's start time.
    // Schedule-started sessions have tag == profile UUID (set by createSessionForScheduler).
    let isScheduleStarted = (tag == blockedProfile.id.uuidString)
    if isScheduleStarted, modelContext != nil {
      blockedProfile.scheduleLastStoppedAt = now
      BlockedProfiles.updateSnapshot(for: blockedProfile)
    }

    SharedData.flushActiveSession(expectedSessionId: id)
  }
```

- [ ] **Step 5: Update the extension-side callers** to pass the in-hand `activeSession.id`. In `Packages/FoqosShared/Sources/FoqosShared/Timers/BreakTimerActivity.swift`, `start` (`:43`) and `stop` (`:72`):

> **Benign ordering note (leave a one-line comment):** in `stop`, `appBlocker.activateRestrictions(for:)` runs *before* the now-gated `setBreakEndTime`/`clearOneMoreMinuteStartTime`. If the shared session was swapped between the top-of-function `getActiveSharedSession()` read and the write, the write no-ops (correct — it is a foreign session) but restrictions were already re-applied. This is *strictly better* than today's clobber and the extension self-heals on its next callback; no reordering needed.

```swift
    // (start, line 43) — activeSession is already bound above and its profile verified
    SharedData.setBreakStartTime(date: now, expectedSessionId: activeSession.id)
```
```swift
    // (stop, line 72) — inside the `breakStartTime != nil && breakEndTime == nil` block
    SharedData.setBreakEndTime(date: now, expectedSessionId: activeSession.id)
```

In `Packages/FoqosShared/Sources/FoqosShared/Timers/OneMoreMinuteTimerActivity.swift`, `stop` (`:55`):

```swift
    // (stop, line 55) — inside the `oneMoreMinuteStartTime != nil` block; activeSession bound above
    SharedData.clearOneMoreMinuteStartTime(expectedSessionId: activeSession.id)
```

- [ ] **Step 6: Fix the two existing `OneMoreMinuteTests` call sites** so the suite compiles. In `FoqosTests/OneMoreMinuteTests.swift`, line `285` (the snapshot id in that test is `"test-session"`, set at `:269`) and line `296` (no active session — any id, the gate no-ops either way):

```swift
    // line 285
    SharedData.setOneMoreMinuteStartTime(date: oneMoreMinuteStart, expectedSessionId: "test-session")
```
```swift
    // line 296 (testGivenNoActiveSession…: still a no-op, still asserts nil)
    SharedData.setOneMoreMinuteStartTime(date: Date(), expectedSessionId: "any-id")
```

- [ ] **Step 7: Add an OMM id-mismatch no-op test** (covers the OMM mutator's gate directly). Append to `FoqosTests/OneMoreMinuteTests.swift` (inside the same `final class`):

```swift
  func testGivenDifferentActiveSession_WhenSettingOneMoreMinute_ThenNoOp() {
    let profileId = UUID()
    let stored = SharedData.SessionSnapshot(
      id: "stored-session",
      tag: "tag",
      blockedProfileId: profileId,
      startTime: Date(),
      forceStarted: false
    )
    SharedData.createActiveSharedSession(for: stored)

    // A DIFFERENT session tries to stamp one-more-minute.
    SharedData.setOneMoreMinuteStartTime(date: Date(), expectedSessionId: "other-session")

    let after = SharedData.getActiveSharedSession()
    XCTAssertEqual(after?.id, "stored-session", "stored session untouched")
    XCTAssertFalse(after?.oneMoreMinuteUsed ?? true, "mismatch is a no-op (#237)")
    XCTAssertNil(after?.oneMoreMinuteStartTime)
  }
```

> `SharedData.SessionSnapshot(id:tag:blockedProfileId:startTime:forceStarted:)` is the existing memberwise initializer used at `OneMoreMinuteTests.swift:268-274`.

- [ ] **Step 8: Run the affected suites to verify green.**

Run: `xcodebuild test … -only-testing:FoqosTests/SharedDataSessionIdentityTests -only-testing:FoqosTests/OneMoreMinuteTests`
Expected: PASS (all, including the new clobber regression). Also run `-only-testing:FoqosTests/SharedDataLockTests` to confirm no lock-path regression.

- [ ] **Step 9: swift-format + commit.**

```bash
swift-format --in-place --recursive .
swift-format lint --recursive .
git add Packages/FoqosShared/Sources/FoqosShared/SharedData.swift \
        Foqos/Models/BlockedProfileSessions.swift \
        Packages/FoqosShared/Sources/FoqosShared/Timers/BreakTimerActivity.swift \
        Packages/FoqosShared/Sources/FoqosShared/Timers/OneMoreMinuteTimerActivity.swift \
        FoqosTests/OneMoreMinuteTests.swift \
        FoqosTests/SharedDataSessionIdentityTests.swift
git commit -m "fix(#237): gate SharedData session mutators by session identity (Part A)

In-app session mutators (endSession/startBreak/startOneMoreMinute) wrote to
SharedData.activeSharedSession with no identity check, clobbering an
extension-created scheduled session and losing its endTime. Thread an
expectedSessionId through the six mutators and no-op on mismatch inside the
existing withLock; extension timers pass their in-hand activeSession.id,
closing their read-then-write TOCTOU. This is the data-loss floor; Part B adds
the user-facing reload-and-surface (MAINTAINER DECISION 3 = reload and surface)."
```

### Part B — reconcile-and-surface on Stop (MAINTAINER DECISION 3 = reload and surface)

Part A stops the *destruction*, but a bare no-op leaves the UI showing a session that isn't running and makes Stop look broken ("I tapped it and nothing happened"). Per MD3, the user Stop path must, on mismatch, **refresh from `SharedData` and surface what is actually active** (or that the session ended). The mismatch itself is the reconciliation trigger — it does not depend on any DeviceActivity/extension callback having fired.

**Files:**
- Modify: `Foqos/Utils/StrategyManager.swift:116-136` (`toggleBlocking` — the manual Stop entry point)
- Create: `FoqosTests/StrategyManagerReconcileTests.swift`

**Interfaces:**
- Consumes: `SharedData.getActiveSharedSession() -> SessionSnapshot?` (`SharedData.swift:388`); `loadActiveSession(context:)` (`StrategyManager.swift:88`, refreshes `activeSession` from SwiftData + imports SharedData snapshots via `syncScheduleSessions`); `@Published var errorMessage` (surfaced by `HomeView.swift:287` → `showErrorAlert`).
- Produces: no signature change. `toggleBlocking` gains a reconcile guard at the top of its stop branch.

**Context:** `toggleBlocking` (`StrategyManager.swift:116`) is the Stop/Start toggle the Home Stop button calls (`HomeView.swift:491`). Its `if isBlocking` branch currently goes straight to a geofence check + `stopBlocking`. The reconcile must run **before** either, so the geofence/stop logic never operates on a stale session. Scope: this Part covers the manual Stop path (the reported #237 scenario). Break / one-more-minute actions are protected by Part A's floor (silent no-op on a foreign session); extending reconcile to them is out of scope for D2.

- [ ] **Step 10: Write the failing test.** Create `FoqosTests/StrategyManagerReconcileTests.swift`:

```swift
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class StrategyManagerReconcileTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!
  private var manager: StrategyManager!
  private var suiteName: String!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "StrategyManagerReconcileTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    container = try TestModelContainer.create()
    context = container.mainContext
    manager = StrategyManager()
  }

  override func tearDown() async throws {
    manager.stopTimer()
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  // #237 / Design Q1: tapping Stop while the shared active session was swapped by the extension
  // must NOT end the stale on-screen session — it reloads and surfaces instead.
  func testGivenSharedSessionSwapped_WhenToggleStop_ThenStaleSessionNotEndedAndSurfaced() throws {
    let profileA = BlockedProfiles(name: "A")
    context.insert(profileA)
    let sessionA = BlockedProfileSession(tag: "A", blockedProfile: profileA)
    context.insert(sessionA)
    try context.save()
    manager.activeSession = sessionA  // stale on-screen session
    // Extension swapped the shared active session to a different one (fresh id != sessionA.id).
    SharedData.createSessionForScheduler(for: UUID())
    XCTAssertNotEqual(
      SharedData.getActiveSharedSession()?.id, sessionA.id, "precondition: shared session swapped")

    manager.toggleBlocking(context: context, activeProfile: profileA)

    XCTAssertNil(sessionA.endTime, "the stale session must NOT be ended (#237 / Q1)")
    XCTAssertNotNil(manager.errorMessage, "the state change is surfaced to the user")
  }

  // Control: when the shared session matches the on-screen session, Stop proceeds normally.
  func testGivenMatchingSharedSession_WhenToggleStop_ThenSessionEnds() throws {
    let profile = BlockedProfiles(name: "Focus")
    context.insert(profile)
    let session = BlockedProfileSession(tag: "manual", blockedProfile: profile)
    context.insert(session)
    try context.save()
    manager.activeSession = session
    SharedData.createActiveSharedSession(for: session.toSnapshot())  // shared id == session.id

    manager.toggleBlocking(context: context, activeProfile: profile)

    XCTAssertNotNil(session.endTime, "a matching-identity Stop ends the session")
  }
}
```

- [ ] **Step 11: Run to verify it fails.**

Run: `xcodebuild test … -only-testing:FoqosTests/StrategyManagerReconcileTests`
Expected: `testGivenSharedSessionSwapped…` FAILS — current `toggleBlocking` ends `sessionA` regardless (via `stopBlocking`), so `sessionA.endTime != nil` and `errorMessage == nil`. (`testGivenMatchingSharedSession…` passes on current code.)

- [ ] **Step 12: Add the reconcile guard.** In `Foqos/Utils/StrategyManager.swift`, at the **top of the `if isBlocking` branch** of `toggleBlocking` (before the geofence check):

```swift
  func toggleBlocking(context: ModelContext, activeProfile: BlockedProfiles?) {
    if isBlocking {
      // #237 / Design Q1 (MD3): reconcile against cross-process state before ending a possibly
      // stale on-screen session. If the DeviceActivity extension swapped the active session out
      // from under the UI, refresh from SharedData and surface what is actually running — never
      // end a session the user isn't looking at, never fail silently. The mismatch itself is the
      // trigger (no dependence on a callback). The user's next Stop acts on fresh state and passes
      // the Part-A identity gate.
      if let displayed = activeSession,
        SharedData.getActiveSharedSession()?.id != displayed.id
      {
        try? loadActiveSession(context: context)
        errorMessage =
          "This session was changed by a scheduled timer. The view has been refreshed — "
          + "tap Stop again if a session is still active."
        return
      }

      // Check geofence rule if one exists
      if let session = activeSession,
        let geofenceRule = session.blockedProfile.geofenceRule,
        geofenceRule.hasLocations
      {
        geofenceEvaluator.checkGeofenceAndStop(context: context, profile: session.blockedProfile) {
          self.stopBlocking(context: context, bypassStrategy: true)
        }
        return
      }

      stopBlocking(context: context, bypassStrategy: true)
    } else {
      geofenceEvaluator.checkGeofenceAndStart(context: context, activeProfile: activeProfile) {
        ctx, profile in
        self.startBlocking(context: ctx, activeProfile: profile, bypassStrategy: true)
      }
    }
  }
```

(Only the reconcile block at the top of the `if isBlocking` branch is new; the geofence + `stopBlocking` + `else` bodies are unchanged from `StrategyManager.swift:116-136`, reproduced here so the edit is unambiguous.)

- [ ] **Step 13: Run to verify green, then swift-format + commit.**

Run: `xcodebuild test … -only-testing:FoqosTests/StrategyManagerReconcileTests`
Expected: PASS (both).

```bash
swift-format --in-place --recursive .
swift-format lint --recursive .
git add Foqos/Utils/StrategyManager.swift FoqosTests/StrategyManagerReconcileTests.swift
git commit -m "fix(#237): reconcile-and-surface on stale-session Stop (Part B)

Part A's identity gate stops the data loss but a bare no-op leaves the UI showing
a session that isn't running and makes Stop look broken. Per MAINTAINER DECISION 3
(reload and surface), toggleBlocking now reconciles the on-screen session against
SharedData's active session before stopping: on mismatch it reloads state and
surfaces what is actually running (or that it ended) instead of ending a session
the user never saw. The mismatch is the reconciliation trigger — no dependence on
a cross-process callback. The user's next Stop acts on fresh state."
```

---

## Task 2: #204 — route `startRemoteSession` through `activateSession`

**Files:**
- Modify: `Foqos/Utils/StrategyManager.swift:1169` (`startRemoteSession`)
- Create: `FoqosTests/StrategyManagerRemoteSessionTests.swift`

**Interfaces:**
- Consumes: the existing private `activateSession(_ session: BlockedProfileSession, context: ModelContext? = nil)` (`StrategyManager.swift:585`), same class so callable from `startRemoteSession`.
- Consumes: `shouldSyncSessionChange` (`:56`) `== profileSyncManager.isEnabled && !processingRemoteChange`; `syncSessionStart` (`:492`) is `guard shouldSyncSessionChange`'d. `startRemoteSession` holds `processingRemoteChange = true` for its whole body (`:1138`, reset by `defer` at `:1140`), so `activateSession`'s `syncSessionStart` is suppressed — no CloudKit echo (I2).
- Produces: no signature change. `startRemoteSession(context:profileId:sessionId:startTime:)` is unchanged externally; only its body converges on `activateSession`.

**Context / current offending code (`StrategyManager.swift:1131-1177`):** `startRemoteSession` activates restrictions (`:1157`) and creates the session (`:1160`, with the synced `startTime`), then sets `self.activeSession = activeSession` directly (`:1169`) — skipping `startTimer()`, `liveActivityManager.startSessionActivity`, `DeviceActivityCenterUtil.scheduleStopActivity(for:)`, `WidgetCenter…reloadTimelines`, `HeartbeatManager.writeHeartbeat`, `timersUtil.cancelAll`, and snapshot refresh — all of which `activateSession` (`:585-621`) performs. Most serious: without `scheduleStopActivity`, the *local* `DeviceActivity` that enforces a scheduled stop is never registered on the receiving device, so a backgrounded device has no local enforcement if the CloudKit stop push is dropped. `activateSession` does **not** itself call `appBlocker.activateRestrictions` (the caller does), so keeping `:1157` and adding `activateSession` produces no double-activation.

- [ ] **Step 1: Write the failing test.** Create `FoqosTests/StrategyManagerRemoteSessionTests.swift`:

```swift
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class StrategyManagerRemoteSessionTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!
  private var manager: StrategyManager!
  private var suiteName: String!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "StrategyManagerRemoteSessionTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    container = try TestModelContainer.create()
    context = container.mainContext
    manager = StrategyManager()
  }

  override func tearDown() async throws {
    manager.stopTimer()
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  // #204: a remote start must converge on activateSession, not hand-roll a subset.
  // The timer task is the clean synchronous discriminator: startTimer() runs inside
  // activateSession and sets timerTask; the old direct-assign path never started it.
  //
  // COVERAGE BOUNDARY (be honest): timerTask is a PROXY for "activateSession ran". The other
  // side-effects #204 restores (Live Activity, scheduleStopActivity, widget reload, heartbeat)
  // route through non-injectable statics/singletons (DeviceActivityCenterUtil, WidgetCenter,
  // LiveActivityManager) and cannot be asserted without a DI refactor this plan does not do.
  // A wrong "fix" that appends startTimer() AFTER the direct-assign (instead of converging on
  // activateSession) would false-green this test. The reviewer MUST confirm by reading the diff
  // that startRemoteSession literally calls `activateSession(activeSession, context: context)`
  // and does not re-hand-roll the side-effects.
  func testGivenRemoteStart_WhenStartRemoteSession_ThenActiveSessionAndTimerStarted() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Focus")  // needsAppSelection defaults false
    context.insert(profile)
    try context.save()

    manager.startRemoteSession(
      context: context, profileId: profile.id, sessionId: UUID(), startTime: now)

    XCTAssertEqual(
      manager.activeSession?.blockedProfile.id, profile.id,
      "remote session becomes the active session")
    XCTAssertEqual(manager.activeSession?.startTime, now, "synced startTime preserved")
    XCTAssertNotNil(
      manager.timerTask,
      "activateSession's startTimer() must run on the remote-start path (#204)")
  }

  // Guard: a remote start for a profile needing app selection must NOT activate.
  func testGivenProfileNeedsAppSelection_WhenStartRemoteSession_ThenNoActivation() throws {
    let profile = BlockedProfiles(name: "NoApps")
    profile.needsAppSelection = true
    context.insert(profile)
    try context.save()

    manager.startRemoteSession(
      context: context, profileId: profile.id, sessionId: UUID(), startTime: Date())

    XCTAssertNil(manager.activeSession, "cannot start remotely without local app selection")
    XCTAssertNil(manager.timerTask)
  }
}
```

- [ ] **Step 2: Run to verify it fails.**

Run: `xcodebuild test … -only-testing:FoqosTests/StrategyManagerRemoteSessionTests`
Expected: `testGivenRemoteStart…` FAILS at `XCTAssertNotNil(manager.timerTask …)` — the current direct-assign path never calls `startTimer()`. (`testGivenProfileNeedsAppSelection…` passes on current code — it locks in the existing guard.)

- [ ] **Step 3: Route through `activateSession`.** In `Foqos/Utils/StrategyManager.swift`, inside `startRemoteSession`, replace the direct assignment (`:1168-1169`):

```swift
      // Set as active session
      self.activeSession = activeSession
```

with the convergence on the single source of truth (echo suppressed by `processingRemoteChange`, still `true` here):

```swift
      // Converge on the single activation path so the remote-started session gets the
      // elapsed timer, Live Activity, local stop-schedule DeviceActivity, widget reload,
      // and heartbeat — exactly like a local start. syncSessionStart is suppressed because
      // processingRemoteChange is true for this scope (shouldSyncSessionChange == false),
      // so no session record is echoed back to CloudKit (#204).
      activateSession(activeSession, context: context)
```

Leave the `appBlocker.activateRestrictions(for:)` (`:1157`) and `BlockedProfileSession.createSession(...)` (`:1160`) exactly as they are. `activateSession` sets `activeSession = session` itself (`:596`), so the removed line is fully subsumed. `activateSession` also calls `BlockedProfiles.updateSnapshot(for:)` (the *profile* snapshot — a distinct store from the *session* snapshot `createSession` already wrote), so there is no double-write of `activeSharedSession`. (Aside: the `sessionId:` parameter of `startRemoteSession` is already dead — `createSession` mints its own id — and this change does not alter that; do not add code that depends on it being the session identity.)

- [ ] **Step 4: Run to verify it passes.**

Run: `xcodebuild test … -only-testing:FoqosTests/StrategyManagerRemoteSessionTests`
Expected: PASS (both). Then run the sibling session suites to confirm the change did not break compilation or the guard/resolver behavior they *do* cover:
Run: `xcodebuild test … -only-testing:FoqosTests/StrategyManagerStartTests -only-testing:FoqosTests/StrategyManagerStopTests -only-testing:FoqosTests/StrategyManagerBackgroundTests`

> **Note (verified):** those three sibling suites exercise `StartStopActionResolver` and guard/early-return paths — **none of them drives `activateSession`'s success body.** This new `StrategyManagerRemoteSessionTests` is the *first* unit test to run `activateSession` end-to-end in the test host; it is safe for a schedule-less profile (`scheduleStopActivity` early-returns; `startSessionActivity`/`Activity.request` are `do/catch`-wrapped; `WidgetCenter` is a no-op). Do not treat the sibling suites as *gating* this change — they only confirm nothing adjacent regressed.

- [ ] **Step 5: swift-format + commit.**

```bash
swift-format --in-place --recursive .
swift-format lint --recursive .
git add Foqos/Utils/StrategyManager.swift FoqosTests/StrategyManagerRemoteSessionTests.swift
git commit -m "fix(#204): route startRemoteSession through activateSession

startRemoteSession hand-rolled a subset of activateSession, so a device
receiving a remote start had no elapsed timer, no local stop-schedule
DeviceActivity, no widget reload, no heartbeat (and no Live Activity when
foregrounded) — and, worst, no local enforcement of a scheduled stop if the
CloudKit stop push was dropped. Converge on activateSession (the documented
single source of truth). Its syncSessionStart is suppressed by
processingRemoteChange, so no session record echoes back to CloudKit (I2).
(Live Activities remain foreground-only per iOS; loadActiveSession re-registers
on the next foreground — unchanged.)"
```

---

## Task 3: #203 — stop the owned session before applying a remote profile deletion

> **⚠️ PREREQUISITE — fix #194 first (or in the same bundle).** Per MAINTAINER DECISION 2, delete handling is **uniform** (no per-mode special case): the safety of honoring every propagated delete rests on the **local** delete-gate stopping an unauthorized delete of a *locked* profile at its origin. That local gate is currently broken — **[#194](https://github.com/mnbf9rca/family-foqos/issues/194)** lets a child delete a locked profile locally (and crash). **Do not merge Task 3 until #194 is fixed** (before or together with this task; tracked on epic #263). Task 3 itself adds **no** mode/lock logic to `SyncApplyService`.

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/SyncApplyService.swift:104-125` (`deleteLocalProfile`)
- Modify: `FoqosTests/SyncApplyServiceTests.swift` (add one test; mirrors the existing session-record-deletion test)

**Interfaces:**
- Consumes: `sessionController: SessionController` (already an injected dependency of `SyncApplyService`, `:52-54`). Protocol (`Foqos/CloudKit/SessionController.swift:7-10`): `var activeSession: BlockedProfileSession? { get }`, `func stopRemoteSession(context: ModelContext, profileId: UUID)`.
- Consumes: `stopRemoteSession` (`StrategyManager.swift:1180`) → `manualStrategy.stopBlocking` (`ManualBlockingStrategy.swift:46`) → `appBlocker.deactivateRestrictions()` (shields down) + `onSessionCreation(.ended)` (`StrategyManager.swift:632-644`) → `activeSession = nil` + `stopTimer()` (zombie cleared). Its internal stop-CAS is echo-suppressed by `processingRemoteChange`.

**Context / current offending code (`SyncApplyService.swift:104-125`):** `deleteLocalProfile` calls `BlockedProfiles.deleteProfile(profile, in: modelContext)` (`:111`) then commits. `BlockedProfiles.deleteProfile` (`BlockedProfiles.swift:469-494`) ends+deletes the SwiftData sessions and removes schedule activities but **never** calls `appBlocker.deactivateRestrictions()` and never clears `StrategyManager.activeSession`. So when the deleted profile owns the active session: (1) `ManagedSettings` shields stay applied with no profile/session in the UI to stop them, and (2) `StrategyManager.activeSession` points at the deleted `@Model`, which the 1 s timer loop (`StrategyManager.swift:184-201`) dereferences on its next tick → `EXC_BREAKPOINT`. The sibling `ProfileSessionRecord`-deletion branch (`stopSessionForDeletedRecord`, `:149-162`) already does the right thing via `stopRemoteSession`; this task mirrors it on the profile-deletion branch. **Per MAINTAINER DECISION 1-A: stop immediately, then delete.**

- [ ] **Step 1: Write the failing test.** Append to `final class SyncApplyServiceTests` in `FoqosTests/SyncApplyServiceTests.swift` (mirrors `testGivenSessionDeletion_WhenLocalActive_ThenMirrorStopped` at `:445`; uses the existing `MockSessionController` and `makeService()`):

```swift
  // #203: a remote profile deletion for the ACTIVE profile must stop the session
  // (deactivating restrictions + clearing the manager) before deleting the profile.
  func testGivenActiveSessionProfile_WhenProfileDeletionApplied_ThenSessionStoppedThenDeleted()
    throws
  {
    let id = UUID()
    let profile = BlockedProfiles(id: id, name: "Focus", syncVersion: 1)
    context.insert(profile)
    // Insert + save the session so deleteProfile deletes a context-managed model (not a
    // context-less one — avoids a SwiftData edge that could false-red the test).
    let session = BlockedProfileSession(tag: "local", blockedProfile: profile)
    context.insert(session)
    try context.save()
    sessionController.activeSession = session

    let outcome = makeService().applyFetchedDeletion(
      recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID),
      recordType: SyncedProfile.recordType)

    XCTAssertEqual(outcome, .deleted)
    XCTAssertTrue(
      sessionController.stopRemoteSessionCalled,
      "the owned session must be stopped before the profile is deleted (#203)")
    XCTAssertEqual(sessionController.stopRemoteSessionProfileId, id)
    XCTAssertNil(
      try BlockedProfiles.findProfile(byID: id, in: context), "profile is still deleted")
  }

  // Negative: a remote profile deletion for a NON-active profile must not touch the session.
  func testGivenDeletionForNonActiveProfile_WhenApplied_ThenNoSessionStop() throws {
    let activeId = UUID()
    let deleteId = UUID()
    let activeProfile = BlockedProfiles(id: activeId, name: "Active", syncVersion: 1)
    let deleteProfile = BlockedProfiles(id: deleteId, name: "Delete", syncVersion: 1)
    context.insert(activeProfile)
    context.insert(deleteProfile)
    let activeSession = BlockedProfileSession(tag: "local", blockedProfile: activeProfile)
    context.insert(activeSession)
    try context.save()
    sessionController.activeSession = activeSession

    XCTAssertEqual(
      makeService().applyFetchedDeletion(
        recordID: CKRecord.ID(recordName: deleteId.uuidString, zoneID: zoneID),
        recordType: SyncedProfile.recordType),
      .deleted)
    XCTAssertFalse(
      sessionController.stopRemoteSessionCalled, "unrelated profile deletion never stops the session")
    XCTAssertNil(try BlockedProfiles.findProfile(byID: deleteId, in: context))
    XCTAssertNotNil(try BlockedProfiles.findProfile(byID: activeId, in: context))
  }
```

- [ ] **Step 2: Run to verify it fails.**

Run: `xcodebuild test … -only-testing:FoqosTests/SyncApplyServiceTests`
Expected: `testGivenActiveSessionProfile…` FAILS at `XCTAssertTrue(sessionController.stopRemoteSessionCalled …)` — current `deleteLocalProfile` never calls `stopRemoteSession`. (`testGivenDeletionForNonActiveProfile…` passes on current code.)

- [ ] **Step 3: Add the session-teardown guard.** In `Foqos/CloudKit/SyncEngine/SyncApplyService.swift`, `deleteLocalProfile`, insert the guard **before** `BlockedProfiles.deleteProfile` (`:111`):

```swift
  private func deleteLocalProfile(recordName: String) -> DeletionOutcome {
    guard let id = UUID(uuidString: recordName) else { return .ignored }
    do {
      guard let profile = try BlockedProfiles.findProfile(byID: id, in: modelContext) else {
        clearDeletionBookkeeping(recordName: recordName)  // intent already satisfied
        return .notPresent
      }
      // §5.2 / #203: if the profile being deleted owns the active session, stop it first —
      // this deactivates ManagedSettings restrictions and clears StrategyManager.activeSession
      // (via the manual-stop path) so deleteProfile does not strand shields or leave the
      // manager holding a deleted @Model. Mirrors stopSessionForDeletedRecord. Idempotent;
      // its stop-CAS echo is suppressed by processingRemoteChange (I2). MAINTAINER DECISION 1-A.
      if sessionController.activeSession?.blockedProfile.id == id {
        sessionController.stopRemoteSession(context: modelContext, profileId: id)
      }
      try BlockedProfiles.deleteProfile(profile, in: modelContext)  // defers save
      try commit()
      clearDeletionBookkeeping(recordName: recordName)
      return .deleted
    } catch {
      modelContext.rollback()
      store.addFailedApply(
        FailedApply(
          recordName: recordName, recordType: SyncedProfile.recordType, op: .delete))
      Log.error(
        "Failed to apply profile deletion \(recordName): \(error.localizedDescription)",
        category: .sync)
      return .ignored
    }
  }
```

- [ ] **Step 4: Run to verify it passes.**

Run: `xcodebuild test … -only-testing:FoqosTests/SyncApplyServiceTests`
Expected: PASS (all, including the two new tests and the existing S-1/S-22 deletion tests).

- [ ] **Step 4b: Cover the REAL teardown (the mock hides it).** `MockSessionController.stopRemoteSession` is a pure recorder — it does **not** clear `activeSession`, deactivate restrictions, or stop the timer. So Step 1's test proves only that the seam is *wired*, not that #203's actual symptoms (shields down, `activeSession` cleared, zombie timer stopped) are resolved. Add a test that drives the **real** `StrategyManager.stopRemoteSession` end-to-end. Append it to `FoqosTests/StrategyManagerRemoteSessionTests.swift` (created in Task 2):

```swift
  // #203 payload: the REAL stopRemoteSession must clear the manager's active session and stop
  // the timer — the teardown MockSessionController cannot exercise. (deactivateRestrictions is a
  // ManagedSettings no-op in the test host, but activeSession/timer clearing is fully asserted.)
  func testGivenRealActiveSession_WhenStopRemoteSession_ThenActiveSessionClearedAndTimerStopped()
    throws
  {
    let profile = BlockedProfiles(name: "Focus")
    context.insert(profile)
    let session = BlockedProfileSession(tag: "local", blockedProfile: profile)
    context.insert(session)
    try context.save()
    manager.activeSession = session
    manager.startTimer()
    XCTAssertNotNil(manager.timerTask, "precondition: timer running")

    manager.stopRemoteSession(context: context, profileId: profile.id)

    XCTAssertNil(manager.activeSession, "real stopRemoteSession clears the active session (#203)")
    XCTAssertNil(manager.timerTask, "real stopRemoteSession stops the timer (#203)")
    XCTAssertNotNil(session.endTime, "the session is ended")
  }
```

Run: `xcodebuild test … -only-testing:FoqosTests/StrategyManagerRemoteSessionTests`
Expected: PASS. This test passes on current code too (it exercises the already-correct `stopRemoteSession`, not the deletion path) — it is a **characterization lock** ensuring the teardown Task 3 depends on stays intact, not a red→green for the deletion wiring (that is Step 1's job). Together, Step 1 (deletion path calls the seam) + Step 4b (the seam really tears down) cover the full #203 chain.

- [ ] **Step 5: swift-format + commit.**

```bash
swift-format --in-place --recursive .
swift-format lint --recursive .
git add Foqos/CloudKit/SyncEngine/SyncApplyService.swift \
        FoqosTests/SyncApplyServiceTests.swift \
        FoqosTests/StrategyManagerRemoteSessionTests.swift
git commit -m "fix(#203): stop the owned session before applying a remote profile deletion

A fetched SyncedProfile deletion for the actively-blocking profile went straight
to BlockedProfiles.deleteProfile, which never deactivates ManagedSettings shields
nor clears StrategyManager.activeSession — leaving the device stuck-blocked with
no session to stop and a zombie @Model the 1s timer dereferences (EXC_BREAKPOINT).
Mirror the ProfileSessionRecord-deletion branch: stop the owned session via the
existing stopRemoteSession seam (deactivates restrictions, clears activeSession,
stops the timer) before deleting the profile. Stays inside §5.2 (I1); no funnel
bypass, no version bump (I2). MAINTAINER DECISION 1-A (stop immediately)."
```

---

## Final integration step (run after all tasks)

- [ ] **Full suite green.**

Run: `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty`
Expected: 0 failures. Confirm the new/edited suites are included (`SharedDataSessionIdentityTests`, `StrategyManagerReconcileTests`, `StrategyManagerRemoteSessionTests`, `SyncApplyServiceTests`, `OneMoreMinuteTests`).

- [ ] **swift-format lint clean:** `swift-format lint --recursive .` → no output.

- [ ] **#194 gate confirmed:** do not open Task 3 for merge unless #194 (local locked-profile delete-gate) is fixed on the merge base or in this bundle (MAINTAINER DECISION 2). State its status in the PR.

- [ ] **Request code review** (AGENTS.md requirement) before merging. The three MAINTAINER DECISIONS are settled (2026-07-05); restate the chosen options in the PR (MD1 = A stop-immediately; MD2 = A uniform delete, #194 prerequisite; MD3 = reload-and-surface) so the reviewer sees the ratified design.

---

## Self-review (spec coverage / placeholders / type consistency)

- **Coverage:** #203 → Task 3 (wiring in Step 1 + real teardown in Step 4b); #204 → Task 2; #237 → Task 1 Part A (identity gate) + Part B (reconcile-and-surface). Every re-triage "surviving gap" maps to a task. ✅
- **Placeholders:** none — every step has complete code and an exact `-only-testing:` command. ✅
- **Type consistency:** `expectedSessionId: String` matches `BlockedProfileSession.id: String` and `SessionSnapshot.id: String`; `stopRemoteSession(context:profileId:)` and `activeSession` match the `SessionController` protocol and `MockSessionController`; `activateSession(_:context:)` matches its `StrategyManager` definition; `applyFetchedDeletion(recordID:recordType:)`/`DeletionOutcome`/`makeService()`/`MockSessionController.stopRemoteSessionCalled` match the existing `SyncApplyServiceTests`. ✅

## Adversarial verification (ran on the draft; findings folded in)

Three adversaries attacked the draft (contract-invariant violations, cross-process races, stale-snapshot windows, false-green/false-red tests). **No blockers.** Folded-in fixes:
- **Cross-context (Task 3):** confirmed NON-issue — `SyncApplyService.modelContext == container.mainContext` (`FoqosApp.swift:252`), the same context `StrategyManager.shared.activeSession` lives on; the stop mutates/saves the right context. Also confirmed `processingRemoteChange` is set *only* inside `startRemoteSession`/`stopRemoteSession`, so `stopRemoteSession`'s own `guard !processingRemoteChange` **passes** (the stop actually runs, not a self-suppressed no-op) while still suppressing the stop-CAS echo (I2 holds).
- **Task 3 mock coverage gap → added Step 4b** (real-`StrategyManager` teardown test) and corrected the MD1-A "atomic" wording (the stop commits mid-transaction; husk self-heals via §5.6 retry).
- **Task 3 lock-bypass** surfaced to the maintainer → **settled 2026-07-05 as MD2 = A (uniform delete)**: locking is enforced *locally* at each origin, so no wire-level trust is needed; the lock-bypass is closed by fixing the **local** gate (**#194**, now a Task 3 prerequisite), not by mode logic in `SyncApplyService`. The earlier "B1 merge gate / child defer-guard" framing is superseded.
- **Task 3 uninserted-session false-red risk → tests now `context.insert(session)`** before the delete.
- **Task 2 false-green risk → documented** that `timerTask` is a proxy (reviewer must confirm the diff literally converges on `activateSession`); softened the "regression suites" claim (they do not drive `activateSession`); fixed the commit wording (Live Activity is foreground-only); noted the dead `sessionId` param.
- **Task 1:** confirmed no missed mutator caller, no double-flush, genuine red→green test; added the benign extension-ordering note (N1).

## Contract-compliance & residuals (honest)

- **No invariant violated, no funnel bypassed** — see "Binding contract compliance" above. Each task reuses an S0 seam (§5.2 deletion path + `SessionController`; `activateSession`; `SharedData.withLock`).
- **Idempotency:** all three added/rerouted handlers are safe under flaky/duplicate DeviceActivity/extension callbacks.
- **Residual (#237, MD3 = reload-and-surface):** on identity mismatch the mutator no-ops and the Stop path reloads + surfaces; the foreign shared session is left for the extension to finish (self-heals on its next `start`/`stop`). Bounded, non-destructive. Break / one-more-minute actions on a stale session are protected by Part A's silent no-op only (no reconcile-and-surface) — acceptable, out of D2 scope.
- **Residual (#203, MD1 = A):** a remote profile deletion instantly ends the local block (the fetched deletion is authoritative). Ratified 2026-07-05.
- **Residual (#203, MD2 = A uniform):** delete handling is uniform with no per-mode special case. Its safety **depends on #194** (local locked-profile delete-gate) being fixed — a hard Task 3 prerequisite. Accepted sub-residual: a fresh **Individual**-mode device on the child's account is not blocked by locked items and could delete a locked profile (per the AGENTS.md mode table) — accepted per app philosophy (parental conversations, not DRM).
