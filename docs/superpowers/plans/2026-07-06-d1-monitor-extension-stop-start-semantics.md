# D1 — Monitor-Extension Start/Stop Semantics Implementation Plan (#206, #229, #236, #239, #243, #261)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every background/monitor-extension stop and start channel the *same* commitment-respecting policy — a single, extension-evaluable "background stop policy" (session-match + `disableBackgroundStops` + fail-closed geofence + `canStop`) that the DeviceActivity monitor extension can evaluate from the app-group `ProfileSnapshot` alone — and make schedule-suppression (`scheduleLastStoppedAt`) coherent across the app↔extension boundary, so no channel can silently lift a commitment profile's restrictions or resurrect a manually-stopped session.

**Architecture:** Six defects share one root cause: the monitor extension (which has no `StrategyManager`, no `StartStopActionResolver`, and sees only the app-group `ProfileSnapshot`) makes stop/start decisions with **fewer** guards than the in-app paths. The fix is a **pure, side-effect-free `BackgroundStopPolicy`** value type living in `FoqosShared` that BOTH processes call, plus the minimum snapshot-schema addition needed to make it evaluable in the extension (`ProfileStopConditions` moves into `FoqosShared` and rides on `ProfileSnapshot`). The three extension stop/takeover paths (`StopScheduleTimerActivity.stop`, `ScheduleTimerActivity.stop`, `ScheduleTimerActivity.start`) and the app Siri/Shortcuts path (`stopSessionFromBackground`) all route their decision through this one policy. Two independent coherence fixes (`scheduleLastStoppedAt` legacy suppression #229 and app-side merge-back #243) complete the bundle. Every handler is **idempotent** and depends on **no** DeviceActivity callback definitely firing (per the #260 verdict).

**Tech Stack:** Swift 6, SwiftUI, SwiftData, DeviceActivity / FamilyControls / ManagedSettings, XCTest. App target module is `FamilyFoqos`; cross-process shared state lives in the `FoqosShared` local Swift package (app-group `UserDefaults`, suite `group.com.cynexia.family-foqos`). The monitor extension target is `FoqosDeviceMonitor`.

---

## Plan provenance & re-triage (READ FIRST)

- **Planned against `main` @ `18904b6`** ("docs(#263/D2): remote session handling plan (#203, #204, #237, #194) (#274)"). Every `file:line` below is from this commit. The six handovers (`docs/handovers/issue-{206,229,236,239,243,261}-*.md`) date from **2026-07-02** and their line numbers are stale (PRs #264/#269/#271/#275 landed since); all citations here were re-verified against `18904b6` by direct file reads on 2026-07-06.
- **The #261 handover is DISPUTED**, but the dispute is **SETTLED**: the maintainer ruled **Option A — gate background stops on `canStop`** (issue #261 comment, 2026-07-05). This plan implements Option A. Do not re-open it.
- **The #260 verdict is a global constraint**, not a task: DeviceActivity/extension callback delivery is undocumented, contested, and demonstrably flaky. **Every handler this plan adds or changes must be idempotent and must not depend on any callback definitely firing.** This is enforced per-task below.

### Re-triage table (verified against `18904b6`)

| Issue | Sev | Verdict | Current anchor (18904b6) | One-line gap |
|---|---|---|---|---|
| **#261** | high | still-present (SETTLED = Option A) | `Foqos/Utils/StrategyManager.swift:406` `stopSessionFromBackground` | No `canStop` — Siri/Shortcuts stops an NFC/QR/timer-only profile with zero friction. |
| **#206** | high | still-present | `Packages/FoqosShared/.../Timers/ScheduleTimerActivity.swift:88` `stop` | Ends any session whose profile-id matches — no `isTodayScheduled`, no `stopConditions.schedule`, no session-origin check; synthetic daily interval (`DeviceActivityCenterUtil.swift:46-53`) fires it even for manual-only-stop profiles. |
| **#239** | medium | still-present | `Packages/FoqosShared/.../Timers/StopScheduleTimerActivity.swift:22` `stop` | Ignores `disableBackgroundStops` (present on the snapshot it holds). |
| **#236** | medium | still-present | `Packages/FoqosShared/.../Timers/ScheduleTimerActivity.swift:80` `start` | Force-ends a *different* profile's active session (`endActiveSharedSession`) with no `disableBackgroundStops`/stop-condition/geofence check on the victim. |
| **#229** | medium | still-present | `Packages/FoqosShared/.../Timers/ScheduleTimerActivity.swift:58-70` (legacy branch of `start`) | Legacy branch checks only `isTodayScheduled` + `olderThanOneMinute` — ignores `scheduleLastStoppedAt`, so a foreground re-registration restarts a manually-stopped session. |
| **#243** | low | still-present | `Foqos/Utils/PreActivationReminderScheduler.swift:54` + every `getSnapshot`/`updateSnapshot` writer | Extension writes `scheduleLastStoppedAt` into the snapshot only (`StrategyTimerActivity.swift:62`); the app never reads it back into SwiftData and clobbers it on the next `updateSnapshot`. |

---

## Global Constraints

Copied verbatim from `AGENTS.md`; every task's requirements implicitly include these.

- **Never force-commit, amend, or force-push.** New commits only; use `git revert` to undo. The *plan* lives on branch `docs/263-d1-monitor-extension-plan`; **implementation goes on a NEW branch off `main`** named `fix/263-d1-monitor-extension`.
- **Request code review before merging.** Never merge unreviewed.
- **NO parallel development on the same machine.** Only ONE build/test stream at a time. Implement one task at a time; do not run builds/tests while another implementation stream is active.
- **Worktrees:** this plan was authored in a read-only worktree (AGENTS.md permits worktrees for read-only sessions). **Implementation must NOT use a worktree** — use the `fix/263-d1-monitor-extension` feature branch in the main checkout.
- Views must use `@SafeQuery` (never raw `@Query`); non-query `PersistentModel` arrays filtered with `.valid`. *(No view queries are added or changed in this plan.)*
- Lock-code restriction checks must use `appModeManager.currentMode == .child`; the pattern `!= .parent` is forbidden. *(No lock/mode logic in this plan.)*
- Use `Log.<level>(_, category:)` — never `print()`. Session/schedule logs use `category: .timer`, `.session`, or `.strategy`. Never log lock codes or personal identifiers (profile names are acceptable).
- **swift-format** is enforced by a pre-commit hook (2-space indent, ~100–120 col). Run `swift-format --in-place --recursive .` before each commit; `swift-format lint --recursive .` must be clean.
- **Tests:** name `testGivenX_WhenY_ThenZ()`. Pin time — capture one `let now = Date()` per test and inject via `now:` parameters; never call `Date()` more than once per test where an assertion depends on it. Pure schedule tests use a fixed `Calendar(identifier: .gregorian)` and a fixed reference date (see `ScheduleSuppressionTests.swift`).

### Running tests (do this ONCE per session)

```bash
# 1. Boot the simulator ONCE (boot takes 3–5 min; tests take <3 s). Use the UUID, NEVER the name.
xcrun simctl list devices available | grep "iPhone 17"
xcrun simctl boot <UUID>          # e.g. B9E4A679-BDF3-4541-A59F-DA4BE21F80ED

# 2. Run a single test class by UUID
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' \
  -only-testing:FoqosTests/<ClassName> | xcpretty

# 3. Full suite before the final commit
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty
```

Reuse the same booted UUID for every run. All tests live in the **`FoqosTests`** target (the `FoqosShared` package has no test target); they `@testable import FamilyFoqos` and `import FoqosShared`, so the new pure `BackgroundStopPolicy` and the moved `ProfileStopConditions` are directly testable there.

---

## The hard requirement: extension-evaluability

The monitor extension (`FoqosDeviceMonitor/DeviceActivityMonitorExtension.swift`) has **no `StrategyManager`, no `StartStopActionResolver`, no SwiftData, and no live location**. Its only view of a profile is `SharedData.snapshot(for: profileId)` → `SharedData.ProfileSnapshot`, fetched by `TimerActivityUtil.getProfile` and passed to each `TimerActivity.stop(for:)` / `.start(for:)`. **No step in this plan may call `StartStopActionResolver.canStop` (an `@MainActor`, app-target type) from the extension.** Instead, the shared `BackgroundStopPolicy` (in `FoqosShared`) evaluates the same decision from snapshot fields.

**Per-input source table (WHERE each policy input is read, in each process):**

| Policy input | App process — `stopSessionFromBackground` (Siri/Shortcuts, #261) | Extension process — `TimerActivity.stop`/`.start` (#206/#239/#236) | Snapshot change needed? |
|---|---|---|---|
| **session identity match** | `getActiveSession(context:)` + `localActiveSession.blockedProfile.id == profileId` (`StrategyManager.swift:421-431`) | `SharedData.getActiveSharedSession()?.blockedProfileId == snapshot.id` (already compared, e.g. `ScheduleTimerActivity.swift:75,97`) | **none** |
| **`disableBackgroundStops`** | `profile.disableBackgroundStops` (`StrategyManager.swift:439`) | `snapshot.disableBackgroundStops ?? false` (`SharedData.swift:176`) | **none** (already on snapshot) |
| **geofence (fail-closed)** | `geofenceEvaluator.evaluateGeofenceForStop(profile:context:)` — real `CLLocation` (`StrategyManager.swift:448`) | `snapshot.geofenceRule?.hasLocations == true` ⇒ **`.unavailable` (fail-closed)**; else `.noRule` (`SharedData.swift:174`, `GeofenceRule.swift:78`) | **none** (rule already on snapshot); **semantics per channel = [MDR-3](#mdr-3)** |
| **`canStop`** — `.manual` for shortcut/takeover, `.schedule` for schedule stops | `StartStopActionResolver.canStop(with: .manual, conditions: profile.stopConditions, …)` (in-app; `StartStopActionResolver.swift:123`) | `snapshot.stopConditions.manual` / `.schedule` — **requires adding `stopConditions` to the snapshot (Task 1)** | **YES — Task 1** |

`canStop(with: .manual, conditions:…)` is *defined* as `conditions.manual` (`StartStopActionResolver.swift:132-136`); `canStop(.schedule)` as `conditions.schedule` (`:198-202`). So the only missing snapshot ingredient is the `ProfileStopConditions` value itself. `getSnapshot` currently copies **only** `stopConditions.schedule` (as the flat `stopConditionsSchedule`, `BlockedProfiles.swift:527`) — not the composite. **Task 1 moves `ProfileStopConditions` into `FoqosShared` and adds `stopConditions: ProfileStopConditions?` to `ProfileSnapshot`, populated at the single `getSnapshot` builder.** Because every snapshot writer funnels through `getSnapshot` → `updateSnapshot` → `SharedData.setSnapshot` (call sites: `BlockedProfiles.swift:462` `updateProfile`, `:629` `createProfile`, `:692` `cloneProfile`; plus `PreActivationReminderScheduler.swift:58`), populating the builder populates every write site automatically. This is verified in Task 1 Step 6.

---

## The `scheduleLastStoppedAt` suppression data-flow (resolves #229 / #243)

`scheduleLastStoppedAt` records "this schedule window was already dismissed; do not restart it." It has **two stores** (SwiftData `BlockedProfiles.scheduleLastStoppedAt`, and the app-group `ProfileSnapshot.scheduleLastStoppedAt`) and **two readers** (the extension via `shouldBeActiveNow`, and the app's `catchUpMissedScheduleStarts`). Today the two stores drift. The explicit data-flow (verified 2026-07-06):

| Actor / site | WRITES | READS | May CLOBBER |
|---|---|---|---|
| Extension `StrategyTimerActivity.stop` (`StrategyTimerActivity.swift:62`) | `SharedData.setLastStoppedAt(profileId, now)` → **snapshot only** (in-place, `SharedData.swift:405-413`) | — | — |
| App `BlockedProfileSessions.endSession` (`BlockedProfileSessions.swift:90-91`) | `blockedProfile.scheduleLastStoppedAt = now` (SwiftData) **then** `updateSnapshot` (rewrites snapshot from SwiftData) | — | overwrites snapshot's value with the SwiftData value it just set (consistent — same value) |
| App `BlockedProfiles.updateSnapshot`/`updateProfile`/`getSnapshot` (`:462`,`:527-534`,`:539-542`) | snapshot.`scheduleLastStoppedAt` = **stale SwiftData value** | — | **CLOBBERS the extension's snapshot-only write (#243)** — any profile edit or foreground catch-up erases it |
| App `catchUpMissedScheduleStarts` (`PreActivationReminderScheduler.swift:54`) | — | `profile.scheduleLastStoppedAt` (**SwiftData**), passed to `shouldBeActiveNow` | reads stale SwiftData (never sees the extension's snapshot write) → **restarts the just-ended session (#243)** |
| Extension `ScheduleTimerActivity.start` **V2 branch** (`ScheduleTimerActivity.swift:48-57`) | — | `snapshot.scheduleLastStoppedAt` via `shouldBeActiveNow` step 4 (`ProfileScheduleTime.swift:164`) | reads snapshot value (correct) |
| Extension `ScheduleTimerActivity.start` **legacy branch** (`ScheduleTimerActivity.swift:58-70`) | — | **nothing** — ignores `scheduleLastStoppedAt` entirely (**#229**) | — |
| CloudKit sync (`SyncApplyService.swift:285,334`; `SyncModels.swift:307`) | `profile.scheduleLastStoppedAt` (SwiftData) from/to the wire | — | last-write-wins across devices (out of D1 scope; unchanged) |

**Two fixes:**
- **#243 (Task 8):** on every foreground/launch, **before** `catchUpMissedScheduleStarts` and before any `updateSnapshot`, merge the snapshot's value into SwiftData: `profile.scheduleLastStoppedAt = max(swiftData, snapshot)`. This makes the extension's out-of-process write authoritative and readable by the app, and immunizes it from the `updateSnapshot` clobber (after the merge, SwiftData already holds the newer value, so the next `updateSnapshot` writes the correct value back).
- **#229 (Task 7):** the legacy branch of `ScheduleTimerActivity.start` gains the same suppression the V2 branch has — suppress when `snapshot.scheduleLastStoppedAt >= today's legacy window start`. The extension reads the value from the snapshot directly (no SwiftData needed); Task 8's merge keeps that snapshot value fresh across app writes.

---

## Coordination & sequencing (MANDATORY — read before implementing)

**D2 (remote-session handling) implements FIRST** and merges before D1. Its plan is `docs/superpowers/plans/2026-07-05-d2-remote-session-handling.md`. D1 shares surface with D2 and must compose with **D2's end-state**, not current `main`:

1. **D2 Task 1 Part A** changes the signatures of the six in-app `SharedData` mutators to take `expectedSessionId: String` and no-op on identity mismatch (`flushActiveSession`, `setEndTime`, `setBreakStartTime`, `setBreakEndTime`, `setOneMoreMinuteStartTime`, `clearOneMoreMinuteStartTime`). **D1 does NOT touch those six.** D1 adds a *new* identity-gated variant of `endActiveSharedSession` (Task 2 Step 7) — a DIFFERENT primitive D2 leaves un-gated — so there is no signature conflict. If D2's Part A also renamed `endActiveSharedSession`, reconcile in Task 0.
2. **D2 Task 3** adds session teardown to `SyncApplyService.deleteLocalProfile` (the remote-delete path) via `SessionController.stopRemoteSession`. That is the **remote-stop channel** in the #261 matrix. **D1 does NOT re-gate the remote-stop path** — see [MDR-2](#mdr-2): remote operations are trusted-at-origin (D2 MAINTAINER DECISION 2). D1's shared policy applies to Shortcuts + the extension schedule channels only.
3. **D2 Task 1 Part B** adds a reconcile guard to `toggleBlocking`. D1 does not touch `toggleBlocking`.
4. **Bundles F, I, C2 also merge before D1.** C2 (issue #214 / #260 break-end) reshapes break/`activateSession` paths. C2's #260 fix (in-process break-end re-apply) is the *same idempotency principle* D1 follows; they do not conflict (C2 touches `stopBreak`/`BreakTimerActivity`; D1 touches the schedule timers + `stopSessionFromBackground`).

Because of the above, **the first task of the implementing session is [Task 0](#task-0-refresh-citations--re-verify-against-post-d2-main).** Every line number below is from `18904b6` and *will* have drifted after D2/C2/F/I merge.

---

## File Structure

| File | Responsibility | Task |
|------|----------------|------|
| `Foqos/Models/ProfileStopConditions.swift` → **move to** `Packages/FoqosShared/Sources/FoqosShared/ProfileStopConditions.swift` | Make the pure `ProfileStopConditions` value type available to the extension. | 1 |
| `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift` | Add `stopConditions: ProfileStopConditions?` to `ProfileSnapshot` (+ init param). Add `endActiveSharedSession(expectedSessionId:)`. | 1, 2 |
| `Foqos/Models/BlockedProfiles.swift:500-536` | `getSnapshot` populates `stopConditions: profile.stopConditions`. | 1 |
| `Packages/FoqosShared/Sources/FoqosShared/BackgroundStopPolicy.swift` | **NEW.** Pure, side-effect-free policy evaluator (the single source of truth for every background stop channel). | 2 |
| `FoqosTests/BackgroundStopPolicyTests.swift` | **NEW.** Full decision matrix for the pure policy. | 2 |
| `FoqosTests/ProfileSnapshotStopConditionsTests.swift` | **NEW.** `getSnapshot` round-trips `stopConditions` for the extension. | 1 |
| `Foqos/Utils/StrategyManager.swift:406-472` (`stopSessionFromBackground`) | Route the decision through `BackgroundStopPolicy` (adds the missing `canStop` gate). | 3 |
| `Foqos/Intents/IntentError.swift` | Add `case stopConditionsNotMet(reason: String)`. | 3 |
| `FoqosTests/StrategyManagerBackgroundTests.swift` | Add the #261 regression (Shortcuts refuses an NFC-only profile). | 3 |
| `Packages/FoqosShared/Sources/FoqosShared/Timers/StopScheduleTimerActivity.swift:22-47` | `stop` routes through `BackgroundStopPolicy` (channel `.schedule`). | 4 |
| `Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift:88-110` | `stop` routes through `BackgroundStopPolicy` (channel `.schedule`) + `isTodayScheduled` + id-gated end. | 5 |
| `Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift:74-86` | `start` takeover guard: evaluate the victim via `BackgroundStopPolicy` (channel `.takeover`) before force-ending. | 6 |
| `Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift:58-70` | `start` legacy branch: `scheduleLastStoppedAt` suppression. | 7 |
| `Packages/FoqosShared/Sources/FoqosShared/Schedule.swift` | Add pure `BlockedProfileSchedule.windowStart(on:calendar:)` helper for #229. | 7 |
| `FoqosTests/ScheduleTimerActivityTests.swift` | **NEW.** Snapshot-driven tests for Tasks 5/6/7 (extension stop/takeover/legacy-suppression). | 5,6,7 |
| `Foqos/Utils/PreActivationReminderScheduler.swift` | Add `mergeExtensionScheduleSuppression(context:)`; call it before catch-up. | 8 |
| `Foqos/FoqosApp.swift:159,257` | Call the merge before `rescheduleAllReminders`/`catchUpMissedScheduleStarts`. | 8 |
| `FoqosTests/ScheduleSuppressionMergeTests.swift` | **NEW.** Snapshot value merges into SwiftData; catch-up then suppresses. | 8 |

---

## MAINTAINER DECISIONS REQUIRED

Anything "clever" — a unification, an early-exit, a per-channel exception, a schema choice — is surfaced here rather than chosen silently. Each has a **recommendation**; the implementing session must get a maintainer ruling on any marked ⚠️ UNRESOLVED before coding the affected task. Items already ratified by the maintainer are marked ✅ SETTLED and are not open for redesign.

### MDR-0 — #261 gate on `canStop` ✅ SETTLED (Option A, 2026-07-05)
Not open for redesign. `stopSessionFromBackground` gates on `canStop` in addition to session-match + `disableBackgroundStops` + fail-closed geofence. Profiles with `manual` stop allowed are unaffected. Implemented in Task 3. The three overstating copy strings become *true* under Option A (copy audit, Task 3 Step 6).

### MDR-1 — App path: route through the shared policy vs. add the check inline  ⚠️ UNRESOLVED (recommend: route through)
The maintainer's directive is "**ONE** shared background-stop policy … applied uniformly … no per-channel exceptions." Two ways to realize that for the app-side Siri/Shortcuts path:
- **(A) Route `stopSessionFromBackground` through `BackgroundStopPolicy` (RECOMMENDED).** The app still *evaluates* geofence with real location (produces a `GeofenceState`) and still owns its typed `IntentError`s and the geofence notification, but the *decision* (disableBackgroundStops + geofence + canStop) is the shared policy's `Decision`, mapped to `IntentError`. One decision implementation, two call sites (app + extension). This is what Task 3 is written against.
- **(B) Add only the missing `canStop(.manual)` check inline** in `stopSessionFromBackground`, leaving its other guards as bespoke code. Lower churn on a well-tested path, but the "one policy" is then a convention, not a call.

Recommendation: **A** — it is the literal reading of the directive and single-sources the decision. Risk is contained because the app path keeps its own geofence *evaluation* and error taxonomy. If the maintainer prefers minimal churn, fall back to **B** (Task 3 notes the exact inline edit).

### MDR-2 — Remote-stop channel: trust-at-origin vs. re-gate on the receiver  ⚠️ UNRESOLVED (recommend: trust-at-origin — do NOT re-gate)
The #261 comment says apply the policy "uniformly to Shortcuts/Siri, schedule stops, **and remote stops**." That collides with **D2 MAINTAINER DECISION 2** (settled 2026-07-05): remote operations are **trusted-at-origin** — every propagated stop/delete was authorized locally where it originated, so the wire needs no re-validation. Re-running `canStop` on the *receiving* device is also **semantically impossible and unsafe**: (a) the receiver does not know the origin's stop *method* (it only sees "session ended"), so it cannot reconstruct the correct `StopMethod`; (b) if the receiver refused what the origin allowed, the two devices would **diverge** (origin unblocked, receiver still blocked) — breaking sync convergence. The #261 comment's own stop-path matrix lists the remote-stop row as gated "no (sync propagation of a stop validated at origin)", i.e. it contradicts its own "uniformly … remote stops" phrasing.
Recommendation: **the shared policy applies to the Shortcuts/Siri channel (#261) and the extension schedule channels (#206/#239/#236) only. The remote-stop path (`stopRemoteSession` / D2's `deleteLocalProfile` teardown) is trusted-at-origin and is NOT re-gated by D1.** This is the one deliberate, documented exception to "no per-channel exceptions," justified by D2 MD2 and convergence. **Get explicit maintainer sign-off** that this reconciles #261's "remote stops" phrasing with D2 MD2.

### MDR-3 — Geofence on the schedule-stop channel  ⚠️ UNRESOLVED (recommend: omit geofence from the `.schedule` channel)
A geofence rule means "you may only *stop* this profile when [within/outside] these locations." The extension cannot evaluate location, so a strict "fail-closed geofence, uniformly" would make the `.schedule` channel **refuse the scheduled stop whenever a geofence rule exists** — and because the in-app manual stop *also* requires the geofence, a geofenced+scheduled profile could become **permanently un-stoppable in the background** (a lock-in the product does not intend). Today, schedule stops never check geofence (the #261 matrix lists schedule-stop geofence as ❌).
Options for the `.schedule` channel geofence input:
- **(A) Omit geofence from the `.schedule` channel (RECOMMENDED).** A scheduled stop is *time-authoritative*; geofence gates user-initiated/manual stops, not the clock. Matches current behavior; no lock-in. The `.shortcut` and `.takeover` channels keep fail-closed geofence.
- **(B) Fail-closed uniformly.** Purest reading of "uniform," but risks the permanent-trap above and changes behavior for geofence+schedule profiles.
Recommendation: **A.** Task 4/5 pass `geofence: .noRule` for the `.schedule` channel regardless of `snapshot.geofenceRule` (documented in code). **Confirm with the maintainer.**

### MDR-4 — #206 synthetic daily interval: guard in the extension vs. fix the scheduler  ⚠️ UNRESOLVED (recommend: guard in the extension, primary; scheduler cleanup optional)
Root cause of #206's daily fire is the scheduler synthesizing `intervalEnd = start − 1 min` for manual-only-stop profiles (`DeviceActivityCenterUtil.swift:46-53`, `repeats: true`). Two fix locations:
- **(A) Guard in `ScheduleTimerActivity.stop` (RECOMMENDED, primary).** Reject the stop when `!snapshot.stopConditions.schedule` (canStop(.schedule) fails) or not `isTodayScheduled`. This is **in the evaluable process** and robust to the #260 flakiness (idempotent, self-defending). Task 5 implements this.
- **(B) Also stop synthesizing a daily-firing interval** in `DeviceActivityCenterUtil.scheduleTimerActivity` for manual-only-stop profiles. Reduces spurious callbacks but is in the app process and cannot be relied on by the extension.
Recommendation: **A now (Task 5); B as an optional follow-up** (not in D1 scope unless the maintainer wants it). The extension guard makes the fix correct even if B never lands.

### MDR-5 — #236 takeover: skip vs. defer  ⚠️ UNRESOLVED (recommend: skip — keep the victim)
When `ScheduleTimerActivity.start` finds a *different* profile's session active and the shared policy says that session may **not** be stopped in the background (victim has `disableBackgroundStops` or non-manual stop conditions), what happens to the scheduled profile?
- **(A) Skip the takeover (RECOMMENDED).** Keep the victim session; do **not** start the scheduled profile; log. The scheduled profile simply does not start this window (it will re-evaluate next window). Simplest, no new state.
- **(B) Defer** the scheduled start until the victim ends. Requires new deferral bookkeeping in the extension; more complex; interacts with the flaky-callback model.
Recommendation: **A.** Task 6 implements skip.

### MDR-6 — Snapshot schema: move `ProfileStopConditions` vs. add a mirror type  ⚠️ UNRESOLVED (recommend: move it)
The extension needs the stop-condition booleans. `ProfileStopConditions` is a pure `Codable` value (only `import Foundation`) but is referenced by ~9 app files + 6 test files.
- **(A) Move it into `FoqosShared` (RECOMMENDED).** DRY, single source; the ~9 app files already largely `import FoqosShared` (they use `SharedData`); the compiler flags any missing import. The JSON shape is unchanged (same fields), so `stopConditionsData` (`BlockedProfiles.swift:143`) and `SyncModels` wire format are unaffected. Pre-release, no live users, so no migration constraint.
- **(B) Keep it in the app; add a `FoqosShared` mirror struct** on the snapshot. Fully decoupled, zero import churn, but duplicates 10 booleans and risks drift.
Recommendation: **A** (matches the project's "prefer structural fixes" stance and the `GeofenceRule`-in-`FoqosShared` precedent). Task 1 is written for **A**; if the maintainer prefers **B**, Task 1's note gives the mirror shape.

---

## Task 0: Refresh citations & re-verify against post-D2 `main`

**Mandatory gate, not optional.** Every line number in Tasks 1–8 is from `18904b6`. D2, C2, F, and I merge before D1. Verify the ground before writing code.

- [ ] **Step 1: Branch off current `main`.**

```bash
git checkout main && git pull
git checkout -b fix/263-d1-monitor-extension
```

- [ ] **Step 2: Confirm each defect still exists** (open each file, check the cited symbol still has the gap). If a prior bundle already fixed one, STOP and re-triage that issue before proceeding.
  - **#261:** `StrategyManager.swift` `stopSessionFromBackground` still has **no** `StartStopActionResolver.canStop` call (guards are profile-found, active-session, session-match, `disableBackgroundStops`, geofence only).
  - **#206:** `ScheduleTimerActivity.stop` still ends on profile-id match with **no** `isTodayScheduled` / `stopConditions.schedule` / session-origin check.
  - **#239:** `StopScheduleTimerActivity.stop` still has **no** `disableBackgroundStops` check.
  - **#236:** `ScheduleTimerActivity.start` still calls `SharedData.endActiveSharedSession()` on a different-profile session with **no** guard.
  - **#229:** `ScheduleTimerActivity.start` legacy branch (`else if let schedule = profile.schedule`) still checks only `isTodayScheduled()` + `olderThanOneMinute()`.
  - **#243:** no app-side reader merges `SharedData.snapshot(for:)?.scheduleLastStoppedAt` into SwiftData; `catchUpMissedScheduleStarts` still reads `profile.scheduleLastStoppedAt` (SwiftData) only.

- [ ] **Step 3: Re-confirm the D2 composition points** (D2 has merged): the six in-app `SharedData` mutators now take `expectedSessionId`; `endActiveSharedSession()` (no id) is **still present and un-gated** (D1 Task 2 adds the id-gated sibling — confirm the name did not collide). `SyncApplyService.deleteLocalProfile` now calls `stopRemoteSession` (D2 Task 3) — confirm D1 does not touch it.

- [ ] **Step 4: Refresh every `file:line`** in Tasks 1–8 to post-merge numbers using **symbol search** (function names are stable; lines are not). Update the anchors in-place in your working copy of this plan.

- [ ] **Step 5: Boot the simulator once and run the full suite green** to establish a clean baseline. If red on fresh `main`, STOP and report.

No commit for Task 0 (verification only).

---

## Task 1: Make stop conditions extension-visible (move `ProfileStopConditions`; add to `ProfileSnapshot`)

**This is the schema foundation for extension-evaluability. Implements [MDR-6 = A](#mdr-6).**

**Files:**
- Move: `Foqos/Models/ProfileStopConditions.swift` → `Packages/FoqosShared/Sources/FoqosShared/ProfileStopConditions.swift`
- Modify: `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift:140-257` (`ProfileSnapshot` struct + memberwise init)
- Modify: `Foqos/Models/BlockedProfiles.swift:500-536` (`getSnapshot`)
- Create: `FoqosTests/ProfileSnapshotStopConditionsTests.swift`

**Interfaces:**
- Produces: `SharedData.ProfileSnapshot.stopConditions: ProfileStopConditions?` (nil-defaulting, back-compat-safe Codable field). `ProfileStopConditions` becomes a `public` `FoqosShared` type (add `public` to the struct and every member/computed property so the extension and the policy can read them).
- Consumes: `BlockedProfiles.stopConditions: ProfileStopConditions` (`BlockedProfiles.swift:131`, unchanged).

- [ ] **Step 1: Move the type into `FoqosShared` and make it public.** `git mv Foqos/Models/ProfileStopConditions.swift Packages/FoqosShared/Sources/FoqosShared/ProfileStopConditions.swift`, then mark it `public` (the type, its stored vars, its `init`, and the computed `isValid`/`hasNFC`/`hasQR`/`requiresPhysicalItemOnly`). Add an explicit memberwise `public init` (Swift synthesizes an `internal` one otherwise, which the app module cannot call). Final content:

```swift
import Foundation

/// Defines which conditions can end a blocking session for a profile.
/// Multiple conditions can be enabled simultaneously.
/// Lives in FoqosShared so the DeviceActivity monitor extension can evaluate
/// stop conditions from the app-group ProfileSnapshot (it has no StartStopActionResolver).
public struct ProfileStopConditions: Codable, Equatable {
  public var manual: Bool
  public var timer: Bool
  public var anyNFC: Bool
  public var specificNFC: Bool
  public var sameNFC: Bool
  public var anyQR: Bool
  public var specificQR: Bool
  public var sameQR: Bool
  public var schedule: Bool
  public var deepLink: Bool

  public init(
    manual: Bool = false,
    timer: Bool = false,
    anyNFC: Bool = false,
    specificNFC: Bool = false,
    sameNFC: Bool = false,
    anyQR: Bool = false,
    specificQR: Bool = false,
    sameQR: Bool = false,
    schedule: Bool = false,
    deepLink: Bool = false
  ) {
    self.manual = manual
    self.timer = timer
    self.anyNFC = anyNFC
    self.specificNFC = specificNFC
    self.sameNFC = sameNFC
    self.anyQR = anyQR
    self.specificQR = specificQR
    self.sameQR = sameQR
    self.schedule = schedule
    self.deepLink = deepLink
  }

  /// True if at least one condition is selected
  public var isValid: Bool {
    manual || timer || anyNFC || specificNFC || sameNFC
      || anyQR || specificQR || sameQR || schedule || deepLink
  }

  /// True if any NFC stop condition is enabled
  public var hasNFC: Bool { anyNFC || sameNFC || specificNFC }

  /// True if any QR stop condition is enabled
  public var hasQR: Bool { anyQR || sameQR || specificQR }

  /// True if every enabled stop condition requires a specific physical item.
  public var requiresPhysicalItemOnly: Bool {
    guard isValid else { return false }
    let hasAlwaysAvailable = manual || timer || anyNFC || anyQR || schedule
    return !hasAlwaysAvailable
  }
}
```

- [ ] **Step 2: Fix imports.** Build; for every app/test file the compiler reports as unable to find `ProfileStopConditions`, add `import FoqosShared` at the top (candidates from grep: `Foqos/CloudKit/SyncModels.swift`, `Foqos/Components/BlockedProfileView/StopConditionSelector.swift`, `Foqos/Models/BlockedProfiles.swift`, `Foqos/Models/TriggerConfigurationModel.swift`, `Foqos/Models/TriggerPickerOptions.swift`, `Foqos/Models/TriggerValidator.swift`, `Foqos/Utils/StartStopActionResolver.swift`, `Foqos/Utils/TriggerMigration.swift`, and tests `ProfileStopConditionsTests`, `StrategyManagerStartTests`, `StrategyManagerStopTests`, `TriggerMigrationTests`, `TriggerPickerOptionsTests`, `TriggerValidatorTests`). Most already import `FoqosShared`; add only where missing.

- [ ] **Step 3: Add the field to `ProfileSnapshot`.** In `SharedData.swift`, add the stored property after `disableBackgroundStops` (`:176`):

```swift
    public var disableBackgroundStops: Bool?

    /// The profile's stop conditions, so the monitor extension can evaluate
    /// canStop() without StartStopActionResolver. Optional for snapshot back-compat
    /// (older encoded snapshots decode it as nil → treated as "no conditions").
    public var stopConditions: ProfileStopConditions?
```

Add the matching init parameter (after `disableBackgroundStops: Bool? = nil` at `:216`) and assignment (after `self.disableBackgroundStops = disableBackgroundStops` at `:250`):

```swift
      disableBackgroundStops: Bool? = nil,
      stopConditions: ProfileStopConditions? = nil,   // <-- add
```
```swift
      self.disableBackgroundStops = disableBackgroundStops
      self.stopConditions = stopConditions            // <-- add
```

> **Placement matters:** put `stopConditions` LAST in the parameter list is NOT required, but if you insert it mid-list, update ALL call sites. `getSnapshot` (Task 1 Step 5) is the only production caller; test call sites use labeled args so order is irrelevant. Keeping the existing param order and appending `stopConditions` near `disableBackgroundStops` is least disruptive.

- [ ] **Step 4: Write the failing round-trip test.** Create `FoqosTests/ProfileSnapshotStopConditionsTests.swift`:

```swift
import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class ProfileSnapshotStopConditionsTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!

  override func setUp() async throws {
    try await super.setUp()
    container = try TestModelContainer.create()
    context = container.mainContext
  }

  // #206/#236/#261: the extension must see the profile's stop conditions on the snapshot.
  func testGivenProfileWithNFCOnlyStop_WhenBuildingSnapshot_ThenStopConditionsCarried() throws {
    let profile = BlockedProfiles(name: "NFC only")
    profile.stopConditions = ProfileStopConditions(manual: false, anyNFC: true)
    context.insert(profile)
    try context.save()

    let snapshot = BlockedProfiles.getSnapshot(for: profile)

    XCTAssertEqual(snapshot.stopConditions?.manual, false, "manual not allowed is visible to extension")
    XCTAssertEqual(snapshot.stopConditions?.anyNFC, true)
  }

  // Codable back-compat: an older snapshot without the field decodes to nil, not a crash.
  func testGivenSnapshotEncodedWithoutStopConditions_WhenDecoding_ThenNil() throws {
    // Build a snapshot, then simulate an "old" encoding by round-tripping through a dict
    // that omits stopConditions.
    let profile = BlockedProfiles(name: "Legacy")
    profile.stopConditions = ProfileStopConditions(manual: true)
    let snapshot = BlockedProfiles.getSnapshot(for: profile)
    var json = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(snapshot)) as! [String: Any]
    json.removeValue(forKey: "stopConditions")
    let stripped = try JSONSerialization.data(withJSONObject: json)

    let decoded = try JSONDecoder().decode(SharedData.ProfileSnapshot.self, from: stripped)

    XCTAssertNil(decoded.stopConditions, "missing field decodes to nil (back-compat)")
  }
}
```

- [ ] **Step 5: Populate `stopConditions` in `getSnapshot`.** In `Foqos/Models/BlockedProfiles.swift`, add one line to the `SharedData.ProfileSnapshot(...)` literal (after `disableBackgroundStops: profile.disableBackgroundStops,` at `:529`):

```swift
      disableBackgroundStops: profile.disableBackgroundStops,
      stopConditions: profile.stopConditions,        // <-- add (#206/#236/#261 extension-evaluability)
      isManaged: profile.isManaged,
```

- [ ] **Step 6: Run the round-trip tests.**

Run: `xcodebuild test … -only-testing:FoqosTests/ProfileSnapshotStopConditionsTests`
Expected: PASS (both). Then run the pre-existing `-only-testing:FoqosTests/ProfileStopConditionsTests` to confirm the moved type still passes its own suite unchanged.

- [ ] **Step 7: swift-format + commit.**

```bash
swift-format --in-place --recursive .
swift-format lint --recursive .
git add Packages/FoqosShared/Sources/FoqosShared/ProfileStopConditions.swift \
        Packages/FoqosShared/Sources/FoqosShared/SharedData.swift \
        Foqos/Models/BlockedProfiles.swift \
        FoqosTests/ProfileSnapshotStopConditionsTests.swift
# plus any files that gained `import FoqosShared` in Step 2
git add -u
git commit -m "feat(#263/D1): move ProfileStopConditions to FoqosShared; add to ProfileSnapshot

The DeviceActivity monitor extension has no StartStopActionResolver and can only
read the app-group ProfileSnapshot. To let it evaluate canStop() for the shared
background-stop policy (#206/#236/#261), move the pure ProfileStopConditions value
type into FoqosShared and carry it on ProfileSnapshot, populated by getSnapshot
(the single snapshot builder every writer funnels through). Optional field →
back-compat safe for older encoded snapshots (decode to nil)."
```

---

## Task 2: The pure `BackgroundStopPolicy` + identity-gated extension session-end

**The single source of truth for every background stop channel.** Pure value type — no DeviceActivity, no SwiftData, no location, no `@MainActor`. Also adds the identity-gated `endActiveSharedSession(expectedSessionId:)` that closes the extension-side read-then-end TOCTOU (see the adversarial notes).

**Files:**
- Create: `Packages/FoqosShared/Sources/FoqosShared/BackgroundStopPolicy.swift`
- Modify: `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift` (add `endActiveSharedSession(expectedSessionId:)` near `:392`)
- Create: `FoqosTests/BackgroundStopPolicyTests.swift`

**Interfaces:**
- Produces:
  - `BackgroundStopPolicy.Channel` = `.shortcut | .schedule | .takeover`
  - `BackgroundStopPolicy.GeofenceState` = `.noRule | .satisfied | .notSatisfied(reason: String) | .unavailable`
  - `BackgroundStopPolicy.Denial` = `.noMatchingSession | .backgroundStopsDisabled | .geofenceNotSatisfied(reason: String) | .geofenceUnavailable | .stopConditionNotMet(reason: String)`
  - `BackgroundStopPolicy.Decision` = `.allowed | .denied(Denial)` (Equatable)
  - `static func evaluate(channel:sessionMatchesProfile:disableBackgroundStops:geofence:stopConditions:) -> Decision`
  - `@discardableResult SharedData.endActiveSharedSession(expectedSessionId: String) -> Bool` — appends to `completedSessionsInScheduler` + clears `activeSharedSession`, **only if** the current active session's `id == expectedSessionId`; returns `true` iff it actually ended (idempotent; a swapped/absent session → `false`, no-op). **The Bool lets the caller deactivate the global ManagedSettings store ONLY when the end actually fired — see the [race note](#a1a2) — so a stale fire never lifts a different profile's restrictions.**
  - `SharedData.startSchedulerSessionTakingOver(profileId: UUID, expectedVictimId: String?) -> Bool` — the **atomic** takeover for a scheduled start (Task 6): within one `withLock`, (a) if no session is active, create the scheduler session and return `true`; (b) if the active session is `expectedVictimId`, append it to `completedSessionsInScheduler` and replace it with the scheduler session, return `true`; (c) if the active session is already this profile's, return `true` (continue, no-op); (d) otherwise (a *different, newer* session appeared in the eval→write gap) do **nothing** and return `false`. This closes the F2 hole where the un-gated `createSessionForScheduler` would clobber a session that arrived after the policy read.
- Consumes: `ProfileStopConditions` (Task 1), `SharedData.SessionSnapshot.id` (`SharedData.swift:262`).

- [ ] **Step 1: Write the failing policy tests.** Create `FoqosTests/BackgroundStopPolicyTests.swift`:

```swift
import FoqosShared
import XCTest

final class BackgroundStopPolicyTests: XCTestCase {

  private func manualOnly() -> ProfileStopConditions { ProfileStopConditions(manual: true) }
  private func nfcOnly() -> ProfileStopConditions { ProfileStopConditions(anyNFC: true) }
  private func scheduleOnly() -> ProfileStopConditions { ProfileStopConditions(schedule: true) }

  // MARK: - session match

  func testGivenNoSessionMatch_WhenEvaluating_ThenDeniedNoMatchingSession() {
    let d = BackgroundStopPolicy.evaluate(
      channel: .shortcut, sessionMatchesProfile: false,
      disableBackgroundStops: false, geofence: .noRule, stopConditions: manualOnly())
    XCTAssertEqual(d, .denied(.noMatchingSession))
  }

  // MARK: - disableBackgroundStops (checked before canStop)

  func testGivenBackgroundStopsDisabled_WhenShortcut_ThenDeniedDisabled() {
    let d = BackgroundStopPolicy.evaluate(
      channel: .shortcut, sessionMatchesProfile: true,
      disableBackgroundStops: true, geofence: .noRule, stopConditions: manualOnly())
    XCTAssertEqual(d, .denied(.backgroundStopsDisabled))
  }

  // MARK: - geofence (shortcut/takeover channels)

  func testGivenGeofenceUnavailable_WhenShortcut_ThenDeniedFailClosed() {
    let d = BackgroundStopPolicy.evaluate(
      channel: .shortcut, sessionMatchesProfile: true,
      disableBackgroundStops: false, geofence: .unavailable, stopConditions: manualOnly())
    XCTAssertEqual(d, .denied(.geofenceUnavailable))
  }

  func testGivenGeofenceNotSatisfied_WhenShortcut_ThenDeniedWithReason() {
    let d = BackgroundStopPolicy.evaluate(
      channel: .shortcut, sessionMatchesProfile: true,
      disableBackgroundStops: false, geofence: .notSatisfied(reason: "Not at home"),
      stopConditions: manualOnly())
    XCTAssertEqual(d, .denied(.geofenceNotSatisfied(reason: "Not at home")))
  }

  // MARK: - canStop: .shortcut / .takeover require conditions.manual

  func testGivenManualAllowed_WhenShortcut_ThenAllowed() {
    let d = BackgroundStopPolicy.evaluate(
      channel: .shortcut, sessionMatchesProfile: true,
      disableBackgroundStops: false, geofence: .noRule, stopConditions: manualOnly())
    XCTAssertEqual(d, .allowed)
  }

  func testGivenNFCOnly_WhenShortcut_ThenDeniedStopConditionNotMet() {
    let d = BackgroundStopPolicy.evaluate(
      channel: .shortcut, sessionMatchesProfile: true,
      disableBackgroundStops: false, geofence: .noRule, stopConditions: nfcOnly())
    guard case .denied(.stopConditionNotMet) = d else {
      return XCTFail("NFC-only profile must refuse a Shortcuts (manual-equivalent) stop (#261)")
    }
  }

  func testGivenNFCOnly_WhenTakeover_ThenDeniedStopConditionNotMet() {
    let d = BackgroundStopPolicy.evaluate(
      channel: .takeover, sessionMatchesProfile: true,
      disableBackgroundStops: false, geofence: .noRule, stopConditions: nfcOnly())
    guard case .denied(.stopConditionNotMet) = d else {
      return XCTFail("a commitment victim must not be force-ended by a scheduled takeover (#236)")
    }
  }

  // MARK: - canStop: .schedule requires conditions.schedule

  func testGivenScheduleAllowed_WhenScheduleChannel_ThenAllowed() {
    let d = BackgroundStopPolicy.evaluate(
      channel: .schedule, sessionMatchesProfile: true,
      disableBackgroundStops: false, geofence: .noRule, stopConditions: scheduleOnly())
    XCTAssertEqual(d, .allowed)
  }

  func testGivenManualOnly_WhenScheduleChannel_ThenDeniedStopConditionNotMet() {
    // #206: a manual-only-stop profile must NOT be ended by the synthetic daily schedule interval.
    let d = BackgroundStopPolicy.evaluate(
      channel: .schedule, sessionMatchesProfile: true,
      disableBackgroundStops: false, geofence: .noRule, stopConditions: manualOnly())
    guard case .denied(.stopConditionNotMet) = d else {
      return XCTFail("manual-only profile must refuse a scheduled stop (#206)")
    }
  }

  // #239: disableBackgroundStops blocks a scheduled stop too.
  func testGivenBackgroundStopsDisabled_WhenScheduleChannel_ThenDeniedDisabled() {
    let d = BackgroundStopPolicy.evaluate(
      channel: .schedule, sessionMatchesProfile: true,
      disableBackgroundStops: true, geofence: .noRule, stopConditions: scheduleOnly())
    XCTAssertEqual(d, .denied(.backgroundStopsDisabled))
  }

  // nil stopConditions (older snapshot) → treated as "no condition met" → denied, never allowed.
  func testGivenNilStopConditions_WhenSchedule_ThenDenied() {
    let d = BackgroundStopPolicy.evaluate(
      channel: .schedule, sessionMatchesProfile: true,
      disableBackgroundStops: false, geofence: .noRule, stopConditions: nil)
    guard case .denied = d else { return XCTFail("nil conditions must fail closed") }
  }
}
```

- [ ] **Step 2: Run to verify it fails.**

Run: `xcodebuild test … -only-testing:FoqosTests/BackgroundStopPolicyTests`
Expected: FAIL to compile — `BackgroundStopPolicy` does not exist yet.

- [ ] **Step 3: Implement the pure policy.** Create `Packages/FoqosShared/Sources/FoqosShared/BackgroundStopPolicy.swift`:

```swift
import Foundation

/// The single source of truth for whether a *background* actor (Siri/Shortcuts,
/// the DeviceActivity monitor extension's scheduled stop, or a scheduled-start
/// takeover) may stop a session. Pure and side-effect-free so BOTH the app process
/// and the extension can evaluate it (the extension has no StartStopActionResolver
/// and only sees the app-group ProfileSnapshot).
///
/// Ordering mirrors the app's stopSessionFromBackground: session-match →
/// disableBackgroundStops → geofence → canStop. Every caller is idempotent and
/// depends on NO DeviceActivity callback firing (see the #260 verdict).
public enum BackgroundStopPolicy {

  /// Which background channel is requesting the stop.
  public enum Channel: Equatable {
    /// Siri/Shortcuts (app process). canStop == manual (#261, Option A).
    case shortcut
    /// A scheduled stop firing in the extension (#206/#239). canStop == schedule.
    case schedule
    /// A scheduled START force-ending a DIFFERENT profile's session (#236).
    /// The victim is evaluated as a manual-equivalent stop. canStop == manual.
    case takeover
  }

  /// The caller's geofence determination. The app supplies a real result; the
  /// extension cannot evaluate location, so it supplies `.unavailable` when a rule
  /// exists (fail-closed) or `.noRule`. Per MDR-3, the `.schedule` channel supplies
  /// `.noRule` regardless (a scheduled stop is time-authoritative, not location-gated).
  public enum GeofenceState: Equatable {
    case noRule
    case satisfied
    case notSatisfied(reason: String)
    case unavailable
  }

  public enum Denial: Equatable {
    case noMatchingSession
    case backgroundStopsDisabled
    case geofenceNotSatisfied(reason: String)
    case geofenceUnavailable
    case stopConditionNotMet(reason: String)
  }

  public enum Decision: Equatable {
    case allowed
    case denied(Denial)
  }

  public static func evaluate(
    channel: Channel,
    sessionMatchesProfile: Bool,
    disableBackgroundStops: Bool,
    geofence: GeofenceState,
    stopConditions: ProfileStopConditions?
  ) -> Decision {
    // 1. Session identity: never act on a session that isn't the one in question.
    guard sessionMatchesProfile else { return .denied(.noMatchingSession) }

    // 2. The explicit safeguard.
    if disableBackgroundStops { return .denied(.backgroundStopsDisabled) }

    // 3. Geofence (fail-closed). `.schedule` callers pass `.noRule` per MDR-3.
    switch geofence {
    case .noRule, .satisfied: break
    case .notSatisfied(let reason): return .denied(.geofenceNotSatisfied(reason: reason))
    case .unavailable: return .denied(.geofenceUnavailable)
    }

    // 4. canStop — the profile's configured stop conditions, single-sourced on
    //    ProfileStopConditions (canStop(.manual) == conditions.manual;
    //    canStop(.schedule) == conditions.schedule). nil conditions fail closed.
    let conditions = stopConditions ?? ProfileStopConditions()
    switch channel {
    case .shortcut, .takeover:
      guard conditions.manual else {
        return .denied(.stopConditionNotMet(
          reason: "This profile can only be stopped with its configured stop method."))
      }
    case .schedule:
      guard conditions.schedule else {
        return .denied(.stopConditionNotMet(
          reason: "This profile is not configured to stop on a schedule."))
      }
    }

    return .allowed
  }
}
```

- [ ] **Step 4: Run to verify policy tests pass.**

Run: `xcodebuild test … -only-testing:FoqosTests/BackgroundStopPolicyTests`
Expected: PASS (all).

- [ ] **Step 5: Write the failing identity-gated-end test.** Append to `FoqosTests/BackgroundStopPolicyTests.swift` a second class (same file), or create `FoqosTests/SharedDataScheduledEndTests.swift`:

```swift
import FoqosShared
import XCTest

final class SharedDataScheduledEndTests: XCTestCase {
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "SharedDataScheduledEndTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
  }

  override func tearDown() {
    UserDefaults().removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  // The extension must not end a session that was swapped out from under it.
  func testGivenSwappedSession_WhenEndByExpectedId_ThenNoOpAndReturnsFalse() {
    SharedData.createSessionForScheduler(for: UUID())  // session A (fresh id)
    let staleId = "some-other-id"

    let didEnd = SharedData.endActiveSharedSession(expectedSessionId: staleId)

    XCTAssertFalse(didEnd, "no-op returns false so the caller skips deactivateRestrictions (F1)")
    XCTAssertNotNil(
      SharedData.getActiveSharedSession(),
      "ending with a non-matching id is a no-op (extension TOCTOU guard)")
  }

  func testGivenMatchingSession_WhenEndByExpectedId_ThenEndedAndReturnsTrue() {
    SharedData.createSessionForScheduler(for: UUID())
    let id = SharedData.getActiveSharedSession()!.id

    let didEnd = SharedData.endActiveSharedSession(expectedSessionId: id)

    XCTAssertTrue(didEnd, "matching id reports it ended")
    XCTAssertNil(SharedData.getActiveSharedSession(), "matching id ends the session")
  }

  // Atomic takeover (Task 6 / #236): a DIFFERENT session that appeared in the eval gap
  // must NOT be clobbered by the scheduler start.
  func testGivenDifferentSessionAppeared_WhenTakingOver_ThenAborts() {
    let victimId = UUID()
    SharedData.createActiveSharedSession(for: SharedData.SessionSnapshot(
      id: "victim-A", tag: "t", blockedProfileId: victimId, startTime: .distantPast,
      forceStarted: false))
    // The victim we evaluated was "stale-victim", but "victim-A" is what's actually active now.
    let started = SharedData.startSchedulerSessionTakingOver(
      profileId: UUID(), expectedVictimId: "stale-victim")

    XCTAssertFalse(started, "a newer/different session aborts the takeover (F2)")
    XCTAssertEqual(
      SharedData.getActiveSharedSession()?.id, "victim-A", "the active session is untouched")
  }

  func testGivenExpectedVictimActive_WhenTakingOver_ThenReplacedAndVictimCompleted() {
    let victimId = UUID()
    SharedData.createActiveSharedSession(for: SharedData.SessionSnapshot(
      id: "victim-A", tag: "t", blockedProfileId: victimId, startTime: .distantPast,
      forceStarted: false))
    let newProfile = UUID()

    let started = SharedData.startSchedulerSessionTakingOver(
      profileId: newProfile, expectedVictimId: "victim-A")

    XCTAssertTrue(started)
    XCTAssertEqual(
      SharedData.getActiveSharedSession()?.blockedProfileId, newProfile, "scheduler session is active")
    XCTAssertTrue(
      SharedData.completedSessionsInScheduler.contains { $0.id == "victim-A" },
      "the displaced victim is moved to completed, not lost")
  }

  func testGivenNoActiveSession_WhenTakingOver_ThenCreates() {
    let newProfile = UUID()
    let started = SharedData.startSchedulerSessionTakingOver(
      profileId: newProfile, expectedVictimId: nil)
    XCTAssertTrue(started)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.blockedProfileId, newProfile)
  }
}
```

- [ ] **Step 6: Run to verify it fails.**

Run: `xcodebuild test … -only-testing:FoqosTests/SharedDataScheduledEndTests`
Expected: FAIL to compile — `endActiveSharedSession(expectedSessionId:)` does not exist.

- [ ] **Step 7: Add the identity-gated end.** In `SharedData.swift`, next to `endActiveSharedSession()` (`:392-401`), add the gated sibling (a single `withLock` block — do NOT call the existing method from inside it; `withLock` is non-reentrant):

```swift
  /// Identity-gated variant for the DeviceActivity extension: end the shared session
  /// ONLY if it is still the session the caller evaluated. Closes the read-then-end
  /// TOCTOU where the app swaps activeSharedSession between the extension's
  /// getActiveSharedSession() read and its end. Returns whether it actually ended, so
  /// the caller deactivates the (global) ManagedSettings store only on a real end.
  /// Idempotent; complements the in-app mutator identity-gating from D2 (un-gated there).
  @discardableResult
  public static func endActiveSharedSession(expectedSessionId: String) -> Bool {
    withLock {
      guard var existing = activeSharedSession, existing.id == expectedSessionId else { return false }
      existing.endTime = Date()
      completedSessionsInScheduler.append(existing)
      activeSharedSession = nil
      return true
    }
  }

  /// Atomic takeover for a scheduled START (#236, Task 6). In ONE withLock:
  /// - no active session          → create the scheduler session, return true
  /// - active == expectedVictimId → append victim to completed, replace it, return true
  /// - active is already this profile → return true (continue, no-op)
  /// - a DIFFERENT/newer session   → do nothing, return false (abort — do NOT clobber it)
  /// This gates the destructive write (createSessionForScheduler is otherwise un-gated),
  /// so a session that arrived after the policy read is never overwritten.
  @discardableResult
  public static func startSchedulerSessionTakingOver(
    profileId: UUID, expectedVictimId: String?
  ) -> Bool {
    withLock {
      if let current = activeSharedSession {
        if current.blockedProfileId == profileId {
          return true  // already ours
        }
        guard let victimId = expectedVictimId, current.id == victimId else {
          return false  // a different/newer session appeared — abort the takeover
        }
        var victim = current
        victim.endTime = Date()
        completedSessionsInScheduler.append(victim)
      }
      activeSharedSession = SessionSnapshot(
        id: UUID().uuidString,
        tag: profileId.uuidString,
        blockedProfileId: profileId,
        startTime: Date(),
        forceStarted: true
      )
      return true
    }
  }
```

- [ ] **Step 8: Run to verify green, then swift-format + commit.**

Run: `xcodebuild test … -only-testing:FoqosTests/BackgroundStopPolicyTests -only-testing:FoqosTests/SharedDataScheduledEndTests -only-testing:FoqosTests/SharedDataLockTests`
Expected: PASS (all; `SharedDataLockTests` confirms no lock-path regression).

```bash
swift-format --in-place --recursive .
swift-format lint --recursive .
git add Packages/FoqosShared/Sources/FoqosShared/BackgroundStopPolicy.swift \
        Packages/FoqosShared/Sources/FoqosShared/SharedData.swift \
        FoqosTests/BackgroundStopPolicyTests.swift \
        FoqosTests/SharedDataScheduledEndTests.swift
git commit -m "feat(#263/D1): pure BackgroundStopPolicy + identity-gated extension session-end

Add the single, extension-evaluable policy (session-match + disableBackgroundStops
+ fail-closed geofence + canStop) that every background stop channel routes through,
and an identity-gated endActiveSharedSession(expectedSessionId:) so the extension
cannot end a session swapped out from under it (read-then-end TOCTOU). Pure,
idempotent, no callback dependence (#260)."
```

---

## Task 3: #261 — Siri/Shortcuts stop respects `canStop` (Option A)

**Implements [MDR-0 = Option A](#mdr-0) and [MDR-1 = A route-through](#mdr-1).** If the maintainer chose MDR-1 = B, use the inline note in Step 4 instead.

**Files:**
- Modify: `Foqos/Intents/IntentError.swift` (add `.stopConditionsNotMet`)
- Modify: `Foqos/Utils/StrategyManager.swift:406-472` (`stopSessionFromBackground`)
- Modify: `FoqosTests/StrategyManagerBackgroundTests.swift` (add the #261 regression)

**Interfaces:**
- Consumes: `BackgroundStopPolicy.evaluate(...)` (Task 2); `geofenceEvaluator.evaluateGeofenceForStop(profile:context:) -> GeofenceCheckResult?` (`StrategyManager.swift:448`, async); `profile.stopConditions` (`BlockedProfiles.swift:131`).
- Produces: `IntentError.stopConditionsNotMet(reason: String)`; `stopSessionFromBackground` throws it when the policy denies on stop conditions.

- [ ] **Step 1: Add the IntentError case.** In `Foqos/Intents/IntentError.swift`, add the case (after `:9`) and its message:

```swift
  case backgroundStopsDisabled(profileName: String)
  case geofenceBlocked(reason: String)
  case stopConditionsNotMet(reason: String)   // <-- add
  case unexpected(String)
```
```swift
    case .geofenceBlocked(let reason):
      "Cannot stop — \(reason)"
    case .stopConditionsNotMet(let reason):    // <-- add
      "\(reason)"
    case .unexpected(let message):
      "\(message)"
```

- [ ] **Step 2: Write the failing #261 regression test.** Append to `FoqosTests/StrategyManagerBackgroundTests.swift` (inside the existing `final class`):

```swift
  // #261 (Option A): a Shortcuts/Siri stop of an NFC-only profile must be refused,
  // just like the in-app / deep-link / NFC / QR paths refuse it.
  func testGivenNFCOnlyStopProfile_WhenStoppingFromBackground_ThenThrowsStopConditionsNotMet()
    async throws
  {
    let profile = BlockedProfiles(name: "Commitment")
    profile.disableBackgroundStops = false           // default; the bypass works without the safeguard
    profile.stopConditions = ProfileStopConditions(manual: false, anyNFC: true)
    context.insert(profile)
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)
    context.insert(session)
    try context.save()

    do {
      try await manager.stopSessionFromBackground(profile.id, context: context)
      XCTFail("Expected the NFC-only profile to refuse a background stop (#261)")
    } catch let error as IntentError {
      if case .stopConditionsNotMet = error {
      } else {
        XCTFail("Expected stopConditionsNotMet, got \(error)")
      }
    }
  }

  // Control: a manual-stop-allowed profile still stops from the background (no regression).
  func testGivenManualStopProfile_WhenStoppingFromBackground_ThenSucceeds() async throws {
    let profile = BlockedProfiles(name: "Casual")
    profile.stopConditions = ProfileStopConditions(manual: true)
    context.insert(profile)
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)
    context.insert(session)
    try context.save()

    try await manager.stopSessionFromBackground(profile.id, context: context)
    // No throw == success. (The manual strategy ends the session; ManagedSettings is a no-op in the test host.)
  }
```

- [ ] **Step 3: Run to verify it fails.**

Run: `xcodebuild test … -only-testing:FoqosTests/StrategyManagerBackgroundTests`
Expected: `testGivenNFCOnlyStopProfile…` FAILS — current `stopSessionFromBackground` never checks stop conditions, so it stops the NFC-only session and throws nothing. (`testGivenManualStopProfile…` passes on current code.)

- [ ] **Step 4: Route the decision through `BackgroundStopPolicy`.** In `Foqos/Utils/StrategyManager.swift`, replace the geofence block and the final stop call in `stopSessionFromBackground` (`:441-460` — the block from `// Check geofence rule` through `manualStrategy.stopBlocking(...)`) with a policy-driven decision. The session-match and `disableBackgroundStops` guards above it (`:417-439`) already compute the policy's first two inputs and throw their own typed errors, so keep them; feed the *geofence* and *canStop* dimensions to the policy:

```swift
      // Evaluate geofence with real location, then map to the policy's GeofenceState.
      // IMPORTANT (F5 — no behavior change): evaluateGeofenceForStop returns nil ONLY when the
      // profile has no geofence stop rule (GeofenceEvaluator.swift:44-48); when a rule EXISTS but
      // location can't be determined it returns .failed(...) (GeofenceEvaluator.swift:50-55) — so
      // the app path is ALREADY fail-closed. This mapping preserves current stopSessionFromBackground
      // behavior exactly (nil → allowed because no rule; .failed → denied). Do NOT add an
      // `.unavailable` branch here — nil never co-occurs with a rule in this evaluator.
      let geofenceResult = await geofenceEvaluator.evaluateGeofenceForStop(
        profile: profile,
        context: context
      )
      let geofenceState: BackgroundStopPolicy.GeofenceState
      if let geofenceResult {
        geofenceState =
          geofenceResult.isSatisfied
          ? .satisfied
          : .notSatisfied(reason: geofenceResult.failureMessage ?? "Location restriction not met.")
      } else {
        geofenceState = .noRule
      }

      // Single shared policy: Shortcuts/Siri is the `.shortcut` channel (canStop == manual).
      // session-match and disableBackgroundStops were already validated above and threw typed
      // errors; pass their now-known values so the policy is the one decision authority.
      let decision = BackgroundStopPolicy.evaluate(
        channel: .shortcut,
        sessionMatchesProfile: true,
        disableBackgroundStops: false,  // already handled above (would have thrown)
        geofence: geofenceState,
        stopConditions: profile.stopConditions
      )

      // NOTE: each `.denied` sub-case is its own arm — Swift forbids a `let` binding that
      // is not present in every pattern of a multi-pattern `case`, so geofenceNotSatisfied
      // and geofenceUnavailable cannot share one arm.
      switch decision {
      case .allowed:
        break
      case .denied(.geofenceNotSatisfied(let reason)):
        Log.info(
          "Geofence blocked background stop for profile: \(profile.name) — \(reason)",
          category: .strategy)
        geofenceEvaluator.postGeofenceBlockedNotification(
          profileId: profile.id, profileName: profile.name, reason: reason)
        self.errorMessage = "Cannot stop — \(reason)"
        throw IntentError.geofenceBlocked(reason: reason)
      case .denied(.geofenceUnavailable):
        let reason = "Your location can't be confirmed right now."
        Log.info(
          "Geofence blocked background stop for profile: \(profile.name) — \(reason)",
          category: .strategy)
        geofenceEvaluator.postGeofenceBlockedNotification(
          profileId: profile.id, profileName: profile.name, reason: reason)
        self.errorMessage = "Cannot stop — \(reason)"
        throw IntentError.geofenceBlocked(reason: reason)
      case .denied(.stopConditionNotMet(let reason)):
        Log.info(
          "Background stop refused for profile: \(profile.name) — stop conditions not met",
          category: .strategy)
        self.errorMessage = reason
        throw IntentError.stopConditionsNotMet(reason: reason)
      case .denied(.backgroundStopsDisabled), .denied(.noMatchingSession):
        // Unreachable — handled by the typed guards above; treat defensively as a refusal.
        self.errorMessage = "\(profile.name) cannot be stopped in the background."
        throw IntentError.backgroundStopsDisabled(profileName: profile.name)
      }

      let _ = manualStrategy.stopBlocking(
        context: context,
        session: localActiveSession
      )
```

> **MDR-1 = B fallback (if the maintainer chose "inline"):** keep the existing geofence block verbatim and insert *only* this, immediately before `manualStrategy.stopBlocking(...)`:
> ```swift
>       let stopValidation = StartStopActionResolver.canStop(
>         with: .manual, conditions: profile.stopConditions,
>         sessionTag: localActiveSession.tag,
>         stopNFCTagId: profile.stopNFCTagId, stopQRCodeId: profile.stopQRCodeId)
>       guard stopValidation.allowed else {
>         let reason = stopValidation.errorMessage ?? "This profile cannot be stopped from the background."
>         self.errorMessage = reason
>         throw IntentError.stopConditionsNotMet(reason: reason)
>       }
> ```

- [ ] **Step 5: Run to verify green.**

Run: `xcodebuild test … -only-testing:FoqosTests/StrategyManagerBackgroundTests`
Expected: PASS (all, including the two new tests and the pre-existing background-stop tests — session-match, no-active-session, disableBackgroundStops still throw their original errors).

- [ ] **Step 6: Copy audit (#261 rider — verification only, likely no change).** Under Option A the three previously-overstating strings become **true**. Confirm they now read accurately (do NOT change unless inaccurate):
  - `StartStopActionResolver.swift:105` — "This profile can only be stopped when the timer runs out" (now true: Shortcuts is gated).
  - `Foqos/Components/BlockedProfileView/StopConditionSelector.swift` (the `requiresPhysicalItemOnly` warning "Emergency Unblock … will be your only way to stop this profile") — now true.
  - `Packages/FoqosShared/Sources/FoqosShared/ProfileStopConditions.swift` `requiresPhysicalItemOnly` doc comment — now true.
  Record in the commit message that the audit found them accurate (or list any wording fix made).

- [ ] **Step 7: swift-format + commit.**

```bash
swift-format --in-place --recursive .
swift-format lint --recursive .
git add Foqos/Intents/IntentError.swift Foqos/Utils/StrategyManager.swift \
        FoqosTests/StrategyManagerBackgroundTests.swift
git commit -m "fix(#261): Siri/Shortcuts stop respects the profile's stop conditions (Option A)

stopSessionFromBackground never validated stop conditions, so 'Hey Siri, stop
<profile>' ended an NFC/QR/timer-only commitment profile with zero friction — the
one background channel every in-app path refuses. Route the decision through the
shared BackgroundStopPolicy (.shortcut channel, canStop == manual); throw
IntentError.stopConditionsNotMet on refusal so StopProfileIntent surfaces a clear
error, never a silent no-op. Copy audit: the three 'only way to stop' strings are
now accurate. MAINTAINER DECISION: #261 Option A (settled 2026-07-05)."
```

---

## Task 4: #239 — scheduled stop respects `disableBackgroundStops` (+ the shared policy)

**Files:**
- Modify: `Packages/FoqosShared/Sources/FoqosShared/Timers/StopScheduleTimerActivity.swift:22-47` (`stop`)
- Create/extend: `FoqosTests/ScheduleTimerActivityTests.swift`

**Interfaces:**
- Consumes: `BackgroundStopPolicy.evaluate(...)` (Task 2); `SharedData.getActiveSharedSession()`; `SharedData.endActiveSharedSession(expectedSessionId:)` (Task 2); `snapshot.disableBackgroundStops`, `snapshot.stopConditions`, `snapshot.stopSchedule` (Task 1).

**Context / current offending code (`StopScheduleTimerActivity.swift:22-47`):** checks session-match + `isTodayScheduled` then unconditionally `deactivateRestrictions()` + `endActiveSharedSession()`. Ignores `disableBackgroundStops` (#239) and does not consult stop conditions. Per **MDR-3 = A**, the `.schedule` channel passes `geofence: .noRule`.

- [ ] **Step 1: Write the failing test.** Create (or append to) `FoqosTests/ScheduleTimerActivityTests.swift`:

```swift
import FoqosShared
import XCTest

final class ScheduleTimerActivityTests: XCTestCase {
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "ScheduleTimerActivityTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
  }

  override func tearDown() {
    UserDefaults().removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  private func snapshot(
    id: UUID,
    disableBackgroundStops: Bool = false,
    stopConditions: ProfileStopConditions = ProfileStopConditions(schedule: true),
    stopSchedule: ProfileScheduleTime? = ProfileScheduleTime(
      days: Weekday.allCases, hour: 17, minute: 0, updatedAt: .distantPast)
  ) -> SharedData.ProfileSnapshot {
    SharedData.ProfileSnapshot(
      id: id, name: "P", selectedActivity: .init(), createdAt: .distantPast,
      updatedAt: .distantPast, order: 0, enableLiveActivity: false, enableBreaks: false,
      enableStrictMode: false, enableAllowMode: false, enableAllowModeDomains: false,
      enableSafariBlocking: false, stopSchedule: stopSchedule,
      disableBackgroundStops: disableBackgroundStops, stopConditions: stopConditions)
  }

  // #239: a scheduled stop must NOT lift restrictions when disableBackgroundStops is on.
  func testGivenBackgroundStopsDisabled_WhenStopScheduleFires_ThenSessionSurvives() {
    let id = UUID()
    SharedData.createSessionForScheduler(for: id)  // active session for this profile
    let snap = snapshot(id: id, disableBackgroundStops: true)

    StopScheduleTimerActivity().stop(for: snap)

    XCTAssertNotNil(
      SharedData.getActiveSharedSession(),
      "disableBackgroundStops must block the scheduled stop (#239)")
  }

  // Control: with the safeguard off and schedule stop enabled, the scheduled stop ends the session.
  func testGivenScheduleStopEnabled_WhenStopScheduleFires_ThenSessionEnds() {
    let id = UUID()
    SharedData.createSessionForScheduler(for: id)
    let snap = snapshot(id: id, disableBackgroundStops: false)

    StopScheduleTimerActivity().stop(for: snap)

    XCTAssertNil(SharedData.getActiveSharedSession(), "scheduled stop ends the session normally")
  }

  // Guard: a session for a DIFFERENT profile is never ended by this profile's stop schedule.
  func testGivenDifferentProfileSession_WhenStopScheduleFires_ThenNoOp() {
    SharedData.createSessionForScheduler(for: UUID())  // some other profile
    let snap = snapshot(id: UUID())

    StopScheduleTimerActivity().stop(for: snap)

    XCTAssertNotNil(SharedData.getActiveSharedSession(), "unrelated session untouched")
  }
}
```

- [ ] **Step 2: Run to verify it fails.**

Run: `xcodebuild test … -only-testing:FoqosTests/ScheduleTimerActivityTests`
Expected: `testGivenBackgroundStopsDisabled…` FAILS — current `stop` ignores `disableBackgroundStops` and ends the session.

- [ ] **Step 3: Route `stop` through the policy.** Replace the body of `StopScheduleTimerActivity.stop(for:)` (`:22-47`):

```swift
  public func stop(for profile: SharedData.ProfileSnapshot) {
    let profileId = profile.id.uuidString

    guard let activeSession = SharedData.getActiveSharedSession() else {
      Log.info("Stop schedule timer for \(profileId), no active session found", category: .timer)
      return
    }

    // Check if today is a scheduled stop day (unchanged).
    if let stopSchedule = profile.stopSchedule, !stopSchedule.isTodayScheduled() {
      Log.info("Stop schedule timer for \(profileId), not scheduled for today", category: .timer)
      return
    }

    // Shared background-stop policy: the .schedule channel. session-match +
    // disableBackgroundStops + canStop(.schedule). Geofence omitted for scheduled
    // stops (time-authoritative; MDR-3 = A). Idempotent; no callback dependence (#260).
    let decision = BackgroundStopPolicy.evaluate(
      channel: .schedule,
      sessionMatchesProfile: activeSession.blockedProfileId == profile.id,
      disableBackgroundStops: profile.disableBackgroundStops ?? false,
      geofence: .noRule,
      stopConditions: profile.stopConditions
    )
    guard case .allowed = decision else {
      Log.info(
        "Stop schedule timer for \(profileId) refused by background-stop policy: \(decision)",
        category: .timer)
      return
    }

    Log.info("Stop schedule timer firing for \(profileId), ending session", category: .timer)
    // End FIRST (identity-gated), then deactivate the GLOBAL ManagedSettings store only if the
    // end actually fired. deactivateRestrictions() is unconditional + profile-agnostic
    // (AppBlockerUtil.clearAllSettings), so deactivating before a no-op end would wipe a
    // DIFFERENT session's restrictions if the app swapped sessions in the eval gap (F1).
    if SharedData.endActiveSharedSession(expectedSessionId: activeSession.id) {
      appBlocker.deactivateRestrictions()
    }
  }
```

- [ ] **Step 4: Run to verify green.**

Run: `xcodebuild test … -only-testing:FoqosTests/ScheduleTimerActivityTests`
Expected: PASS (all three).

- [ ] **Step 5: swift-format + commit.**

```bash
swift-format --in-place --recursive .
swift-format lint --recursive .
git add Packages/FoqosShared/Sources/FoqosShared/Timers/StopScheduleTimerActivity.swift \
        FoqosTests/ScheduleTimerActivityTests.swift
git commit -m "fix(#239): scheduled stop respects disableBackgroundStops via shared policy

StopScheduleTimerActivity.stop lifted restrictions and ended the session with no
disableBackgroundStops check, contradicting the deep-link/Shortcuts paths. Route
it through BackgroundStopPolicy (.schedule channel) and end via the identity-gated
endActiveSharedSession(expectedSessionId:). Geofence omitted for scheduled stops
(MDR-3). Idempotent under duplicate/dropped callbacks (#260)."
```

---

## Task 5: #206 — scheduled stop only ends a scheduler-legitimate session

**Implements [MDR-4 = A](#mdr-4) (extension-side guard is primary).**

**Files:**
- Modify: `Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift:88-110` (`stop`)
- Extend: `FoqosTests/ScheduleTimerActivityTests.swift`

**Context / current offending code (`ScheduleTimerActivity.swift:88-110`):** ends the session on profile-id match with **no** `isTodayScheduled`, **no** `stopConditions.schedule`, **no** session-origin check. The scheduler synthesizes a daily `intervalEnd = start − 1 min` for manual-only-stop profiles (`DeviceActivityCenterUtil.swift:46-53`, `repeats: true`), so this fires **every day** and silently ends manually-started sessions (the Saturday-manual-start-on-a-Mon-Fri-profile scenario). The guard rejects when the profile does not actually stop on a schedule, when today is not a scheduled day, or when the session was not scheduler-started.

> **Session-origin note:** scheduler-started sessions have `tag == profileId` (`SharedData.createSessionForScheduler`, `:374`). A manually-started session on a profile whose stop conditions include `schedule` legitimately stops on schedule (the user opted in), so the guard allows the scheduled stop when `stopConditions.schedule` is true **regardless of origin**, and additionally allows a scheduler-started session; it rejects only the #206 case (manual-only-stop profile, synthetic interval).

- [ ] **Step 1: Write the failing tests.** Append to `FoqosTests/ScheduleTimerActivityTests.swift`:

```swift
  private func startScheduledSnapshot(
    id: UUID,
    stopConditions: ProfileStopConditions,
    stopSchedule: ProfileScheduleTime? = nil
  ) -> SharedData.ProfileSnapshot {
    SharedData.ProfileSnapshot(
      id: id, name: "P", selectedActivity: .init(), createdAt: .distantPast,
      updatedAt: .distantPast, order: 0, enableLiveActivity: false, enableBreaks: false,
      enableStrictMode: false, enableAllowMode: false, enableAllowModeDomains: false,
      enableSafariBlocking: false, stopSchedule: stopSchedule,
      disableBackgroundStops: false, stopConditions: stopConditions)
  }

  // #206: a manual-only-stop profile's synthetic daily intervalDidEnd must NOT end a
  // (manually started) session.
  func testGivenManualOnlyStopProfile_WhenScheduleStopFires_ThenSessionSurvives() {
    let id = UUID()
    SharedData.createActiveSharedSession(for: SharedData.SessionSnapshot(
      id: UUID().uuidString, tag: "manual", blockedProfileId: id,
      startTime: .distantPast, forceStarted: false))  // manually started (tag != profileId)
    let snap = startScheduledSnapshot(id: id, stopConditions: ProfileStopConditions(manual: true))

    ScheduleTimerActivity().stop(for: snap)

    XCTAssertNotNil(
      SharedData.getActiveSharedSession(),
      "manual-only-stop profile must not be ended by the synthetic schedule interval (#206)")
  }

  // Control: a profile that DOES stop on schedule ends its session when the interval fires today.
  func testGivenScheduleStopProfileToday_WhenScheduleStopFires_ThenSessionEnds() {
    let id = UUID()
    SharedData.createSessionForScheduler(for: id)  // scheduler-started, tag == profileId
    let everyDayStop = ProfileScheduleTime(
      days: Weekday.allCases, hour: 17, minute: 0, updatedAt: .distantPast)
    let snap = startScheduledSnapshot(
      id: id, stopConditions: ProfileStopConditions(schedule: true), stopSchedule: everyDayStop)

    ScheduleTimerActivity().stop(for: snap)

    XCTAssertNil(SharedData.getActiveSharedSession(), "schedule-stop profile ends on its interval")
  }
```

- [ ] **Step 2: Run to verify it fails.**

Run: `xcodebuild test … -only-testing:FoqosTests/ScheduleTimerActivityTests`
Expected: `testGivenManualOnlyStopProfile…` FAILS — current `stop` ends any id-matched session.

- [ ] **Step 3: Add the guards.** Replace the body of `ScheduleTimerActivity.stop(for:)` (`:88-110`):

```swift
  public func stop(for profile: SharedData.ProfileSnapshot) {
    let profileId = profile.id.uuidString

    guard let activeSession = SharedData.getActiveSharedSession() else {
      Log.info("Stop schedule timer activity for \(profileId), no active session found", category: .timer)
      return
    }

    // Shared background-stop policy: the .schedule channel. canStop(.schedule) requires
    // stopConditions.schedule, which rejects the #206 case (manual-only-stop profile whose
    // synthetic daily interval would otherwise end a manually-started session). session-match
    // + disableBackgroundStops included; geofence omitted for scheduled stops (MDR-3).
    //
    // NOTE (F3 — do NOT add a naive isTodayScheduled() day guard): the combined DeviceActivity
    // interval is registered with hour/minute only (repeats daily), and isTodayScheduled() is
    // weekday-membership only. For an OVERNIGHT window (e.g. Fri 22:00 → Sat 06:00, days = {Fri})
    // intervalDidEnd fires Saturday 06:00, so isTodayScheduled(Saturday) would WRONGLY refuse the
    // legitimate stop and strand the session blocked all Saturday. Day-of-week precision for
    // schedule-stop profiles needs window-aware logic (ProfileScheduleTime.activeWindowStart) and
    // is a documented residual (MDR-4 follow-up) — NOT part of the #206 fix, which is fully carried
    // by canStop(.schedule). Behavior for schedule-stop profiles is unchanged from current main
    // (which also fires daily); only the manual-only bypass is closed.
    let decision = BackgroundStopPolicy.evaluate(
      channel: .schedule,
      sessionMatchesProfile: activeSession.blockedProfileId == profile.id,
      disableBackgroundStops: profile.disableBackgroundStops ?? false,
      geofence: .noRule,
      stopConditions: profile.stopConditions
    )
    guard case .allowed = decision else {
      Log.info(
        "Stop schedule timer activity for \(profileId) refused by policy: \(decision)",
        category: .timer)
      return
    }

    // End first (identity-gated); deactivate the global store only on a real end (F1 — see Task 4).
    if SharedData.endActiveSharedSession(expectedSessionId: activeSession.id) {
      appBlocker.deactivateRestrictions()
    }
  }
```

- [ ] **Step 4: Run to verify green.**

Run: `xcodebuild test … -only-testing:FoqosTests/ScheduleTimerActivityTests`
Expected: PASS (all).

- [ ] **Step 5: swift-format + commit.**

```bash
swift-format --in-place --recursive .
swift-format lint --recursive .
git add Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift \
        FoqosTests/ScheduleTimerActivityTests.swift
git commit -m "fix(#206): scheduled stop only ends a schedule-legitimate session

ScheduleTimerActivity.stop ended any profile-id-matched session with no
isTodayScheduled or stop-condition check, so the synthetic daily intervalDidEnd
(start-1min, registered for manual-only-stop profiles) silently ended manually
started sessions on non-scheduled days. Route through BackgroundStopPolicy
(.schedule channel: canStop(.schedule) requires stopConditions.schedule) plus the
today-scheduled guard; end via the identity-gated primitive. MDR-4 = extension
guard. Idempotent (#260)."
```

---

## Task 6: #236 — scheduled start must not force-end a protected session

**Implements [MDR-5 = A](#mdr-5) (skip the takeover; keep the victim).**

**Files:**
- Modify: `Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift:74-86` (the takeover branch of `start`)
- Extend: `FoqosTests/ScheduleTimerActivityTests.swift`

**Context / current offending code (`ScheduleTimerActivity.swift:74-86`):** when a *different* profile's session is active, `start` calls `SharedData.endActiveSharedSession()` and takes over — no `disableBackgroundStops`/stop-condition/geofence check on the victim (#236). The victim snapshot is needed to evaluate the policy, but `start` only holds the *incoming* profile's snapshot. **The victim's snapshot is fetched from `SharedData.snapshot(for: victim.blockedProfileId)`** — available in-process.

- [ ] **Step 1: Write the failing test.** Append to `FoqosTests/ScheduleTimerActivityTests.swift`:

```swift
  // #236: a scheduled start must NOT force-end a victim session whose profile forbids
  // background stops (or is a non-manual commitment).
  func testGivenProtectedVictim_WhenScheduledStartTakesOver_ThenVictimSurvives() throws {
    // Victim: a strict profile, active, that cannot be stopped in the background.
    let victimId = UUID()
    SharedData.createActiveSharedSession(for: SharedData.SessionSnapshot(
      id: UUID().uuidString, tag: "nfc:abc", blockedProfileId: victimId,
      startTime: .distantPast, forceStarted: false))
    SharedData.setSnapshot(
      startScheduledSnapshot(id: victimId, stopConditions: ProfileStopConditions(anyNFC: true)),
      for: victimId.uuidString)

    // Incoming scheduled profile B, scheduled to start now (every day, 1+ min old).
    let incomingId = UUID()
    let startNow = ProfileScheduleTime(
      days: Weekday.allCases, hour: Calendar.current.component(.hour, from: Date()),
      minute: Calendar.current.component(.minute, from: Date()), updatedAt: .distantPast)
    var incoming = startScheduledSnapshot(
      id: incomingId, stopConditions: ProfileStopConditions(schedule: true))
    incoming.startSchedule = startNow
    incoming.startTriggersSchedule = true

    ScheduleTimerActivity().start(for: incoming)

    XCTAssertEqual(
      SharedData.getActiveSharedSession()?.blockedProfileId, victimId,
      "the protected victim session must survive; the scheduled takeover is skipped (#236)")
  }
```

> **Note on the start-schedule guard:** `start` early-returns unless `shouldBeActiveNow` (V2) passes; the test sets `startSchedule` to the current hour/minute with `updatedAt: .distantPast` so `olderThanOneMinute` passes and the window is active. If clock-edge flakiness is a concern, the reviewer may inject a fixed `now:` — but `ScheduleTimerActivity.start` does not currently take a `now:` parameter; adding one is out of D1 scope, so this test relies on the always-active every-day window. (It never calls `Date()` for an assertion; the assertion is on session identity.)

- [ ] **Step 2: Run to verify it fails.**

Run: `xcodebuild test … -only-testing:FoqosTests/ScheduleTimerActivityTests`
Expected: `testGivenProtectedVictim…` FAILS — current takeover ends the victim unconditionally.

- [ ] **Step 3: Add the takeover guard.** In `ScheduleTimerActivity.start`, replace the else branch of the active-session check (`:78-81`):

```swift
    let existingSession = SharedData.getActiveSharedSession()
    if let existingSession, existingSession.blockedProfileId == profile.id {
      Log.info("Start schedule timer for \(profileId), continuing active session", category: .timer)
      return
    }
    if let existingSession {
      // #236: evaluate the VICTIM against the shared policy before force-ending it. A scheduled
      // start is a background actor; treat the takeover as a manual-equivalent stop of the victim
      // (.takeover channel). If the victim forbids background stops, is a non-manual commitment,
      // or is geofence-locked (F4: fail-closed, consistent with the Shortcuts channel), SKIP the
      // takeover (MDR-5 = A): keep the victim, do not start this profile this window.
      let victimSnapshot = SharedData.snapshot(for: existingSession.blockedProfileId.uuidString)
      let victimGeofence: BackgroundStopPolicy.GeofenceState =
        (victimSnapshot?.geofenceRule?.hasLocations == true) ? .unavailable : .noRule
      let decision = BackgroundStopPolicy.evaluate(
        channel: .takeover,
        sessionMatchesProfile: true,
        disableBackgroundStops: victimSnapshot?.disableBackgroundStops ?? false,
        geofence: victimGeofence,
        stopConditions: victimSnapshot?.stopConditions
      )
      guard case .allowed = decision else {
        Log.info(
          "Start schedule timer for \(profileId), NOT taking over protected session for "
            + "\(existingSession.blockedProfileId.uuidString): \(decision)",
          category: .timer)
        return
      }
    }

    // Atomic takeover (F2): create the scheduler session ONLY if the active session still matches
    // what we evaluated (the victim we approved, or none). If a different/newer session appeared in
    // the eval gap, this aborts and returns false — the un-gated createSessionForScheduler would
    // otherwise clobber it (losing it entirely, not even moved to completed).
    guard SharedData.startSchedulerSessionTakingOver(
      profileId: profile.id, expectedVictimId: existingSession?.id)
    else {
      Log.info(
        "Start schedule timer for \(profileId), aborting takeover — active session changed under us",
        category: .timer)
      return
    }
    appBlocker.activateRestrictions(for: profile)
```

> **Geofence (F4, resolved):** the extension cannot evaluate the victim's location, so a geofence-locked victim (which may be un-stoppable right now because the user is away from the allowed zone) is treated **fail-closed** — `geofence: .unavailable` when `victimSnapshot.geofenceRule?.hasLocations == true`. This keeps the takeover channel consistent with the Shortcuts channel (both refuse to background-stop a geofenced profile whose location can't be confirmed) and prevents a scheduled start from silently bypassing a victim's location lock. Cost: a geofenced profile is never taken over by another profile's schedule — it simply keeps blocking, and the scheduled profile does not start this window (MDR-5 = A skip). This is the safe default; confirm under [MDR-3](#mdr-3).

- [ ] **Step 4: Run to verify green.**

Run: `xcodebuild test … -only-testing:FoqosTests/ScheduleTimerActivityTests`
Expected: PASS (all).

- [ ] **Step 5: swift-format + commit.**

```bash
swift-format --in-place --recursive .
swift-format lint --recursive .
git add Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift \
        FoqosTests/ScheduleTimerActivityTests.swift
git commit -m "fix(#236): scheduled start must not force-end a protected session

ScheduleTimerActivity.start force-ended a different profile's active session with no
guard, defeating disableBackgroundStops / NFC-lock in the background. Evaluate the
victim via BackgroundStopPolicy (.takeover channel) from its own snapshot; if it
forbids background stops or is a non-manual commitment, skip the takeover and keep
the victim (MDR-5 = A). End via the identity-gated primitive. Idempotent (#260)."
```

---

## Task 7: #229 — legacy schedule branch honors `scheduleLastStoppedAt`

**Files:**
- Modify: `Packages/FoqosShared/Sources/FoqosShared/Schedule.swift` (add `BlockedProfileSchedule.windowStart(on:calendar:)`)
- Modify: `Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift:58-70` (legacy branch of `start`)
- Extend: `FoqosTests/ScheduleTimerActivityTests.swift`

**Context / current offending code (`ScheduleTimerActivity.swift:58-70`):** the legacy branch (`else if let schedule = profile.schedule`) checks only `isTodayScheduled()` + `olderThanOneMinute()`; it never consults `scheduleLastStoppedAt`, so a foreground re-registration (`PreActivationReminderScheduler.rescheduleAllReminders` → `scheduleTimerActivity` → stop+start) restarts a manually-stopped legacy session (#229). The V2 branch already suppresses via `shouldBeActiveNow` step 4. Add the equivalent to the legacy branch: suppress when `scheduleLastStoppedAt >= today's legacy window start`.

- [ ] **Step 1: Write the failing pure-helper test.** Append to `FoqosTests/ScheduleTimerActivityTests.swift` (or a new pure test class — this helper is pure):

```swift
  // #229: legacy window-start computation (today at startHour:startMinute).
  func testGivenLegacySchedule_WhenComputingWindowStart_ThenTodayAtStartTime() {
    let cal = Calendar(identifier: .gregorian)
    var c = DateComponents()
    c.year = 2026; c.month = 6; c.day = 15; c.hour = 12; c.minute = 0
    let now = cal.date(from: c)!
    let schedule = BlockedProfileSchedule(
      days: Weekday.allCases, startHour: 9, startMinute: 0, endHour: 17, endMinute: 0,
      updatedAt: .distantPast)

    let windowStart = schedule.windowStart(on: now, calendar: cal)

    var expected = DateComponents()
    expected.year = 2026; expected.month = 6; expected.day = 15; expected.hour = 9; expected.minute = 0
    XCTAssertEqual(windowStart, cal.date(from: expected))
  }
```

- [ ] **Step 2: Run to verify it fails (compile error — helper missing).**

Run: `xcodebuild test … -only-testing:FoqosTests/ScheduleTimerActivityTests`
Expected: FAIL to compile — `windowStart(on:calendar:)` does not exist.

- [ ] **Step 3: Add the pure helper.** In `Schedule.swift`, add to `BlockedProfileSchedule` (after `olderThanOneMinute`, `:124`):

```swift
  /// The start Date of today's legacy schedule window (today at startHour:startMinute).
  /// Used by the extension's legacy start branch to suppress a window the user already
  /// dismissed (compare against scheduleLastStoppedAt). Mirrors ProfileScheduleTime's
  /// window logic for the V1 combined-schedule shape.
  public func windowStart(on date: Date = Date(), calendar: Calendar = .current) -> Date? {
    var components = calendar.dateComponents([.year, .month, .day], from: date)
    components.hour = startHour
    components.minute = startMinute
    components.second = 0
    return calendar.date(from: components)
  }
```

- [ ] **Step 4: Write the failing suppression test (extension behavior).** Append to `FoqosTests/ScheduleTimerActivityTests.swift`:

```swift
  // #229: a manually-stopped legacy session must not be restarted by re-registration.
  func testGivenLegacyStoppedThisWindow_WhenStartFires_ThenSuppressed() {
    let id = UUID()
    // Legacy schedule 09:00-17:00 every day; stopped today at 10:05 (> window start 09:00).
    let cal = Calendar.current
    var c = cal.dateComponents([.year, .month, .day], from: Date())
    c.hour = 10; c.minute = 5
    let stoppedAt = cal.date(from: c)!
    var snap = SharedData.ProfileSnapshot(
      id: id, name: "Legacy", selectedActivity: .init(), createdAt: .distantPast,
      updatedAt: .distantPast, order: 0, enableLiveActivity: false, enableBreaks: false,
      enableStrictMode: false, enableAllowMode: false, enableAllowModeDomains: false,
      enableSafariBlocking: false,
      schedule: BlockedProfileSchedule(
        days: Weekday.allCases, startHour: 9, startMinute: 0, endHour: 17, endMinute: 0,
        updatedAt: .distantPast),
      disableBackgroundStops: false, stopConditions: ProfileStopConditions(manual: true),
      scheduleLastStoppedAt: stoppedAt)
    snap.startTriggersSchedule = false  // force the legacy branch

    ScheduleTimerActivity().start(for: snap)

    XCTAssertNil(
      SharedData.getActiveSharedSession(),
      "legacy branch must suppress a window already stopped this window (#229)")
  }
```

- [ ] **Step 5: Run to verify it fails.**

Run: `xcodebuild test … -only-testing:FoqosTests/ScheduleTimerActivityTests`
Expected: `testGivenLegacyStoppedThisWindow…` FAILS — legacy branch ignores `scheduleLastStoppedAt`, so it creates a session.

- [ ] **Step 6: Add the suppression to the legacy branch.** In `ScheduleTimerActivity.start`, extend the legacy `else if` branch (`:58-66`) — after the `olderThanOneMinute()` guard, before falling through to session creation:

```swift
    } else if let schedule = profile.schedule {
      guard schedule.isTodayScheduled() else {
        Log.info("Start schedule timer activity for \(profileId), not scheduled for today", category: .timer)
        return
      }
      guard schedule.olderThanOneMinute() else {
        Log.info("Start schedule timer activity for \(profileId), schedule is too new", category: .timer)
        return
      }
      // #229: honor manual-stop suppression on the legacy path too (the V2 path does this via
      // shouldBeActiveNow). Suppress if this window's start is at/before the last stop.
      if let stoppedAt = profile.scheduleLastStoppedAt,
        let windowStart = schedule.windowStart(),
        windowStart <= stoppedAt
      {
        Log.info(
          "Start schedule timer activity for \(profileId), window already stopped — suppressing (#229)",
          category: .timer)
        return
      }
    } else {
```

- [ ] **Step 7: Run to verify green.**

Run: `xcodebuild test … -only-testing:FoqosTests/ScheduleTimerActivityTests -only-testing:FoqosTests/ScheduleSuppressionTests`
Expected: PASS (all; `ScheduleSuppressionTests` confirms the V2 path is untouched).

- [ ] **Step 8: swift-format + commit.**

```bash
swift-format --in-place --recursive .
swift-format lint --recursive .
git add Packages/FoqosShared/Sources/FoqosShared/Schedule.swift \
        Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift \
        FoqosTests/ScheduleTimerActivityTests.swift
git commit -m "fix(#229): legacy schedule branch honors scheduleLastStoppedAt

The legacy start branch checked only isTodayScheduled + olderThanOneMinute, so a
foreground re-registration restarted a manually-stopped legacy session. Add a pure
BlockedProfileSchedule.windowStart helper and suppress when the window start is
at/before scheduleLastStoppedAt — the same suppression the V2 shouldBeActiveNow
path already applies."
```

---

## Task 8: #243 — merge the extension's `scheduleLastStoppedAt` into SwiftData before catch-up

**Files:**
- Modify: `Foqos/Utils/PreActivationReminderScheduler.swift` (add `mergeExtensionScheduleSuppression(context:)`)
- Modify: `Foqos/FoqosApp.swift:159,257` (call it before `rescheduleAllReminders`)
- Create: `FoqosTests/ScheduleSuppressionMergeTests.swift`

**Interfaces:**
- Consumes: `SharedData.snapshot(for:)?.scheduleLastStoppedAt`; `BlockedProfiles.fetchProfiles(in:)`; `profile.scheduleLastStoppedAt`.
- Produces: `static func mergeExtensionScheduleSuppression(context: ModelContext)` — for each profile, `profile.scheduleLastStoppedAt = max(swiftData, snapshot)`; saves once.

**Context (data-flow table above):** the extension writes `scheduleLastStoppedAt` into the snapshot only; the app's `catchUpMissedScheduleStarts` reads the **SwiftData** value and would restart the just-ended session, and the next `updateSnapshot` clobbers the extension's write. Merging snapshot→SwiftData first makes the extension's write authoritative and immunizes it from the clobber.

- [ ] **Step 1: Write the failing test.** Create `FoqosTests/ScheduleSuppressionMergeTests.swift`:

```swift
import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class ScheduleSuppressionMergeTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!
  private var suiteName: String!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "ScheduleSuppressionMergeTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    container = try TestModelContainer.create()
    context = container.mainContext
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  // #243: the extension's snapshot-only lastStoppedAt must be merged into SwiftData
  // (taking the max) so foreground catch-up honors it.
  func testGivenExtensionWroteLaterStop_WhenMerging_ThenSwiftDataTakesSnapshotValue() throws {
    let now = Date()
    let earlier = now.addingTimeInterval(-3600)
    let profile = BlockedProfiles(name: "Sched")
    profile.scheduleLastStoppedAt = earlier
    context.insert(profile)
    try context.save()
    // Snapshot exists (from a prior updateSnapshot), then the extension stamped a LATER stop.
    BlockedProfiles.updateSnapshot(for: profile)
    SharedData.setLastStoppedAt(for: profile.id.uuidString, at: now)

    PreActivationReminderScheduler.mergeExtensionScheduleSuppression(context: context)

    XCTAssertEqual(
      profile.scheduleLastStoppedAt, now,
      "SwiftData adopts the extension's later stop (#243)")
  }

  // The merge never regresses a newer SwiftData value to an older snapshot value.
  func testGivenSwiftDataNewerThanSnapshot_WhenMerging_ThenSwiftDataUnchanged() throws {
    let now = Date()
    let older = now.addingTimeInterval(-3600)
    let profile = BlockedProfiles(name: "Sched")
    profile.scheduleLastStoppedAt = now
    context.insert(profile)
    try context.save()
    BlockedProfiles.updateSnapshot(for: profile)
    SharedData.setLastStoppedAt(for: profile.id.uuidString, at: older)

    PreActivationReminderScheduler.mergeExtensionScheduleSuppression(context: context)

    XCTAssertEqual(profile.scheduleLastStoppedAt, now, "max() keeps the newer SwiftData value")
  }
}
```

- [ ] **Step 2: Run to verify it fails (compile error — method missing).**

Run: `xcodebuild test … -only-testing:FoqosTests/ScheduleSuppressionMergeTests`
Expected: FAIL to compile — `mergeExtensionScheduleSuppression` does not exist.

- [ ] **Step 3: Implement the merge.** In `Foqos/Utils/PreActivationReminderScheduler.swift`, add (above `rescheduleAllReminders`):

```swift
  /// #243: the DeviceActivity extension records schedule-window suppression in the app-group
  /// snapshot only (SharedData.setLastStoppedAt) — it cannot touch SwiftData. Merge that value
  /// back into SwiftData (max of the two) BEFORE catch-up reads it and before any updateSnapshot
  /// rewrites the snapshot from SwiftData (which would clobber the extension's write).
  static func mergeExtensionScheduleSuppression(context: ModelContext) {
    do {
      let profiles = try BlockedProfiles.fetchProfiles(in: context)
      var changed = false
      for profile in profiles {
        guard
          let snapStopped = SharedData.snapshot(for: profile.id.uuidString)?.scheduleLastStoppedAt
        else { continue }
        let current = profile.scheduleLastStoppedAt
        if current == nil || snapStopped > current! {
          profile.scheduleLastStoppedAt = snapStopped
          changed = true
        }
      }
      if changed { try context.save() }
    } catch {
      Log.error(
        "Failed to merge extension schedule suppression: \(error.localizedDescription)",
        category: .timer)
    }
  }
```

- [ ] **Step 4: Run to verify green.**

Run: `xcodebuild test … -only-testing:FoqosTests/ScheduleSuppressionMergeTests`
Expected: PASS (both).

- [ ] **Step 5: Wire it before catch-up.** In `Foqos/FoqosApp.swift`, at BOTH sites where `rescheduleAllReminders`/`catchUpMissedScheduleStarts` run (`:159-160` and `:257-259`), add the merge as the FIRST call:

```swift
              PreActivationReminderScheduler.mergeExtensionScheduleSuppression(context: container.mainContext)
              PreActivationReminderScheduler.rescheduleAllReminders(context: container.mainContext)
              PreActivationReminderScheduler.catchUpMissedScheduleStarts(context: container.mainContext)
```

- [ ] **Step 6: Build to confirm the app compiles.**

Run: `xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' build 2>&1 | xcpretty`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: swift-format + commit.**

```bash
swift-format --in-place --recursive .
swift-format lint --recursive .
git add Foqos/Utils/PreActivationReminderScheduler.swift Foqos/FoqosApp.swift \
        FoqosTests/ScheduleSuppressionMergeTests.swift
git commit -m "fix(#243): merge extension scheduleLastStoppedAt into SwiftData before catch-up

The extension records schedule suppression in the app-group snapshot only; the app
never read it back, so foreground catch-up restarted the just-ended session and the
next updateSnapshot clobbered the extension's write. Merge snapshot->SwiftData
(max) as the first step on every foreground/launch, before rescheduleAllReminders
and catchUpMissedScheduleStarts."
```

---

## Final integration step (run after all tasks)

- [ ] **Full suite green.**

Run: `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty`
Expected: 0 failures. Confirm the new/edited suites are included: `ProfileSnapshotStopConditionsTests`, `BackgroundStopPolicyTests`, `SharedDataScheduledEndTests`, `StrategyManagerBackgroundTests`, `ScheduleTimerActivityTests`, `ScheduleSuppressionMergeTests`, plus the untouched `ScheduleSuppressionTests`, `ProfileStopConditionsTests`, `SharedDataLockTests`.

- [ ] **swift-format lint clean:** `swift-format lint --recursive .` → no output.

- [ ] **⚠️ MANDATORY — refresh every `file:line` citation and re-verify the stop-channel matrix against post-D2 `main` before the implementing session begins.** Every anchor in this plan is from `18904b6`; D2, C2, F, and I merge first. For each of the eight tasks, re-open the cited symbol by NAME (not line), confirm the gap still exists, and update the anchor. Re-derive the #261 stop-channel matrix on then-current `main` and confirm: (a) the Shortcuts row now goes through `BackgroundStopPolicy`; (b) the schedule-stop rows (#206/#239) go through it; (c) the remote-stop row is UNCHANGED (trusted-at-origin per MDR-2 / D2 MD2); (d) no bundle merged between now and implementation already closed one of these gaps (if so, re-scope that task). This step is a gate — do not write code until it is done.

- [ ] **Confirm the MAINTAINER DECISIONS.** Get explicit rulings on the ⚠️ UNRESOLVED items before coding the affected task: **MDR-1** (Task 3 structure), **MDR-2** (Task-nothing — confirm remote stops stay un-gated), **MDR-3** (Task 4/5/6 geofence-on-schedule), **MDR-4** (Task 5 approach), **MDR-5** (Task 6 skip-vs-defer), **MDR-6** (Task 1 move-vs-mirror). MDR-0 (#261 Option A) is already settled.

- [ ] **Request code review** (AGENTS.md requirement) before merging. Restate in the PR: this bundle applies **one** shared `BackgroundStopPolicy` to the Shortcuts/Siri and extension schedule channels; the remote-stop channel is deliberately trusted-at-origin (MDR-2, composing with D2 MD2); #261 is Option A (settled).

---

## Adversarial verification (ran on the draft; findings folded in)

<a id="a1a2"></a>

### Second pass — independent attacker on the written draft (5 findings, all folded in)

An independent adversary attacked the *written* plan against real code and found five holes; every one is resolved above:

- **F1 (HIGH) — `deactivateRestrictions()` is unconditional + global, and ran BEFORE the id-gate.** `AppBlockerUtil.deactivateRestrictions()` calls `clearAllSettings()` on the single shared `ManagedSettingsStore` (`AppBlockerUtil.swift:52-65`) — profile-agnostic. The draft deactivated, then id-gate-ended; in a swap window that wiped a *different, protected* profile's restrictions while its session survived. **Fixed:** `endActiveSharedSession(expectedSessionId:)` now returns `Bool`; Tasks 4/5 **end first, deactivate only on a real end** (`if endActiveSharedSession(…) { deactivateRestrictions() }`). Residual: a ~microsecond window between a *successful* end and the deactivate call remains (ManagedSettings can't be atomic with the app-group `flock`); it self-heals on the next callback/foreground and is far narrower than the draft's — documented below.
- **F2 (HIGH) — the takeover's `createSessionForScheduler` was un-gated, so the id-gate was useless on that path.** After the (gated) end, `ScheduleTimerActivity.start` unconditionally overwrote `activeSharedSession` (`createSessionForScheduler`, `SharedData.swift:370-380`) — clobbering a session that arrived in the eval gap and losing it (not even moved to completed). **Fixed:** Task 2 adds the atomic `startSchedulerSessionTakingOver(profileId:expectedVictimId:)` (one `withLock`: create/replace only if the state still matches; abort otherwise); Task 6 uses it and drops the raw `createSessionForScheduler`/`endActiveSharedSession` pair.
- **F3 (MEDIUM-HIGH) — the draft's new `isTodayScheduled()` guard in Task 5 broke OVERNIGHT scheduled stops.** `isTodayScheduled()` is weekday-membership only; an overnight window (Fri 22:00 → Sat 06:00) fires `intervalDidEnd` on Saturday, which the naive guard would refuse — stranding the session blocked. **Fixed:** Task 5 **removes** the day guard entirely; `canStop(.schedule)` fully carries the #206 fix (manual-only-stop refusal) without a day check. Day-of-week precision for schedule-stop profiles is a documented residual (needs window-aware logic).
- **F4 (MEDIUM) — takeover `geofence: .noRule` let a scheduled start bypass a geofenced victim's location lock**, inconsistent with the now-fail-closed Shortcuts channel. **Fixed:** Task 6 passes `geofence: .unavailable` when `victimSnapshot.geofenceRule?.hasLocations == true` (fail-closed, consistent); a geofenced victim is never taken over (MDR-5 skip).
- **F5 (MEDIUM-LOW) — claimed app-path geofence fail-open→fail-closed change.** **Verified FALSE POSITIVE:** `evaluateGeofenceForStop` returns `nil` only when there is *no* rule and `.failed(...)` when location is unavailable (`GeofenceEvaluator.swift:44-55`), so current behavior is *already* fail-closed. The draft's `.unavailable` app-path branch was dead code. **Fixed:** Task 3's mapping is corrected to `nil → .noRule`, non-nil `→ .satisfied/.notSatisfied`, preserving current behavior exactly (no `.unavailable` on the app path).

The attacker confirmed as clean: `withLock` non-reentrancy (the gated end/takeover use the raw computed properties, no nesting → no deadlock); the pure policy + nil-`stopConditions` fail-closed; and Task 8's monotonic `max` merge (cannot resurrect or double-end).

### First pass — self-run attackers on the draft

Three independent attackers probed the draft for cross-process races, missed/duplicate callbacks, and stale-snapshot windows. Findings and resolutions:

- **A1 — Extension read-then-end TOCTOU (stale-snapshot).** `ScheduleTimerActivity.stop` / `StopScheduleTimerActivity.stop` read the active session, evaluate, then call `endActiveSharedSession()` — but the app could swap `activeSharedSession` between the read and the end, so the extension would end the *wrong* session. D2 gated the six in-app mutators but explicitly left `endActiveSharedSession` un-gated. **Folded in:** Task 2 adds `endActiveSharedSession(expectedSessionId:)` and every extension stop path passes the id it evaluated (Tasks 4/5/6). Composes with D2's identity-gating philosophy.
- **A2 — Duplicate/dropped callbacks (#260).** Every changed handler must be safe under a callback firing 0, 1, or N times. **Verified:** `BackgroundStopPolicy.evaluate` is pure; `endActiveSharedSession(expectedSessionId:)` is a no-op once the session is gone or swapped; the #206/#239 guards reject stale fires; the #229 suppression is a pure comparison. No handler depends on a callback definitely firing (the app-side merge #243 and in-app stop paths are the reconciliation triggers, not the callbacks).
- **A3 — `nil stopConditions` on older snapshots.** A snapshot encoded before Task 1 decodes `stopConditions == nil`. **Folded in:** `BackgroundStopPolicy` treats `nil` as `ProfileStopConditions()` (nothing allowed) → **fails closed** (never allows a background stop it can't justify). Covered by `testGivenNilStopConditions_WhenSchedule_ThenDenied` and the back-compat decode test.
- **A4 — #261 "remote stops" vs D2 MD2 conflict.** The #261 comment says apply the policy to remote stops; D2 MD2 says remote ops are trusted-at-origin, and re-gating on the receiver is semantically impossible (no origin stop-method) and breaks convergence. **Folded in:** MDR-2 surfaces the conflict with a strong recommendation (trust-at-origin) and requires maintainer sign-off; D1 does not touch the remote-stop path.
- **A5 — Geofence permanent-trap on schedule stops.** Uniform fail-closed geofence could make a geofenced+scheduled profile un-stoppable in the background forever. **Folded in:** MDR-3 (schedule channel omits geofence; recommended) with maintainer confirmation required.
- **A6 — #236 victim-snapshot availability.** The takeover branch only holds the incoming profile's snapshot. **Verified:** the victim's snapshot is fetchable in-process via `SharedData.snapshot(for: victimProfileId)` (Task 6 Step 3), so the policy is evaluable; the victim's geofence is not, hence the documented `.noRule` (the `canStop(.manual)` gate already protects commitment victims).
- **A7 — Synthetic-interval fix location.** Fixing only the scheduler (app) would leave the extension trusting a daily callback. **Folded in:** MDR-4 puts the primary guard in the extension (`ScheduleTimerActivity.stop`), robust to flakiness; the scheduler cleanup is optional.

## Self-review (spec coverage / placeholders / type consistency)

- **Coverage:** #261 → Task 3; #206 → Task 5; #239 → Task 4; #236 → Task 6; #229 → Task 7; #243 → Task 8; the extension-evaluability foundation → Tasks 1–2. The two required data-flow deliverables (extension-input source table; `scheduleLastStoppedAt` who-writes/reads/clobbers table) are in the front matter. Every re-triage gap and both settled verdicts map to a task or an MDR. ✅
- **Placeholders:** none — every step has complete code and an exact `-only-testing:` command. ✅
- **Type consistency:** `BackgroundStopPolicy.evaluate(channel:sessionMatchesProfile:disableBackgroundStops:geofence:stopConditions:)`, `Channel/GeofenceState/Denial/Decision`, `SharedData.endActiveSharedSession(expectedSessionId:)`, `ProfileStopConditions` (now `public`, `FoqosShared`), `ProfileSnapshot.stopConditions`, `BlockedProfileSchedule.windowStart(on:calendar:)`, `IntentError.stopConditionsNotMet(reason:)`, and `PreActivationReminderScheduler.mergeExtensionScheduleSuppression(context:)` are used consistently across the tasks that produce and consume them. ✅

## Contract-compliance & residuals (honest)

- **One policy, two/three call sites:** the shared `BackgroundStopPolicy` is the single decision authority for the Shortcuts and extension schedule channels. The remote-stop channel is a **documented, maintainer-gated exception** (MDR-2), not an oversight.
- **Idempotency:** every added/changed handler is safe under flaky/duplicate/dropped DeviceActivity callbacks (#260). No new semantics depend on a callback definitely firing. The **session-state** mutations are identity-gated and atomic (`endActiveSharedSession(expectedSessionId:)`, `startSchedulerSessionTakingOver`).
- **Residual (F1, narrow deactivate window):** `ManagedSettings.clearAllSettings()` is global and cannot be made atomic with the app-group `flock`. After a *successful* identity-gated end, there is a ~microsecond window before `deactivateRestrictions()` in which the app could start a new session whose restrictions are then cleared; the new session's own timer/`loadActiveSession` re-applies them on its next tick. This is strictly narrower than the draft (which deactivated before any gate) and than current `main` (which ends the wrong session outright). Bounded, self-healing.
- **Residual (F3, schedule-stop day precision):** the extension does not narrow scheduled stops to their scheduled *weekdays* (the DeviceActivity interval fires daily by design; a correct narrowing needs window-aware `activeWindowStart` logic that must handle overnight windows). Behavior is unchanged from current `main` for schedule-stop profiles; the #206 defect (manual-only-stop bypass) is fully fixed. A window-aware day guard is a follow-up (MDR-4).
- **Residual (MDR-3, if A adopted):** a geofenced-and-scheduled profile's *scheduled* stop is not geofence-gated (matches current behavior); its manual/Shortcuts stop still is. Documented.
- **Residual (#229 legacy path):** the fix targets unmigrated V1 profiles (an edge case; migration is deferred only during active sessions). Pre-release, no live users — no migration constraint.
- **Residual (#243 clobber):** the merge closes the app↔extension drift on foreground; a suppression written by the extension while the app is in the *foreground and mid-operation* is reconciled on the next `.active` transition, not instantly. Bounded and non-destructive (`max` never regresses).
- **No `@Query`/`!= .parent`/lock-mode changes; no funnel/CloudKit changes** — D1 is confined to background stop/start semantics and the app-group snapshot schema.
