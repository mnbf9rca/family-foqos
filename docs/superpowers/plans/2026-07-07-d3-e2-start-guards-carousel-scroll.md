# D3+E2 — Local session-start guards & carousel scroll preservation Implementation Plan (#224, #225, #246)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close three surviving local-only defects that let the app create an "active" session it shouldn't:
- **#224** — no active-session guard on `startWithTag`/`startBlocking` (and a double-tap re-entrancy window in the geofenced start path) → a second session becomes a zombie, or a scheduler snapshot is silently overwritten and lost.
- **#225** — the three *local* start entry points (App Intents/Shortcuts, deep-link/NFC-QR link, pre-scanned tag) skip the `needsAppSelection` guard that `startRemoteSession` already has → a session shows "active" while blocking zero apps.
- **#246** — the carousel snaps back to the first card whenever the `profiles` array changes under the user (background sync, local create), and a never-cleared deep-link target keeps hijacking the reset.

**Architecture:** Every fix reuses an existing pattern already present elsewhere in the same file; no new subsystem, no CloudKit/sync-layer change.
1. **#224 + #225 (scan/manual paths)** — add ONE shared pre-flight validator on `StrategyManager` (`rejectionForStart(_:context:)`) that returns a user-facing message when a session is already active (**#224**) or the profile needs app selection (**#225**), and call it at the top of `startWithTag` and `startBlocking`. This mirrors the guard `startSessionFromBackground` *already* performs (`getActiveSession != nil` → `throw .sessionAlreadyActive`) and the `needsAppSelection` guard `startRemoteSession` *already* performs.
2. **#225 (intent/deep-link paths)** — `startSessionFromBackground` throws a new `IntentError.needsAppSelection`; `toggleSessionFromDeeplink` sets `errorMessage` and returns — each surfacing per its existing convention (throw vs `errorMessage`).
3. **#224 Case A (double-tap)** — gate `toggleBlocking`'s start branch on `!geofenceEvaluator.isCheckingGeofence` so a second tap during the ~1s async geofence check is ignored (the flag is already `@Published` and set synchronously before the async `Task`; today it is assigned but never read as a gate).
4. **#246** — guard `BlockedProfileCarousel`'s `.onChange(of: profiles)` to keep the current page when `currentProfileId` is still a member of `validProfiles`; and clear `HomeView`'s local `@State navigateToProfileId` after the carousel consumes it.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, DeviceActivity/FamilyControls/ManagedSettings, XCTest. App target module is `FamilyFoqos`; cross-process shared state lives in the `FoqosShared` local Swift package (app-group `UserDefaults`). No CloudKit / `CKSyncEngine` surface is touched.

---

## Plan provenance & Phase 0 re-triage (READ FIRST)

- **Planned against `main` @ `4307654`** ("Fix #285: defer profile delete commits past SwiftData invalidation (#289)"). All file:line citations below are from this commit.
- These five issues were filed by the **2026-07-02** defect audit. Their territory was rebuilt since: the entire CKQuery sync transport was replaced by `CKSyncEngine` (PR #269, `SyncCoordinator.swift` deleted), the StrategyManager start/stop paths were rewritten by bundles D1/D2/C2, and PR #289 rebuilt the list delete/reorder paths. A mandatory re-triage (2026-07-07: five deep code-grounding agents + five adversarial verifiers, all high-confidence, plus manual cross-check) re-established each defect against current `main`:

| Issue | Bundle | Verdict | Rationale (current anchor) |
|---|---|---|---|
| **#224** | D3 | **still-present** | `startWithTag` (`StrategyManager.swift:1258`) and `startBlocking` (`:1135`) create a session with no active-session guard; `toggleBlocking`'s geofenced start branch (`:151`) has no re-entrancy gate. |
| **#225** | D3 | **still-present** | `needsAppSelection` guard exists ONLY in `startRemoteSession` (`:1433`); the three local paths (`:565/572`, `:508`, `:1259`) skip it. D2 routed *remote* starts through the pre-existing check but never added it locally. |
| **#210** | E2 | **obsolete → CLOSE** | Fixed by the sync rebuild + PR #289: `deleteProfiles` now calls `enqueueProfileDelete` (`BlockedProfileListView.swift:188`) → `MutationFunnel` `.deleteRecord` (`MutationFunnel.swift:137`). **Not in this plan.** |
| **#233** | E2 | **obsolete → CLOSE** | Fixed by PR #289: `moveProfiles` (`:237`) and the delete gap-fix (`:211`) now `enqueueProfileSave` → `syncVersion += 1` + `.saveRecord` (`MutationFunnel.swift:62/70`). **Not in this plan.** |
| **#246** | E2 | **still-present** | `.onChange(of: profiles)` unconditionally calls `initialSetup()` (`BlockedProfileCarousel.swift:204`) which resets to `validProfiles.first` (`:123`); `HomeView`'s local `navigateToProfileId` is never cleared (`HomeView.swift:44/260`). |

- **#210 and #233 are obsolete.** A close-with-evidence recommendation has been posted on each; they are **out of scope** for this plan. The three survivors' re-triage verdict + evidence has been posted as a comment on #224/#225/#246. Do not re-open the classification — implement the surviving gap only.

---

## Global Constraints

Copied from `AGENTS.md`; every task's requirements implicitly include these.

- **Never force-commit, amend, or force-push.** New commits only; use `git revert` to undo. The *plan* lives on branch `docs/263-d3-e2-plan`; **implementation goes on a NEW branch off `main`** named `fix/263-d3-e2-start-guards`.
- **Request code review before merging.** Never merge unreviewed.
- **Worktrees:** this plan was authored in a read-only worktree (AGENTS.md permits worktrees for read-only sessions). **Implementation must NOT use a worktree** — one build/test stream per machine; use the feature branch in the main checkout.
- Views must use `@SafeQuery` (never raw `@Query`); non-query `PersistentModel` arrays filtered with `.valid`. *(#246 touches only `@State`/`onChange`, adds no query.)*
- Lock-code checks must use `appModeManager.currentMode == .child`; `!= .parent` is forbidden. *(No lock/mode logic is added in this plan.)*
- Use `Log.<level>(_, category:)` — never `print()`. Never log lock codes or personal identifiers. Start/guard logs use `category: .strategy`; UI logs `.ui`.
- **swift-format** is enforced by a pre-commit hook (2-space indent, ~100–120 col). Run `swift-format --in-place --recursive .` before each commit; `swift-format lint --recursive .` must be clean.
- **Tests:** name `testGivenX_WhenY_ThenZ()`. Pin time — capture one `let now = Date()` per test and inject via `now:`; never call `Date()` more than once where an assertion depends on it.

### Running tests (do this ONCE per session)

```bash
# 1. Boot the simulator ONCE (boot takes 3–5 min; tests take <3 s). Use the UUID, never the name.
xcrun simctl list devices available | grep "iPhone 17"
xcrun simctl boot <UUID>

# 2. Run a single test class by UUID
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' \
  -only-testing:FoqosTests/<ClassName> | xcpretty

# 3. Full suite before the final commit
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty
```

Reuse the same booted UUID for every run in the session.

---

## Binding contract compliance (no funnel / CKSyncEngine interaction)

The `CKSyncEngine` design contract (`docs/plans/2026-07-02-sync-engine-design.md`) is normative. **This plan does not touch it.** All three fixes live in the *local* session-start paths and the carousel view:

- **#224/#225** add pure pre-flight *rejections* before session creation — they only *prevent* a local start, never mutate a synced field, bump `syncVersion`, or enqueue a push. `getActiveSession` (used by the #224 guard) also runs `syncScheduleSessions`, which reconciles scheduler snapshots into SwiftData *before* the guard reads them — this is why routing #224 through `getActiveSession` (not a bare `activeSession != nil` in-memory check) is required: it closes the Case B lost-scheduled-session window as a side effect.
- **#246** is pure SwiftUI `@State`/`onChange`; no persistence, no sync.

**Cross-process rule:** the #224 guard must tolerate a scheduler-created session appearing between two calls — that is exactly why it fetches via `getActiveSession` rather than trusting the in-memory `activeSession`.

---

## File Structure

```
Foqos/Utils/StrategyManager.swift                 # Tasks 1-3: rejectionForStart helper + entry-point guards + re-entrancy gate
Foqos/Intents/IntentError.swift                   # Task 2: + case needsAppSelection(profileName:)
Foqos/Components/BlockedProfileCards/BlockedProfileCarousel.swift  # Task 4: onChange keep-page guard
Foqos/Views/HomeView.swift                        # Task 4: clear navigateToProfileId after consumption
FoqosTests/StrategyManagerStartTests.swift        # Tasks 1-3 tests (start guards, re-entrancy)
FoqosTests/StrategyManagerBackgroundTests.swift   # Task 2 test (intent-path needsAppSelection)
FoqosTests/BlockedProfileCarouselTests.swift      # Task 4 tests (NEW file if absent)
```

---

### Task 0: Citation refresh (MANDATORY FIRST STEP — no code yet)

Code drifts between planning and implementation. Before writing anything, re-verify every anchor this plan cites against the *current* `HEAD`, and update the line numbers in your working notes if they moved:

- [ ] `StrategyManager.startWithTag` — confirm it still calls `activateRestrictions` + `createSession` with no active-session/`needsAppSelection` guard (planned `:1258-1266`).
- [ ] `StrategyManager.startBlocking` — confirm no guard beyond `activeProfile != nil` (planned `:1135-1167`).
- [ ] `StrategyManager.startSessionFromBackground` — confirm the `getActiveSession` guard exists (`throw .sessionAlreadyActive`, planned `:535`) but there is NO `needsAppSelection` check (planned `:565`/`:572`).
- [ ] `StrategyManager.toggleSessionFromDeeplink` — confirm both start sites (switching `:495`, no-active `:508`) have no `needsAppSelection` check.
- [ ] `StrategyManager.startRemoteSession` — confirm the reference `needsAppSelection` guard (planned `:1433`) — copy its message style.
- [ ] `toggleBlocking` start branch (planned `:151`) + `GeofenceEvaluator.isCheckingGeofence` (`GeofenceEvaluator.swift:21`, set at `:157`) — confirm the flag is set synchronously before the async `Task` and is currently never read as a gate.
- [ ] `BlockedProfileCarousel` `.onChange(of: profiles)` (planned `:204`), `initialSetup()` fall-through (planned `:123`); `HomeView` `navigateToProfileId` (planned `:44`, set `:260`, fed `:191`, `clearNavigation()` `:261`).
- [ ] `IntentError` cases (`Foqos/Intents/IntentError.swift`) — confirm no `needsAppSelection` case yet.

If any anchor has moved or a fix already partially landed, STOP and reconcile before proceeding.

---

### Task 1: Shared pre-flight validator for the scan/manual start paths (#224 + #225)

**Red — write failing tests first** in `FoqosTests/StrategyManagerStartTests.swift` (harness pattern: `SharedData.configure(suite:)`, `TestModelContainer.create()`, `manager = StrategyManager()` — mirror `StrategyManagerRemoteSessionTests`). Prefer driving the public scan entry points `startWithNFCTag`/`startWithQRCode` (which funnel to `startWithTag`) so the tests exercise real call sites:

- [ ] `testGivenActiveSession_WhenStartWithNFCTag_ThenNoSecondSessionAndErrorSurfaced()` — seed an active session; call `startWithNFCTag`; assert exactly one `endTime == nil` row remains in `context` and `manager.errorMessage != nil`.
- [ ] `testGivenProfileNeedsAppSelection_WhenStartWithQRCode_ThenNoSessionAndErrorSurfaced()` — profile with `needsAppSelection = true`, no active session; assert `manager.activeSession == nil`, no session row created, `errorMessage != nil` (mirror `testGivenProfileNeedsAppSelection_WhenStartRemoteSession_ThenNoActivation`).
- [ ] `testGivenNoActiveSessionAndAppsSelected_WhenStartWithNFCTag_ThenSessionStarts()` — regression: a clean start still succeeds (`activeSession != nil`, `timerTask != nil`).

**Green — implement:**
- [ ] Add a private helper on `StrategyManager`:
  ```swift
  /// Pre-flight shared by the local start entry points. Returns a user-facing rejection
  /// message, or nil if the start may proceed. Fetching via getActiveSession also runs
  /// syncScheduleSessions first, so a scheduler snapshot is reconciled (not overwritten). 
  private func rejectionForStart(_ profile: BlockedProfiles, context: ModelContext) -> String? {
    if (try? getActiveSession(context: context)) != nil {           // #224
      return "A session is already active. Stop it before starting another."
    }
    if profile.needsAppSelection {                                  // #225
      return "Profile '\(profile.name)' needs app selection on this device before it can start."
    }
    return nil
  }
  ```
- [ ] At the top of `startWithTag(context:profile:tag:)`:
  ```swift
  if let rejection = rejectionForStart(profile, context: context) {
    errorMessage = rejection
    Log.info("Refusing tag start: \(rejection)", category: .strategy)
    return
  }
  ```
- [ ] At the top of `startBlocking(context:activeProfile:bypassStrategy:)`, after the `guard let definedProfile` unwrap, apply the same rejection using `definedProfile`.

**Verify:** the three Task-1 tests pass; full `StrategyManagerStartTests` + `ConcurrentSessionTests` stay green.

---

### Task 2: `needsAppSelection` guard on the intent & deep-link paths (#225)

**Red — write failing tests first:**
- [ ] In `StrategyManagerBackgroundTests.swift`: `testGivenProfileNeedsAppSelection_WhenStartSessionFromBackground_ThenThrowsAndNoSession()` — assert it throws `IntentError.needsAppSelection` and creates no session.
- [ ] In `StrategyManagerStartTests.swift`: `testGivenProfileNeedsAppSelection_WhenToggleSessionFromDeeplink_ThenNoSessionAndErrorSurfaced()` — async; assert no session + `errorMessage != nil`.

**Green — implement:**
- [ ] `Foqos/Intents/IntentError.swift`: add `case needsAppSelection(profileName: String)` and its `CustomLocalizedStringResourceConvertible` message (mirror `backgroundStopsDisabled(profileName:)`).
- [ ] `startSessionFromBackground`: after `findProfile`, before either strategy start, add
  `if profile.needsAppSelection { errorMessage = "..."; throw IntentError.needsAppSelection(profileName: profile.name) }` (place it alongside the existing `sessionAlreadyActive` guard).
- [ ] `toggleSessionFromDeeplink`: in the no-active-session start branch (and the `isSwitching` start), before `manualStrategy.startBlocking`, add
  `guard !profile.needsAppSelection else { self.errorMessage = "..."; return }`.

**Verify:** both new tests pass; `StrategyManagerBackgroundTests` + remote-session tests stay green.

---

### Task 3: Close the #224 Case A double-tap re-entrancy window

**Red — write a failing test first** in `StrategyManagerStartTests.swift`:
- [ ] `testGivenGeofenceCheckInFlight_WhenToggleBlockingCalledAgain_ThenSecondCallIsIgnored()` — inject a `GeofenceEvaluator` (or a test seam) with `isCheckingGeofence == true`; call `toggleBlocking` on a non-blocking manager; assert no start is initiated (no second `checkGeofenceAndStart`/session). If `GeofenceEvaluator` cannot be cheaply faked, extract the gate decision into a pure helper `func shouldIgnoreStartTap(isChecking:isBlocking:) -> Bool` and unit-test that.

**Green — implement:**
- [ ] In `toggleBlocking`, guard the `else` (start) branch:
  ```swift
  } else {
    guard !geofenceEvaluator.isCheckingGeofence else {
      Log.info("Start tap ignored: geofence check already in flight", category: .strategy)
      return
    }
    geofenceEvaluator.checkGeofenceAndStart(...) { ctx, profile in
      self.startBlocking(context: ctx, activeProfile: profile, bypassStrategy: true)
    }
  }
  ```
  (The Task-1 `getActiveSession` guard inside `startBlocking` is the belt-and-suspenders backstop; this gate closes the window before the async check even resolves.)

**Verify:** the Case A test passes; no regression in `toggleBlocking` stop-path tests (`StrategyManagerReconcileTests`, `StrategyManagerStopTests`).

---

### Task 4: Preserve carousel scroll position (#246)

**Red — write failing tests first** (`FoqosTests/BlockedProfileCarouselTests.swift`, new if absent). Test the *decision logic*, extracted to be pure and testable:
- [ ] `testGivenCurrentPageStillPresent_WhenProfilesChange_ThenCurrentPageKept()` — current id still in `validProfiles` ⇒ unchanged.
- [ ] `testGivenCurrentPageRemoved_WhenProfilesChange_ThenFallsBackToFirst()` — current id gone ⇒ resets to first.

**Green — implement:**
- [ ] In `BlockedProfileCarousel`, replace the unconditional `.onChange(of: profiles) { _, _ in initialSetup() }` with a guard that only recomputes when the current page is no longer valid:
  ```swift
  .onChange(of: profiles) { _, _ in
    if currentProfileId == nil
      || !validProfiles.contains(where: { $0.id == currentProfileId }) {
      initialSetup()
    }
  }
  ```
  (Leave the `activeSessionProfileId` and `startingProfileId` `onChange` handlers unchanged — those are intentional navigations.)
- [ ] In `HomeView`, after the carousel consumes `navigateToProfileId` as `startingProfileId`, clear the local `@State` so a stale target can't re-hijack a later profiles change. Set `navigateToProfileId = nil` once the carousel has applied it (e.g. via an `onAppear`/completion callback on the card that matches, or immediately after passing it into the `.onChange(of: navigationManager.navigateToProfileId)` handler once the navigation has been honored). Confirm the exact clear-point during Task 0 against current `HomeView` structure — do not clear it *before* the carousel reads it.

**Verify:** new carousel tests pass; manual reasoning in the skeptic pass confirms the deep-link path still lands on the right card on first navigation.

---

### Task 5: One-skeptic pass on interleavings

- [ ] Dispatch a single skeptic subagent (or self-review with fresh eyes) to attack the three fixes specifically:
  - **#224:** Does routing the guard through `getActiveSession` ever *falsely* reject a legitimate start (e.g. a stale zombie row makes every start fail)? Confirm `getActiveSession`'s `syncScheduleSessions` + fetch semantics can't wedge the user out of starting. Does the Case A gate ever *stick* true (e.g. `isCheckingGeofence` never reset on an early return) and permanently block starts?
  - **#225:** Are there other local start entry points beyond the three named (grep every `createSession` / `strategy.startBlocking` caller) that still bypass the guard? Does the shared `getSnapshot` for a `needsAppSelection` profile really carry empty tokens (precondition holds)?
  - **#246:** Can the keep-page guard strand `currentProfileId` on a value that scrolls to nothing? Does clearing `navigateToProfileId` break the intended first-navigation deep-link?
- [ ] Fold any confirmed gaps back into Tasks 1–4 with an added regression test. Record the skeptic's verdict in the PR description.

---

## Self-Review

Before opening the implementation PR, confirm:
- [ ] Every citation was refreshed (Task 0) and matches the code the diff touches.
- [ ] Each of #224/#225/#246 has at least one failing-first test that now passes; no production code was written before its test.
- [ ] No CloudKit/`CKSyncEngine`/`MutationFunnel` file was modified (this plan is local-only).
- [ ] `swift-format lint --recursive .` is clean; full suite green on the booted simulator UUID.
- [ ] The obsolete siblings (#210, #233) were NOT touched and their close-recommendation comments stand.
- [ ] PR requests review before merge; branch is `fix/263-d3-e2-start-guards` off `main` (not a worktree).
