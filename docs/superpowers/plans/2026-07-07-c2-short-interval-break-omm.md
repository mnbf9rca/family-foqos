# C2 Short-Interval Enforcement — Break / One-More-Minute Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make 5/10-minute breaks (#214) and the 60-second one-more-minute (#207) actually enforce, make an early break-end re-apply restrictions in-process (#260), and stop one-more-minute expiry from re-blocking mid-break (#205) — by moving every restriction-lift/re-block onto a persisted absolute deadline executed in-process, with DeviceActivity demoted to a redundant background backstop.

**Architecture:** Every grant (break or OMM) persists an absolute wall-clock deadline to the app-group `SessionSnapshot` in the *same* `withLock` critical section that lifts restrictions (deadline-authoritative lifting, D-C2-1). Restriction state is a **derived function of persisted state** applied atomically with each state change (D-C2-4). All grant transitions run in-process by whichever process observes them first (main app for taps + foreground ticker; extension for background expiry; a single reconciler for healing). DeviceActivity is registered in a C1-style wrap-anchor shape under **new C2-owned activity names**, and no §4 property depends on any callback firing. The extension **never mutates registrations**; the main app owns all registration and repair.

**Tech Stack:** Swift 6, SwiftUI, SwiftData (`cloudKitDatabase: .none`), DeviceActivity / FamilyControls / ManagedSettings, XCTest. Shared code in the `FoqosShared` SwiftPM package (linked by both the app target `FamilyFoqos` and the monitor extension `FoqosDeviceMonitor`).

**Source contract (NORMATIVE):** `docs/plans/2026-07-06-c2-short-interval-break-omm-design.md` (rev 6, merged PR #282). This plan translates that contract; it does not redesign it. Every invariant and named scenario in the contract maps to a named test here (see §Mapping Tables). Where this plan departs from the contract's *code citations*, it is because the citation was re-verified stale/wrong against current `main` — see §Grounding Corrections; no *mechanism* departs.

**Plan authored against:** `main` @ **`a726a70`** (the commit this plan was grounded on — post-C1 #275, post-D1 #279, post-F #280, post-I #281, post-C2-contract #282). Every `file:line` below was re-verified at this commit.

---

## Global Constraints

- **Contract is normative; do not redesign.** MD-C2-1/2/3 are all SETTLED = A (keep 5/10-min breaks; a break absorbs an open OMM; accept bounded OMM background overrun). The §10 device probe #2 PASSED — implementation gate T-C2-D6 is cleared. Do not reopen these.
- **No mechanism improvisation.** If any step is ambiguous or unimplementable against the real code, STOP and flag it in the PR — do not invent behavior.
- **Swift style (AGENTS.md):** 2-space indent; 100–120 col; `Log.<level>(..., category:)` never `print()`; `guard` early-returns; UserDefaults keys `family_foqos_`-prefixed; booleans `is/has/enable/allow`.
- **`@SafeQuery` not `@Query`** in any view (pre-commit hook rejects raw `@Query`).
- **Pin time in tests:** capture a single `let now = Date()` per test and derive all other dates from it; inject via `now:` params. Never call `Date()` twice in one test.
- **Test isolation idiom (copy verbatim — there is no shared base `XCTestCase`):** per-file unique suite
  ```swift
  private static let testSuiteName = "<ClassName>-\(UUID().uuidString)"
  override func setUp() { super.setUp(); SharedData.configure(suite: UserDefaults(suiteName: Self.testSuiteName)!) }
  override func tearDown() { UserDefaults().removePersistentDomain(forName: Self.testSuiteName); super.tearDown() }
  ```
  For `@MainActor` classes touching `ModelContext`/`StrategyManager`, use `override func setUp() async throws` / `tearDown() async throws` and an instance `suiteName` (see `StrategyManagerRemoteSessionTests`), and call `manager.stopTimer()` in tearDown so the ticker `Task` does not leak.
- **SwiftData test container:** `TestModelContainer.create()` (`FoqosTests/Helpers/TestModelContainer.swift`) — in-memory, `cloudKitDatabase: .none`, schema `[BlockedProfiles, BlockedProfileSession, SavedLocation]`. Its schema already contains the two models C2 touches; no schema-array edit needed.
- **App group:** `group.com.cynexia.family-foqos`. `SharedData` is a `public enum` (static namespace) configured per-process via `SharedData.configure(suite:)`; it is **not** instantiable and has no `.shared`.
- **No live users** (pre-release): prefer structural fixes; no data-migration constraints beyond the in-flight *upgrade-window* grant handling the contract mandates (R7).
- **Test target:** `FoqosTests`. Boot the simulator ONCE (UUID, never device name); run `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/<Class>`. Unit tests take <1s; simulator boot takes minutes — do not re-boot per run.
- **R4 is OUT OF SCOPE.** The pre-existing stop-schedule stop-then-restart re-registration risk (`StrategyManager` :107/:666, `scheduleStopActivity`) is tracked outside C2. Do not touch those sites or expand into them.

---

## Grounding Corrections (contract citations re-verified at `a726a70`)

The contract was authored against `8c86df2`. PRs #280/#281 (and the #217 LegacyKey work) landed after. Every citation was re-checked; these are the deltas an implementer must know. **None changes the mechanism.**

| # | Contract said | Reality at `a726a70` | Consequence for the plan |
|---|---|---|---|
| GC1 | Break/OMM UI in `TimerDurationView` | It is in **`Foqos/Components/BlockedProfileCards/ProfileTimerButton.swift`** (break button :82 gated on `isBreakAvailable`; OMM button :95 gated on `isActive && !isBreakActive`; label :25). `TimerDurationView` is an unrelated 15m–24h session-length slider. | 7.2's "keep stop-break affordance visible on raw-field break-open" edits **ProfileTimerButton** (Task 15). |
| GC2 | §7.5(b) reconciler hook = `FoqosApp` `scenePhase == .active` | `FoqosApp` `.active` (:135–165) does **not** call `loadActiveSession`; it runs the schedule catch-up trio + `drainSessionStopOutbox` + `syncNow`. `loadActiveSession` is driven from **`HomeView.loadApp()` (:607–609)**, wired to HomeView's own `scenePhase` (:282), `onChange(of: profiles)` (:277), initial (:236), and `.onAppear` (:299). | Wire the reconciler **inside `StrategyManager.loadActiveSession`** — the single sink all foreground passes funnel through — not into `FoqosApp` (Task 17). |
| GC3 | rev-6 "active shared session = present AND `endTime == nil`" | `SharedData.activeSharedSession` getter (:370–383) returns the stored snapshot **without** an `endTime` gate; `endTime` field exists (:279). | Implement the "ended-but-present ⇒ no session" reading **locally in the C2 deriver** (Task 4), not by changing the shared getter (which D1 depends on). Avoids D1 scope. |
| GC4 | `stopScheduleInterval` *is* the wrap-anchor shape | Its wrap (`intervalStart = stop+1`) is **conditional** — only when `stopMinuteOfDay < 15` (:462); otherwise a 00:00 anchor. It is not a general deadline→wrap builder. | C2 adds its **own** pure `wrapAnchorInterval(endingAt:now:)` (Task 2); it reuses `stopScheduleInterval` only as the proven precedent for `repeats:true` + modulo-1440 delivery. |
| GC5 | Seam-injected blocker/center spies (implied available) | **No** `AppBlockerUtil`/`DeviceActivityCenter` mock/protocol seam exists in `FoqosTests`; only pure static funcs are unit-testable. | Plan **introduces** two seams: `RestrictionApplying` (Task 3) and `BackstopRegistering` (Task 12). This is mandated by §12's "seam-injected blocker/center spies", not a redesign. |
| GC6 | `SharedData` line numbers (:72-78 withLock, :364-370 setter, etc.) | Shifted ~+6/+12 by the #217 LegacyKey machinery: `withLock` :78–99 (fallbacks :79–96); `activeSharedSession` setter :375–383 (encode-fail **deletes** key :379); `SessionSnapshot` :273–312; identity mutators :511/:519/:527/:535/:546; `activeSharedSessionMatchesExpected` :476–490. | All SharedData citations below use the corrected lines. Encode-then-commit (Task 5) is required because the shipped setter deletes on encode failure. |
| GC7 | `isBreakActive` :26-29 / `isBreakAvailable` :31-35 | **Transposed:** `isBreakAvailable` :26–29 (`enableBreaks && breakEndTime == nil`); `isBreakActive` :31–35 (`enableBreaks && breakStartTime != nil && breakEndTime == nil`); `isOneMoreMinuteAvailable` :42–44 (`!oneMoreMinuteUsed && !isBreakActive`). Behavior as-described. | Cite corrected lines; the `enableBreaks` conjunct in both is exactly the I11 hazard the plan neutralizes. |
| GC8 | Timer strategies call `StrategyTimerActivity.start` | They call **`DeviceActivityCenterUtil.startStrategyTimerActivity(for:)`** (Shortcut :40, NFC :54, QR :53); the extension's `StrategyTimerActivity.start` (:36) is what actually applies. No in-process activate. | The G17 class-(iii) inventory in Task 10/17 greps `startStrategyTimerActivity` call sites, per §7.5's "grep, don't trust the contract" rule. |
| GC9 | `startBreakTimerActivity` is the break's OS wake | It exists (:226–248, swallows the throw at :246) but C2 **stops using it** for new grants (replaced by the C2 backstop). It stays only as a legacy bonus-wake source. `startOneMoreMinuteActivity` (:309–348) is `throws` and propagates; `startBreak`'s util is **not** `throws` (so `startBreak` cannot even observe failure today — #214). | Task 13 makes the break registration path observe failure (via the `BackstopRegistering` seam), fixing #214's silent-no-op. |
| GC10 | — | `StrategyTimerActivity.stop` calls the **bare** `endActiveSharedSession()` (no `expectedSessionId`) — the one ungated D1-era exception (out of scope). All other extension mutators are identity-gated. | Do not touch it; note it in Task 10 so the reconciler's "extension never un-blocks on absence" reasoning stays accurate. |

---

## The Two New Test Seams (introduced by this plan)

Both are required because no seam exists today (GC5) and the contract's test list assumes "seam-injected blocker/center spies".

**Seam 1 — `RestrictionApplying`** (`FoqosShared`, Task 3). The lock-free restriction applier. `AppBlockerUtil` already has exactly the two methods, so conformance is empty. Every C2 primitive that lifts/re-blocks takes an injected `RestrictionApplying` defaulting to `AppBlockerUtil()`; tests pass a recording spy to assert call order (I1 atomicity) and ON/OFF outcomes.

**Seam 2 — `BackstopRegistering`** (main app, Task 12). Wraps the main-app-only DeviceActivity registration mutations (fresh-grant *replace*, re-arm *register-if-absent*, remove, presence check). Real impl delegates to `DeviceActivityCenterUtil` + `DeviceActivityCenter`. `StrategyManager` and the reconciler take an injected `BackstopRegistering` defaulting to the real impl; tests pass a spy to assert "registered before lift", "throw ⇒ fail-closed", and "re-arm never stops a live registration".

Everything else C2 needs is already testable: `SharedData` via `configure(suite:)` + a unique suite; the degraded-lock path via the DEBUG `SharedData.configureLockPath(_:)` / `resetLockPath()` seam (forces the nil-`lockPath` proceed-unlocked branch); pure functions (`wrapAnchorInterval`, the `RestrictionDecision` deriver) directly.

---

## File Structure

**New files (FoqosShared — usable by both processes):**
- `Packages/FoqosShared/Sources/FoqosShared/RestrictionApplying.swift` — `protocol RestrictionApplying` + `extension AppBlockerUtil: RestrictionApplying {}`.
- `Packages/FoqosShared/Sources/FoqosShared/RestrictionDecision.swift` — pure derivation: `enum RestrictionDecision`, `enum RestrictionProcess`, `SharedData.deriveRestriction(...)` (the four-row per-process table). No side effects, no seam.
- `Packages/FoqosShared/Sources/FoqosShared/RestrictionGrants.swift` — the `withLock` critical-section primitives (`openBreakGrant`, `openOneMoreMinuteGrant`, `closeGrantsForSessionEnd`, `closeBreakGrantIfExpiredOrExplicit`, `closeOneMoreMinuteGrantIfExpired`, `applyRestrictionsForCurrentState`) and the reconciler core `healExpiredLifts`. All `SharedData` static methods (same module → reach the encode-then-commit raw seam).
- `Packages/FoqosShared/Sources/FoqosShared/Timers/BreakDeadlineBackstopActivity.swift` — C2-owned backstop handler (`id = "BreakDeadlineBackstop"`), `start` no-op, `stop` → break closer + reconcile.
- `Packages/FoqosShared/Sources/FoqosShared/Timers/OneMoreMinuteDeadlineBackstopActivity.swift` — C2-owned backstop handler (`id = "OneMoreMinuteDeadlineBackstop"`), `start` no-op, `stop` → OMM closer + reconcile.

**Modified files (FoqosShared):**
- `SharedData.swift` — `SessionSnapshot`: add `breakEndDeadline`, `oneMoreMinuteDeadline`, `pinnedProfileConfig` (+ init); add the encode-then-commit raw session seam (`internal` read/write); add `deriveActiveSession` helper (present AND `endTime == nil`).
- `Timers/BreakTimerActivity.swift` — `start` → no-op (log only); `stop` → shared break closer (legacy bonus wake).
- `Timers/OneMoreMinuteTimerActivity.swift` — `start` stays no-op; `stop` → shared OMM closer (with break-active branch).
- `Timers/TimerActivityUtil.swift` — route the two new C2 backstop ids to their handlers.

**Modified files (main app `Foqos/`):**
- `Utils/DeviceActivityCenterUtil.swift` — add `wrapAnchorInterval(endingAt:now:)` (pure) + the C2 backstop register/replace/re-arm/remove/presence helpers under the new names.
- `Utils/StrategyManager.swift` — rewrite `startBreak` (7.1), `stopBreak` (7.2), `startOneMoreMinute` (7.4); `toggleBreak` raw-field routing; ticker expiry executor (7.4b); reconciler wiring in `loadActiveSession`; inject `RestrictionApplying` + `BackstopRegistering`.
- `Models/BlockedProfileSessions.swift` — round-trip the three new fields (`toSnapshot`/`upsertSessionFromSnapshot`); `endSession` calls `closeGrantsForSessionEnd` before its end-time write; ingest normalization + notification cancel for extension-ended sessions.
- `Models/BlockedProfileSession` `@Model` (same file) — add `breakEndDeadline: Date?`, `oneMoreMinuteDeadline: Date?`, `pinnedProfileConfigData: Data?` columns.
- `Components/BlockedProfileCards/ProfileTimerButton.swift` — stop-break affordance visible on raw-field break-open; countdown reads the persisted deadline.

**Modified files (extension `FoqosDeviceMonitor/`):**
- `DeviceActivityMonitorExtension.swift` — after routing each `intervalDidStart`/`intervalDidEnd`, invoke the reconciler with extension capability.

**New CI guard scripts:**
- `scripts/check-c2-guards.sh` — greps enforcing: (a) `AppBlockerUtil` stays lock-free (no `withLock`/`SharedData.` accessor inside it) — T-C2-U21; (b) the extension never calls `startMonitoring`/`stopMonitoring` — T-C2-U28; (c) C2 grant sections never call the public `withLock`-wrapped `SharedData` accessors (silent lock-loss guard, D-C2-4(ii)/guard-parity).

**New test files (FoqosTests):**
- `WrapAnchorIntervalTests.swift`, `RestrictionDecisionTests.swift`, `RestrictionGrantsOpenTests.swift`, `RestrictionGrantsCloseTests.swift`, `SessionEndGrantTests.swift`, `HealExpiredLiftsTests.swift`, `C2BackstopRoutingTests.swift`, `StrategyManagerBreakOMMTests.swift`, `SessionSnapshotDeadlineTests.swift`.

---
## Mapping Tables (contract → plan)

### A. Invariants (I1–I11) → enforcing test(s) → task

| Invariant | Enforced by test(s) | Task |
|---|---|---|
| I1 — Deadline-with-lift (atomic) | `RestrictionGrantsOpenTests.testGivenOpenBreakGrant_WhenSectionCommits_ThenDeadlineStartAndLiftAppliedTogether` (spy-order) = T-C2-U12 | 6 |
| I2 — Initiator executes | `StrategyManagerBreakOMMTests` (tap paths), `RestrictionGrantsCloseTests` (ticker/ext closers), `HealExpiredLiftsTests` = T-C2-U14/U17/U8 | 7,10,15,16 |
| I3 — Exactly-once CAS, any executors | `RestrictionGrantsCloseTests.testGiven*_CASMatrix_*` = T-C2-U3/U4/U7 | 7 |
| I4 — No callback in correctness | `RestrictionGrantsCloseTests` synthetic-end + `HealExpiredLiftsTests` (drop/dup/late) = T-C2-U7/U8 | 7,10 |
| I5 — Backstop freshness + preservation | `StrategyManagerBreakOMMTests` replace-before-lift + `HealExpiredLiftsTests` re-arm-if-absent = T-C2-U18; `C2BackstopRoutingTests` = T-C2-U29 | 11,12,13,14 |
| I6 — Universally gated closers (+ nil-deadline stamp) | `RestrictionGrantsCloseTests.testGiven*_DeadlineGate_*`, `..._NilDeadlineStamp_*` = T-C2-U5/U22 | 7 |
| I7 — Terminal-state-before-deregistration | `StrategyManagerBreakOMMTests.testGivenBreakStarted_WhenToggleBreakAgain_ThenClosesReblocksAndDeregisters` = T-C2-U14 | 15 |
| I8 — Identity gates everywhere | `RestrictionGrantsOpenTests` identity-fail + `RestrictionGrantsCloseTests` identity-fail = T-C2-U9/U3/U4 | 6,7 |
| I9 — One grant family, both directions | `RestrictionGrantsOpenTests` absorption + OMM break-refusal = T-C2-U15/U23; OMM closer break-branch = T-C2-U6 | 6,7 |
| I10 — Single reconciler; session-end is separate | `HealExpiredLiftsTests` + `SessionEndGrantTests` = T-C2-U8/U16 | 8,10 |
| I11 — Raw-field enforcement predicates | `RestrictionGrantsCloseTests` `enableBreaks`-off = T-C2-U19; OMM refuse under `enableBreaks==false` = T-C2-U23; `StrategyManagerBreakOMMTests` raw-field toggle routing | 7,15 |

### B. Interleavings (X1–X38) → coverage

| X | Covered by | X | Covered by |
|---|---|---|---|
| X1 two-tap #260 | T-C2-U14 + T-C2-D1 | X20 stale-⚡ current-deadline | T-C2-U5 |
| X2 synthetic end after early-end | T-C2-U7 | X21 upsert mid-transition | T-C2-U13 |
| X3 fg natural expiry | T-C2-U17 | X22 M† open→lift crash | T-C2-U8 (converge) |
| X4 bg expiry ⚡ delivered | T-C2-U8 | X23 executor† closer crash | T-C2-U8 (converge) |
| X5 ⚡ never delivered (safe-late) | T-C2-U8 + T-C2-D4 | X24 M† between replace & open | T-C2-U18 |
| X6 ⚡ twice / very late | T-C2-U3/U4/U7 | X25 leaked reg adopted | T-C2-U18 |
| X7 expired-OMM ⚡ vs break start | T-C2-U6/U15 | X26 profile edit mid-grant | T-C2-U19/U22 |
| X8 deadline vs backstop-end | T-C2-U1/U5 | X27 ticker vs early-end tap | T-C2-U3 |
| X9 †→relaunch before deadline | T-C2-U18/U8 | X28 ext wake in start gap | T-C2-U20 |
| X10 †→relaunch after deadline | T-C2-U8 + T-C2-D4 | X29 D1 takeover apply/persist | T-C2-U8 (noted OOS) |
| X11 †→never relaunch | T-C2-U8 (R1) | X30 missing snapshot | T-C2-U24/U26 |
| X12 D1 schedule stop mid-break | T-C2-U16 | X31 legacy nil-deadline + shrink | T-C2-U22 |
| X13 D1 takeover mid-break | T-C2-U9 | X32 enableBreaks-off then OMM tap | T-C2-U23 |
| X14 takeover racing open | T-C2-U9 | X33 timer-strategy initial block | T-C2-U20 (session⇒ON) |
| X15 registration throws at grant | T-C2-U10/U11 | X34 re-arm destroy-then-fail | T-C2-U18/U28 |
| X16 backstop absent at re-arm + fail | T-C2-U18 | X35 degraded-lock stale closer | T-C2-U27 |
| X17 session end mid-grant | T-C2-U16 | X36 open while snapshot missing | T-C2-U24 |
| X18 clock jump | T-C2-U5 (absolute deadline) | X37 legacy repeats:false adopted | T-C2-U29/U31 |
| X19 midnight wrap | T-C2-U2 | X38 encode failure in open write | T-C2-U30 |

### C. Named scenarios (contract §12) → test file → task

| Contract ID | Test file · method (testGivenX_WhenY_ThenZ) | Task |
|---|---|---|
| T-C2-U1 | `WrapAnchorIntervalTests` · neverEarly across 0…59s | 2 |
| T-C2-U2 | `WrapAnchorIntervalTests` · midnight wrap | 2 |
| T-C2-U3 | `RestrictionGrantsCloseTests` · break closer CAS matrix | 7 |
| T-C2-U4 | `RestrictionGrantsCloseTests` · OMM closer CAS matrix | 7 |
| T-C2-U5 | `RestrictionGrantsCloseTests` · deadline gate incl. stale ⚡ | 7 |
| T-C2-U6 | `RestrictionGrantsCloseTests` · OMM break-active branch (#205) | 7 |
| T-C2-U7 | `RestrictionGrantsCloseTests` · synthetic-end tolerance | 7 |
| T-C2-U8 | `HealExpiredLiftsTests` · reconciler decision table | 10 |
| T-C2-U9 | `RestrictionGrantsOpenTests` · identity failure ⇒ false, no state | 6 |
| T-C2-U10 | `StrategyManagerBreakOMMTests` · startBreak fail-closed (#214) | 13 |
| T-C2-U11 | `StrategyManagerBreakOMMTests` · startOneMoreMinute fail-closed (#207) | 14 |
| T-C2-U12 | `RestrictionGrantsOpenTests` · I1 atomicity spy-order | 6 |
| T-C2-U13 | `SessionSnapshotDeadlineTests` · round-trip + legacy nil decode | 1 |
| T-C2-U14 | `StrategyManagerBreakOMMTests` · early-end commit-before-deregister (X1) | 15 |
| T-C2-U15 | `RestrictionGrantsOpenTests` · I9 absorption | 6 |
| T-C2-U16 | `SessionEndGrantTests` · endSession bookkeeping + ingest normalize | 8 |
| T-C2-U17 | `StrategyManagerBreakOMMTests` · ticker expiry executor | 16 |
| T-C2-U18 | `HealExpiredLiftsTests` + `StrategyManagerBreakOMMTests` · freshness/preservation | 12,13 |
| T-C2-U19 | `RestrictionGrantsCloseTests` · enableBreaks-off still closes (I11) | 7 |
| T-C2-U20 | `RestrictionDecisionTests` · per-process derivation table | 4 |
| T-C2-U21 | `scripts/check-c2-guards.sh` (CI) + `RestrictionDecisionTests` note | 3,18 |
| T-C2-U22 | `RestrictionGrantsCloseTests` · nil-deadline stamp once; unstampable-in-X | 7 |
| T-C2-U23 | `RestrictionGrantsOpenTests` · OMM break-open refusal | 6 |
| T-C2-U24 | `RestrictionGrantsOpenTests` + `HealExpiredLiftsTests` · missing-snapshot | 6,10 |
| T-C2-U25 | `SessionEndGrantTests` · ingest cancels pending notifications | 8 |
| T-C2-U26 | `RestrictionDecisionTests` · config precedence live→pinned→bail | 4 |
| T-C2-U27 | `RestrictionGrantsOpenTests` · lock-acquisition surfacing | 6 |
| T-C2-U28 | `scripts/check-c2-guards.sh` (CI) | 18 |
| T-C2-U29 | `C2BackstopRoutingTests` · new names route; legacy still routes | 11 |
| T-C2-U30 | `RestrictionGrantsOpenTests`/`...CloseTests` · encode-then-commit | 5,6,7 |
| T-C2-U31 | `HealExpiredLiftsTests` · legacy full migration completion-keyed | 10 |
| T-C2-U32 | `RestrictionDecisionTests` · ended-but-present ⇒ no-session + flush | 4,9 |
| T-C2-U33 | `SharedDataC2SeamTests` · held-lock ⇒ non-blocking acquire degrades within ceiling (+ `RestrictionGrantsCloseTests` R8 best-effort close) | 5 (+7) |
| T-C2-U34 | `RestrictionGrantsOpenTests` · openBreakGrant own-family refusal | 6 |
| T-C2-U35 | `StrategyManagerBreakOMMTests` · countdown from persisted deadline | 16 |
| T-C2-D1…D6 | Device checklist (§Device Verification) — D6 already PASSED | appendix |

**Every contract invariant (I1–I11), interleaving (X1–X38), and named scenario (T-C2-U1–U35, T-C2-D1–D6) appears above with a home.** No contract scenario is unmapped. If, while implementing, you find a scenario with no test, STOP and flag it.

---
## Tasks

Tasks are ordered bottom-up: pure/foundation pieces first, then critical-section primitives, then the reconciler, then the extension/main-app wiring, then CI guards. Each ends with an independently reviewable, testable deliverable. Run the relevant `-only-testing:FoqosTests/<Class>` after each.

---

### Task 1: Deadline + pinned-config schema on `SessionSnapshot` and the model

**Files:**
- Modify: `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift` (`SessionSnapshot` struct :273–312 and its init :289–311)
- Modify: `Foqos/Models/BlockedProfileSessions.swift` (`@Model BlockedProfileSession` stored properties; `toSnapshot()` :97–110; `upsertSessionFromSnapshot` :144–195)
- Test: `FoqosTests/SessionSnapshotDeadlineTests.swift` (new)

**Interfaces:**
- Produces: `SessionSnapshot.breakEndDeadline: Date?`, `.oneMoreMinuteDeadline: Date?`, `.pinnedProfileConfig: SharedData.ProfileSnapshot?`; matching model columns `breakEndDeadline`, `oneMoreMinuteDeadline`, `pinnedProfileConfigData`. Consumed by every later task.

**§6.1a decision (recorded):** the pinned re-block config is the **whole `ProfileSnapshot`**, not a bespoke subset. Rationale: `AppBlockerUtil.activateRestrictions(for:)` takes a `ProfileSnapshot` directly (`AppBlockerUtil.swift:11`), so reusing the type needs no new struct or mapping (DRY); it consumes only `selectedActivity`, `enableAllowMode`, `enableAllowModeDomains`, `enableStrictMode`, `enableSafariBlocking`, `domains`, but pinning the whole snapshot is lossless and Codable-safe. The contract delegates this choice in §6.1a ("the ProfileSnapshot, or the subset — plan's choice"); the enlarged payload is exactly why Task 5's encode-then-commit exists.

- [ ] **Step 1: Write the failing round-trip + legacy-decode test**

`FoqosTests/SessionSnapshotDeadlineTests.swift`:
```swift
import XCTest
import SwiftData
@testable import FamilyFoqos
@preconcurrency import FoqosShared

final class SessionSnapshotDeadlineTests: XCTestCase {
  private static let testSuiteName = "SessionSnapshotDeadlineTests-\(UUID().uuidString)"
  override func setUp() { super.setUp(); SharedData.configure(suite: UserDefaults(suiteName: Self.testSuiteName)!) }
  override func tearDown() { UserDefaults().removePersistentDomain(forName: Self.testSuiteName); super.tearDown() }

  private func makePinned(id: UUID) -> SharedData.ProfileSnapshot {
    SharedData.ProfileSnapshot(
      id: id, name: "Pinned", selectedActivity: .init(), createdAt: Date(), updatedAt: Date(),
      order: 0, enableLiveActivity: false, enableBreaks: true, enableStrictMode: false,
      enableAllowMode: false, enableAllowModeDomains: false, enableSafariBlocking: false)
  }

  func testGivenSnapshotWithDeadlinesAndPin_WhenEncodedAndDecoded_ThenFieldsRoundTrip() throws {
    let now = Date()
    let pid = UUID()
    let snap = SharedData.SessionSnapshot(
      id: "s1", tag: "t", blockedProfileId: pid, startTime: now, forceStarted: false,
      breakStartTime: now, breakEndDeadline: now.addingTimeInterval(300),
      oneMoreMinuteDeadline: nil, pinnedProfileConfig: makePinned(id: pid))
    let data = try JSONEncoder().encode(snap)
    let back = try JSONDecoder().decode(SharedData.SessionSnapshot.self, from: data)
    XCTAssertEqual(back.breakEndDeadline, now.addingTimeInterval(300))
    XCTAssertNil(back.oneMoreMinuteDeadline)
    XCTAssertEqual(back.pinnedProfileConfig?.id, pid)
  }

  func testGivenLegacySnapshotJSONWithoutDeadlines_WhenDecoded_ThenDeadlinesAreNil() throws {
    // A pre-C2 SessionSnapshot payload has no deadline / pin keys.
    let legacy = """
    {"id":"s0","tag":"t","blockedProfileId":"\(UUID().uuidString)","startTime":0,
     "forceStarted":false,"oneMoreMinuteUsed":false}
    """.data(using: .utf8)!
    let back = try JSONDecoder().decode(SharedData.SessionSnapshot.self, from: legacy)
    XCTAssertNil(back.breakEndDeadline)
    XCTAssertNil(back.oneMoreMinuteDeadline)
    XCTAssertNil(back.pinnedProfileConfig)
  }

  @MainActor
  func testGivenModelWithDeadlines_WhenToSnapshotAndUpsert_ThenModelMirrorsDeadlines() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = ModelContext(container)
    let profile = BlockedProfiles(name: "P")
    context.insert(profile)
    let session = BlockedProfileSession(tag: "t", blockedProfile: profile)
    session.breakStartTime = now
    session.breakEndDeadline = now.addingTimeInterval(300)
    session.pinnedProfileConfigData = try JSONEncoder().encode(makePinned(id: profile.id))
    context.insert(session)
    try context.save()

    let snap = session.toSnapshot()
    XCTAssertEqual(snap.breakEndDeadline, now.addingTimeInterval(300))
    XCTAssertEqual(snap.pinnedProfileConfig?.id, profile.id)

    // Upsert a snapshot carrying a fresh OMM deadline back into a clean context.
    let container2 = try TestModelContainer.create()
    let context2 = ModelContext(container2)
    let p2 = BlockedProfiles(name: "P")  // same id space not required; upsert keys on snapshot.id
    context2.insert(p2)
    try context2.save()
    var snap2 = snap
    snap2.oneMoreMinuteDeadline = now.addingTimeInterval(60)
    BlockedProfileSession.upsertSessionFromSnapshot(in: context2, withSnapshot: snap2)
    let fetched = try context2.fetch(FetchDescriptor<BlockedProfileSession>()).first
    XCTAssertEqual(fetched?.breakEndDeadline, now.addingTimeInterval(300))
    XCTAssertEqual(fetched?.oneMoreMinuteDeadline, now.addingTimeInterval(60))
  }
}
```

- [ ] **Step 2: Run it — expect compile failure / test failure**

Run: `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SessionSnapshotDeadlineTests | xcpretty`
Expected: FAIL — `value of type 'SessionSnapshot' has no member 'breakEndDeadline'` (and model members missing).

- [ ] **Step 3: Add the three optional fields to `SessionSnapshot`**

In `SharedData.swift`, inside `public struct SessionSnapshot` (after `oneMoreMinuteStartTime` at :287) add:
```swift
    /// C2 (D-C2-1): absolute wall-clock deadline for an open break grant. nil ⇒ no break deadline / legacy.
    public var breakEndDeadline: Date?
    /// C2 (D-C2-1): absolute wall-clock deadline for an open one-more-minute grant.
    public var oneMoreMinuteDeadline: Date?
    /// C2 (§6.1a): re-block config pinned at grant-open so a post-close wake can re-assert ON
    /// even if the live profile snapshot is later wiped. Retained until session end.
    public var pinnedProfileConfig: ProfileSnapshot?
```
Extend the `public init` (:289–311) by appending three defaulted params (keep them LAST so existing inline call sites compile unchanged):
```swift
      oneMoreMinuteStartTime: Date? = nil,
      breakEndDeadline: Date? = nil,
      oneMoreMinuteDeadline: Date? = nil,
      pinnedProfileConfig: ProfileSnapshot? = nil
    ) {
      // ...existing assignments...
      self.breakEndDeadline = breakEndDeadline
      self.oneMoreMinuteDeadline = oneMoreMinuteDeadline
      self.pinnedProfileConfig = pinnedProfileConfig
    }
```
(Optional Codable members decode as nil when absent — legacy payloads decode cleanly, G13. No `CodingKeys` exist, so nothing else to touch.)

- [ ] **Step 4: Add the mirror columns to the `@Model`**

In `BlockedProfileSessions.swift`, add to `@Model class BlockedProfileSession` (near the other break/OMM fields):
```swift
  var breakEndDeadline: Date?
  var oneMoreMinuteDeadline: Date?
  var pinnedProfileConfigData: Data?
```
(All optional ⇒ SwiftData lightweight migration nil-fills existing rows; no live users regardless.)

- [ ] **Step 5: Round-trip the fields in `toSnapshot()` and `upsertSessionFromSnapshot`**

In `toSnapshot()` (:97–110) pass the new fields into the `SessionSnapshot(...)` initializer:
```swift
      oneMoreMinuteStartTime: oneMoreMinuteStartTime,
      breakEndDeadline: breakEndDeadline,
      oneMoreMinuteDeadline: oneMoreMinuteDeadline,
      pinnedProfileConfig: pinnedProfileConfigData.flatMap {
        try? JSONDecoder().decode(SharedData.ProfileSnapshot.self, from: $0)
      })
```
In `upsertSessionFromSnapshot` (:144–195), in **both** the existing-session branch (:157–176) and the new-session branch (:178–194), after the existing field copies add:
```swift
      session.breakEndDeadline = snapshot.breakEndDeadline
      session.oneMoreMinuteDeadline = snapshot.oneMoreMinuteDeadline
      session.pinnedProfileConfigData = snapshot.pinnedProfileConfig.flatMap {
        try? JSONEncoder().encode($0)
      }
```
(The existing branch already ends with `context.save()`; keep that. The new branch sets fields before insert/save — mirror placement.)

- [ ] **Step 6: Run the test — expect PASS**

Run: `xcodebuild test ... -only-testing:FoqosTests/SessionSnapshotDeadlineTests | xcpretty`
Expected: PASS (3 tests).

- [ ] **Step 7: Commit**

```bash
git add Packages/FoqosShared/Sources/FoqosShared/SharedData.swift Foqos/Models/BlockedProfileSessions.swift FoqosTests/SessionSnapshotDeadlineTests.swift
git commit -m "feat(c2): add break/OMM deadline + pinned-config fields to SessionSnapshot (T-C2-U13)"
```

---

### Task 2: Pure `wrapAnchorInterval` backstop-interval builder (D-C2-2)

**Files:**
- Modify: `Foqos/Utils/DeviceActivityCenterUtil.swift` (add beside `stopScheduleInterval` :455–469)
- Test: `FoqosTests/WrapAnchorIntervalTests.swift` (new)

**Interfaces:**
- Produces: `static func wrapAnchorInterval(endingAt deadline: Date, now: Date, calendar: Calendar = .current) -> (intervalStart: DateComponents, intervalEnd: DateComponents)`. Consumed by Task 12's registration helpers.

**Why new (GC4):** `stopScheduleInterval` only wraps when `stopMinuteOfDay < 15`; for a general deadline the window must always wrap so it is *in progress at registration* and delivers `intervalDidEnd` at the boundary (probe #2). Ceil-to-minute guarantees **never-early** (D-C2-2 / #205 class).

- [ ] **Step 1: Write the failing tests (T-C2-U1 never-early; T-C2-U2 midnight wrap)**

`FoqosTests/WrapAnchorIntervalTests.swift`:
```swift
import XCTest
@testable import FamilyFoqos

final class WrapAnchorIntervalTests: XCTestCase {
  private let cal = Calendar(identifier: .gregorian)

  private func date(_ h: Int, _ m: Int, _ s: Int) -> Date {
    var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 7
    c.hour = h; c.minute = m; c.second = s
    return cal.date(from: c)!
  }

  func testGivenSubMinuteOffsets_WhenBuildingWrapAnchor_ThenEndIsNeverEarlierThanDeadline() {
    // Base deadline minute 12:05; sweep second offsets 0…59; end minute-of-day must be >= deadline.
    for s in 0...59 {
      let deadline = date(12, 5, s)
      let now = date(12, 4, 30)
      let (start, end) = DeviceActivityCenterUtil.wrapAnchorInterval(endingAt: deadline, now: now, calendar: cal)
      let endMinuteOfDay = end.hour! * 60 + end.minute!
      let startMinuteOfDay = start.hour! * 60 + start.minute!
      // never-early: the resolved end wall-minute is >= the deadline
      let endAsDate = date(end.hour!, end.minute!, 0)
      XCTAssertGreaterThanOrEqual(endAsDate, date(12, 5, 0), "s=\(s): end must not precede the deadline minute")
      if s == 0 { XCTAssertEqual(endMinuteOfDay, 12 * 60 + 5, "exact boundary ⇒ no ceil") }
      else { XCTAssertEqual(endMinuteOfDay, 12 * 60 + 6, "sub-minute ⇒ ceil up") }
      XCTAssertEqual(startMinuteOfDay, (endMinuteOfDay + 1) % 1440, "start is end+1 (wrap), length 1439")
    }
  }

  func testGivenDeadlineJustAfterMidnight_WhenBuildingWrapAnchor_ThenWrapsModulo1440() {
    let deadline = date(0, 3, 0)        // 00:03 exact
    let (start, end) = DeviceActivityCenterUtil.wrapAnchorInterval(endingAt: deadline, now: date(0, 2, 30), calendar: cal)
    XCTAssertEqual(end.hour, 0); XCTAssertEqual(end.minute, 3)
    XCTAssertEqual(start.hour, 0); XCTAssertEqual(start.minute, 4)
  }
}
```

- [ ] **Step 2: Run — expect FAIL** (`type 'DeviceActivityCenterUtil' has no member 'wrapAnchorInterval'`).

- [ ] **Step 3: Implement the builder**

In `DeviceActivityCenterUtil.swift`, add immediately after `stopScheduleInterval` (:469):
```swift
  /// D-C2-2 wrap-anchor backstop interval for an absolute deadline.
  /// Produces a `repeats:true`-shaped window whose `intervalEnd` is ceil-to-minute of `deadline`
  /// and whose `intervalStart` is one minute later (mod 24h) — a 1439-minute window that is in
  /// progress at registration and delivers `intervalDidEnd` at the boundary (probe #2). Ceil
  /// guarantees the callback can only be LATE, never early (never-early gate, #205 class).
  static func wrapAnchorInterval(
    endingAt deadline: Date, now: Date, calendar: Calendar = .current
  ) -> (intervalStart: DateComponents, intervalEnd: DateComponents) {
    if deadline <= now {
      Log.warning("wrapAnchorInterval: deadline is not in the future; closer gate will expire it", category: .timer)
    }
    let hour = calendar.component(.hour, from: deadline)
    let minute = calendar.component(.minute, from: deadline)
    let second = calendar.component(.second, from: deadline)
    let nanosecond = calendar.component(.nanosecond, from: deadline)

    var endMinuteOfDay = hour * 60 + minute
    if second > 0 || nanosecond > 0 {
      endMinuteOfDay = (endMinuteOfDay + 1) % 1440   // ceil to the next minute
    }
    let anchor = (endMinuteOfDay + 1) % 1440
    let intervalEnd = DateComponents(hour: endMinuteOfDay / 60, minute: endMinuteOfDay % 60)
    let intervalStart = DateComponents(hour: anchor / 60, minute: anchor % 60)
    return (intervalStart: intervalStart, intervalEnd: intervalEnd)
  }
```

- [ ] **Step 4: Run — expect PASS** (2 tests, 61 assertions).

- [ ] **Step 5: Commit**

```bash
git add Foqos/Utils/DeviceActivityCenterUtil.swift FoqosTests/WrapAnchorIntervalTests.swift
git commit -m "feat(c2): add pure wrapAnchorInterval backstop builder (T-C2-U1, T-C2-U2)"
```

---

### Task 3: `RestrictionApplying` seam + recording spy

**Files:**
- Create: `Packages/FoqosShared/Sources/FoqosShared/RestrictionApplying.swift`
- Create: `FoqosTests/Helpers/C2Spies.swift`
- Test: `FoqosTests/RestrictionApplyingConformanceTests.swift` (new)

**Interfaces:**
- Produces: `protocol RestrictionApplying { func activateRestrictions(for: SharedData.ProfileSnapshot); func deactivateRestrictions() }`; `extension AppBlockerUtil: RestrictionApplying {}`; test spy `RecordingRestrictionApplier`. Consumed by Tasks 6, 7, 9, 13–16.

- [ ] **Step 1: Write the failing conformance + spy test**

`FoqosTests/RestrictionApplyingConformanceTests.swift`:
```swift
import XCTest
@testable import FamilyFoqos
@preconcurrency import FoqosShared

final class RestrictionApplyingConformanceTests: XCTestCase {
  func testGivenAppBlockerUtil_WhenUsedAsRestrictionApplying_ThenConforms() {
    let applier: RestrictionApplying = AppBlockerUtil()   // compile-time proof of conformance
    XCTAssertNotNil(applier)
  }

  func testGivenSpy_WhenActivateThenDeactivate_ThenRecordsOrderedCalls() {
    let spy = RecordingRestrictionApplier()
    let pid = UUID()
    let snap = SharedData.ProfileSnapshot(
      id: pid, name: "P", selectedActivity: .init(), createdAt: Date(), updatedAt: Date(),
      order: 0, enableLiveActivity: false, enableBreaks: false, enableStrictMode: false,
      enableAllowMode: false, enableAllowModeDomains: false, enableSafariBlocking: false)
    spy.activateRestrictions(for: snap)
    spy.deactivateRestrictions()
    XCTAssertEqual(spy.calls, [.activate(profileId: pid), .deactivate])
  }
}
```

- [ ] **Step 2: Run — expect FAIL** (no `RestrictionApplying`, no `RecordingRestrictionApplier`).

- [ ] **Step 3: Create the protocol + conformance**

`RestrictionApplying.swift`:
```swift
import Foundation

/// Lock-free restriction applier seam (G15). `AppBlockerUtil` already implements both methods,
/// so its conformance is empty. C2 primitives take a `RestrictionApplying` (default `AppBlockerUtil()`)
/// so tests can inject a recording spy — no `ManagedSettingsStore` needed in unit tests.
public protocol RestrictionApplying {
  func activateRestrictions(for profile: SharedData.ProfileSnapshot)
  func deactivateRestrictions()
}

extension AppBlockerUtil: RestrictionApplying {}
```

- [ ] **Step 4: Create the spy helper**

`FoqosTests/Helpers/C2Spies.swift`:
```swift
import Foundation
@preconcurrency import FoqosShared

/// Records applier calls in order. `onActivate`/`onDeactivate` fire synchronously inside the
/// caller's critical section — used by I1 atomicity tests to snapshot persisted state at apply time.
final class RecordingRestrictionApplier: RestrictionApplying {
  enum Call: Equatable { case activate(profileId: UUID); case deactivate }
  private(set) var calls: [Call] = []
  var onActivate: ((SharedData.ProfileSnapshot) -> Void)?
  var onDeactivate: (() -> Void)?
  func activateRestrictions(for profile: SharedData.ProfileSnapshot) {
    calls.append(.activate(profileId: profile.id)); onActivate?(profile)
  }
  func deactivateRestrictions() { calls.append(.deactivate); onDeactivate?() }
}
```

- [ ] **Step 5: Run — expect PASS** (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Packages/FoqosShared/Sources/FoqosShared/RestrictionApplying.swift FoqosTests/Helpers/C2Spies.swift FoqosTests/RestrictionApplyingConformanceTests.swift
git commit -m "feat(c2): add RestrictionApplying seam + recording spy"
```

---

### Task 4: Pure `RestrictionDecision` derivation table (D-C2-4)

**Files:**
- Create: `Packages/FoqosShared/Sources/FoqosShared/RestrictionDecision.swift`
- Test: `FoqosTests/RestrictionDecisionTests.swift` (new)

**Interfaces:**
- Produces: `enum RestrictionDecision { case deactivate; case activate(SharedData.ProfileSnapshot); case bailPreserve }`; `enum RestrictionProcess { case mainApp; case monitorExtension }`; `SharedData.hasOpenGrant(_:) -> Bool`; `SharedData.deriveRestriction(session:liveSnapshot:process:) -> RestrictionDecision`. Consumed by Task 9's applier and the reconciler.

- [ ] **Step 1: Write the failing per-process table + precedence + ended-but-present tests (T-C2-U20/U26/U32)**

`FoqosTests/RestrictionDecisionTests.swift`:
```swift
import XCTest
@testable import FamilyFoqos
@preconcurrency import FoqosShared

final class RestrictionDecisionTests: XCTestCase {
  private func session(
    id: String = "s", pid: UUID = UUID(), endTime: Date? = nil,
    breakStart: Date? = nil, breakEnd: Date? = nil, omm: Date? = nil,
    pinned: SharedData.ProfileSnapshot? = nil
  ) -> SharedData.SessionSnapshot {
    SharedData.SessionSnapshot(
      id: id, tag: "t", blockedProfileId: pid, startTime: Date(), endTime: endTime,
      breakStartTime: breakStart, breakEndTime: breakEnd, forceStarted: false,
      oneMoreMinuteStartTime: omm, pinnedProfileConfig: pinned)
  }
  private func snapshot(_ pid: UUID) -> SharedData.ProfileSnapshot {
    SharedData.ProfileSnapshot(
      id: pid, name: "P", selectedActivity: .init(), createdAt: Date(), updatedAt: Date(),
      order: 0, enableLiveActivity: false, enableBreaks: true, enableStrictMode: false,
      enableAllowMode: false, enableAllowModeDomains: false, enableSafariBlocking: false)
  }

  func testGivenNoSession_WhenDerivingPerProcess_ThenMainDeactivatesExtensionBails() {
    XCTAssertEqual(SharedData.deriveRestriction(session: nil, liveSnapshot: nil, process: .mainApp), .deactivate)
    XCTAssertEqual(SharedData.deriveRestriction(session: nil, liveSnapshot: nil, process: .monitorExtension), .bailPreserve)
  }

  func testGivenOpenBreak_WhenDeriving_ThenBothProcessesDeactivate() {
    let now = Date()
    let s = session(breakStart: now)  // breakEnd nil ⇒ open
    XCTAssertEqual(SharedData.deriveRestriction(session: s, liveSnapshot: nil, process: .mainApp), .deactivate)
    XCTAssertEqual(SharedData.deriveRestriction(session: s, liveSnapshot: nil, process: .monitorExtension), .deactivate)
  }

  func testGivenOpenOMM_WhenDeriving_ThenBothProcessesDeactivate() {
    let s = session(omm: Date())
    XCTAssertEqual(SharedData.deriveRestriction(session: s, liveSnapshot: nil, process: .mainApp), .deactivate)
    XCTAssertEqual(SharedData.deriveRestriction(session: s, liveSnapshot: nil, process: .monitorExtension), .deactivate)
  }

  func testGivenNoGrantWithLiveSnapshot_WhenDeriving_ThenActivateWithLive() {
    let pid = UUID()
    let s = session(pid: pid)
    let live = snapshot(pid)
    XCTAssertEqual(SharedData.deriveRestriction(session: s, liveSnapshot: live, process: .mainApp), .activate(live))
    XCTAssertEqual(SharedData.deriveRestriction(session: s, liveSnapshot: live, process: .monitorExtension), .activate(live))
  }

  func testGivenNoGrantNoLiveNoPin_WhenDeriving_ThenBailPreserveBothProcesses() {
    let s = session()
    XCTAssertEqual(SharedData.deriveRestriction(session: s, liveSnapshot: nil, process: .mainApp), .bailPreserve)
    XCTAssertEqual(SharedData.deriveRestriction(session: s, liveSnapshot: nil, process: .monitorExtension), .bailPreserve)
  }

  func testGivenNoGrantNoLiveButPinned_WhenDeriving_ThenActivateWithPinned() {
    let pid = UUID()
    let pinned = snapshot(pid)
    let s = session(pid: pid, pinned: pinned)
    XCTAssertEqual(SharedData.deriveRestriction(session: s, liveSnapshot: nil, process: .mainApp), .activate(pinned))
  }

  func testGivenLiveAndPinnedBothPresent_WhenDeriving_ThenLiveWins() {
    let pid = UUID()
    let live = snapshot(pid); var pinned = snapshot(pid); pinned.name = "Pinned"
    let s = session(pid: pid, pinned: pinned)
    XCTAssertEqual(SharedData.deriveRestriction(session: s, liveSnapshot: live, process: .mainApp), .activate(live))
  }

  func testGivenEndedButPresentSession_WhenDeriving_ThenTreatedAsNoSession() {
    let s = session(endTime: Date(), breakStart: nil)  // ended, no grant
    XCTAssertEqual(SharedData.deriveRestriction(session: s, liveSnapshot: nil, process: .mainApp), .deactivate)
    XCTAssertEqual(SharedData.deriveRestriction(session: s, liveSnapshot: nil, process: .monitorExtension), .bailPreserve)
  }
}
```

- [ ] **Step 2: Run — expect FAIL** (no `deriveRestriction`).

- [ ] **Step 3: Implement the pure deriver**

`RestrictionDecision.swift`:
```swift
import Foundation

/// D-C2-4 derived restriction state. Pure; no side effects, no seam.
public enum RestrictionDecision: Equatable {
  case deactivate                              // restrictions OFF
  case activate(SharedData.ProfileSnapshot)    // restrictions ON with this config
  case bailPreserve                            // leave current restrictions untouched
}

/// Which process is deriving — the "no session" arm differs (D-C2-4 per-process authority).
public enum RestrictionProcess { case mainApp; case monitorExtension }

extension SharedData {
  /// A grant is open (restrictions should be OFF) iff a break is open OR an OMM is open — raw fields (I11).
  public static func hasOpenGrant(_ s: SessionSnapshot) -> Bool {
    let breakOpen = s.breakStartTime != nil && s.breakEndTime == nil
    let ommOpen = s.oneMoreMinuteStartTime != nil
    return breakOpen || ommOpen
  }

  /// Pure derivation of the desired restriction state from persisted state (D-C2-4).
  /// "Active shared session" = present AND `endTime == nil` (rev-6); ended-but-present ⇒ no session.
  public static func deriveRestriction(
    session: SessionSnapshot?, liveSnapshot: ProfileSnapshot?, process: RestrictionProcess
  ) -> RestrictionDecision {
    guard let session, session.endTime == nil else {
      // No active session. Only the main app may turn restrictions OFF on absence (G17 class (i) safety).
      switch process {
      case .mainApp: return .deactivate
      case .monitorExtension: return .bailPreserve
      }
    }
    if hasOpenGrant(session) { return .deactivate }
    // No open grant ⇒ ON. Config precedence: live snapshot → session-pinned config → bail-and-preserve.
    if let live = liveSnapshot { return .activate(live) }
    if let pinned = session.pinnedProfileConfig { return .activate(pinned) }
    return .bailPreserve
  }
}
```

- [ ] **Step 4: Run — expect PASS** (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/FoqosShared/Sources/FoqosShared/RestrictionDecision.swift FoqosTests/RestrictionDecisionTests.swift
git commit -m "feat(c2): add pure RestrictionDecision per-process derivation (T-C2-U20, U26, U32)"
```

---
### Task 5: Section runner + encode-then-commit raw session seam (D-C2-4(ii)(iii), rev-6 bounded-lock)

**Files:**
- Modify: `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift` (add near `withLock` :78–99; the raw seam must live in this file to reach the `private` `suite`/`Key`/`clearLegacy`)
- Test: `FoqosTests/SharedDataC2SeamTests.swift` (new)

**Interfaces:**
- Produces: `enum SharedData.LockOutcome { case acquired; case degraded }`; `SharedData.withLockStatus(blocking:_:)`; `SharedData.rawActiveSession`; `SharedData.rawCommitActiveSession(_:encode:) -> Bool`. Consumed by Tasks 6–10.

**Why:** the shipped `withLock` proceeds *unlocked* on three failure paths with no signal (:79–96) — openers must fail-closed on that (D-C2-4). The shipped `activeSharedSession` **setter deletes the key on encode failure** (:379) — a C2 grant write could destroy the session it grants against (X38). And a *suspended* main app holding the flock would wedge every extension wake behind a blocking `LOCK_EX` (rev-6) — the extension must acquire non-blocking with bounded retry.

> **CONFIRM-ON-IMPLEMENT:** the DEBUG lock-path seam is `SharedData.configureLockPath(_:)` / `resetLockPath()` (`SharedData.swift:41–56`). Tests below force the degraded path by making `lockPath` nil through that seam; confirm the exact call that yields `nil` when wiring the test (grounding verified the seam exists; it did not capture the parameter type).

- [ ] **Step 1: Write the failing seam tests (encode-then-commit + degraded-lock signalling — T-C2-U30 seam level)**

`FoqosTests/SharedDataC2SeamTests.swift`:
```swift
import XCTest
@preconcurrency import FoqosShared
@testable import FamilyFoqos

final class SharedDataC2SeamTests: XCTestCase {
  private static let testSuiteName = "SharedDataC2SeamTests-\(UUID().uuidString)"
  override func setUp() { super.setUp(); SharedData.configure(suite: UserDefaults(suiteName: Self.testSuiteName)!) }
  override func tearDown() {
    SharedData.resetLockPath()  // restore default lock path if a test forced degraded mode
    UserDefaults().removePersistentDomain(forName: Self.testSuiteName); super.tearDown()
  }

  private func session(_ id: String) -> SharedData.SessionSnapshot {
    SharedData.SessionSnapshot(id: id, tag: "t", blockedProfileId: UUID(), startTime: Date(), forceStarted: false)
  }
  private enum Boom: Error { case boom }

  func testGivenEncodeFails_WhenRawCommit_ThenStorageUntouchedAndReturnsFalse() {
    SharedData.createActiveSharedSession(for: session("original"))
    let ok = SharedData.rawCommitActiveSession(session("replacement"), encode: { _ in throw Boom.boom })
    XCTAssertFalse(ok)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, "original", "encode failure must NOT delete or overwrite the key")
  }

  func testGivenEncodeSucceeds_WhenRawCommit_ThenStorageUpdatedReturnsTrue() {
    SharedData.createActiveSharedSession(for: session("original"))
    let ok = SharedData.rawCommitActiveSession(session("replacement"))
    XCTAssertTrue(ok)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, "replacement")
  }

  func testGivenNilLockPath_WhenWithLockStatus_ThenReportsDegraded() {
    SharedData.configureLockPath(nil)  // force the proceed-unlocked branch
    let outcome = SharedData.withLockStatus(blocking: true) { $0 }
    XCTAssertEqual(outcome, .degraded)
  }

  func testGivenNormalLockPath_WhenWithLockStatus_ThenReportsAcquired() {
    let outcome = SharedData.withLockStatus(blocking: true) { $0 }
    XCTAssertEqual(outcome, .acquired)
  }

  func testGivenHeldLock_WhenNonBlockingAcquire_ThenDegradesWithinBoundedCeiling() {  // T-C2-U33 (rev-6)
    // A held flock must NOT wedge a non-blocking acquirer (the extension): LOCK_NB + bounded retry
    // times out to .degraded. Two separate open() descriptions contend even within one process.
    let path = NSTemporaryDirectory() + "c2-lock-\(UUID().uuidString)"
    SharedData.configureLockPath(path)
    let holder = open(path, O_CREAT | O_RDWR, 0o644)
    XCTAssertGreaterThanOrEqual(holder, 0)
    XCTAssertEqual(flock(holder, LOCK_EX), 0, "hold the lock on a separate fd")
    let start = Date()
    let outcome = SharedData.withLockStatus(blocking: false) { $0 }   // non-blocking acquirer
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertEqual(outcome, .degraded, "held lock ⇒ non-blocking acquire degrades, never wedges")
    XCTAssertLessThan(elapsed, 2.0, "bounded retry ceiling (~0.5s), never indefinite")
    flock(holder, LOCK_UN); close(holder)
  }
}
```
(`open`/`flock`/`LOCK_EX`/`LOCK_NB` are POSIX symbols available via the Darwin overlay that `import Foundation` brings in; `XCTest` already imports it.)

- [ ] **Step 2: Run — expect FAIL** (no `withLockStatus` / `rawCommitActiveSession` / `rawActiveSession`).

- [ ] **Step 3: Implement the section runner + raw seam in `SharedData.swift`**

Add in `SharedData.swift` (same file, after `withLock`):
```swift
  /// Result of a C2 critical-section acquisition. `.degraded` = proceeded unlocked (shipped fallback).
  public enum LockOutcome: Equatable { case acquired; case degraded }

  /// Like `withLock` but reports whether a real flock was acquired (D-C2-4 surfaces acquisition
  /// failure). `blocking == false` uses `LOCK_NB` + bounded retry so a *suspended* holder cannot
  /// wedge the extension (rev-6); on timeout the body runs in `.degraded` mode, never blocking.
  public static func withLockStatus<T>(blocking: Bool, _ body: (LockOutcome) -> T) -> T {
    guard let lockPath else {
      lockLog.warning("SharedData: no lockPath (test mode?) — proceeding unlocked")
      return body(.degraded)
    }
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else {
      lockLog.warning("SharedData: open() failed, errno \(errno) — proceeding unlocked")
      return body(.degraded)
    }
    defer { close(fd) }

    if blocking {
      var ret: Int32 = -1
      repeat { ret = flock(fd, LOCK_EX) } while ret != 0 && errno == EINTR
      guard ret == 0 else {
        lockLog.warning("SharedData: flock(LOCK_EX) failed, errno \(errno) — proceeding unlocked")
        return body(.degraded)
      }
    } else {
      // Non-blocking bounded retry: never wedge behind a frozen holder.
      var acquired = false
      for _ in 0..<50 {  // ~50 * 10ms ≈ 0.5s ceiling, well under the extension watchdog
        let ret = flock(fd, LOCK_NB | LOCK_EX)
        if ret == 0 { acquired = true; break }
        if errno != EWOULDBLOCK && errno != EINTR { break }
        usleep(10_000)
      }
      guard acquired else {
        lockLog.warning("SharedData: LOCK_NB timed out — proceeding unlocked (degraded)")
        return body(.degraded)
      }
    }
    defer { flock(fd, LOCK_UN) }
    return body(.acquired)
  }

  /// Raw active-session read for use INSIDE a section (reads `suite` directly; does not lock).
  internal static var rawActiveSession: SessionSnapshot? { activeSharedSession }

  /// Encode-then-commit raw active-session write (D-C2-4(iii)). On encode failure the stored value
  /// is left UNTOUCHED (never deleted, unlike the shipped setter :375–383) and returns false.
  /// MUST be called inside a `withLockStatus`/`withLock` body. `encode` is injectable for tests.
  @discardableResult
  internal static func rawCommitActiveSession(
    _ snapshot: SessionSnapshot?,
    encode: (SessionSnapshot) throws -> Data = { try JSONEncoder().encode($0) }
  ) -> Bool {
    guard let snapshot else {
      suite.removeObject(forKey: Key.activeScheduleSession.rawValue)
      clearLegacy(.activeScheduleSession)
      return true
    }
    guard let data = try? encode(snapshot) else {
      Log.error("rawCommitActiveSession: encode failed — leaving stored session untouched (X38)", category: .session)
      return false
    }
    suite.set(data, forKey: Key.activeScheduleSession.rawValue)
    clearLegacy(.activeScheduleSession)
    return true
  }
```
(`lockLog`, `lockPath`, `suite`, `Key`, `clearLegacy` are the existing private members — reachable because this code is in `SharedData.swift`.)

- [ ] **Step 4: Run — expect PASS** (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/FoqosShared/Sources/FoqosShared/SharedData.swift FoqosTests/SharedDataC2SeamTests.swift
git commit -m "feat(c2): add withLockStatus + encode-then-commit raw session seam (T-C2-U30, U33)"
```

---

### Task 6: Grant openers `openBreakGrant` / `openOneMoreMinuteGrant` (§6.2/§6.3)

**Files:**
- Create: `Packages/FoqosShared/Sources/FoqosShared/RestrictionGrants.swift`
- Test: `FoqosTests/RestrictionGrantsOpenTests.swift` (new)

**Interfaces:**
- Consumes: `RestrictionApplying` (Task 3), `deriveRestriction`/`hasOpenGrant` (Task 4), `withLockStatus`/`rawActiveSession`/`rawCommitActiveSession` (Task 5).
- Produces (all `SharedData` static methods):
  - `applyDecision(_ decision: RestrictionDecision, applier: RestrictionApplying)` — the thin applier.
  - `@discardableResult openBreakGrant(startDate:deadline:expectedSessionId:liveSnapshot:applier:commit:) -> Bool`
  - `@discardableResult openOneMoreMinuteGrant(startDate:deadline:expectedSessionId:liveSnapshot:applier:commit:) -> Bool`
  Consumed by `StrategyManager` (Tasks 13/14).

**Openers are main-app-only** (BLOCKING→OMM_OPEN and →BREAK_OPEN happen only in the foreground app, §5). Both run one `withLockStatus(blocking: true)` section: identity gate → own-family / cross-family refusal → pin (absent ⇒ refuse) → build snapshot (OMM absorption for break) → encode-then-commit → derive-and-apply (→ OFF). Any failure returns `false` with **no state change and no restriction change** (atomic, D-C2-4).

- [ ] **Step 1: Write the failing opener tests (T-C2-U9, U12, U15, U23, U24, U27, U30, U34)**

`FoqosTests/RestrictionGrantsOpenTests.swift`:
```swift
import XCTest
@testable import FamilyFoqos
@preconcurrency import FoqosShared

final class RestrictionGrantsOpenTests: XCTestCase {
  private static let testSuiteName = "RestrictionGrantsOpenTests-\(UUID().uuidString)"
  override func setUp() { super.setUp(); SharedData.configure(suite: UserDefaults(suiteName: Self.testSuiteName)!) }
  override func tearDown() { SharedData.resetLockPath(); UserDefaults().removePersistentDomain(forName: Self.testSuiteName); super.tearDown() }

  private func liveSnap(_ pid: UUID) -> SharedData.ProfileSnapshot {
    SharedData.ProfileSnapshot(
      id: pid, name: "P", selectedActivity: .init(), createdAt: Date(), updatedAt: Date(),
      order: 0, enableLiveActivity: false, enableBreaks: true, enableStrictMode: false,
      enableAllowMode: false, enableAllowModeDomains: false, enableSafariBlocking: false)
  }
  /// Seed an active blocking session and return (sessionId, profileId).
  @discardableResult
  private func seedSession(breakStart: Date? = nil, breakEnd: Date? = nil, omm: Date? = nil,
                           ommUsed: Bool = false, pid: UUID = UUID()) -> (String, UUID) {
    let s = SharedData.SessionSnapshot(
      id: "sess-1", tag: "t", blockedProfileId: pid, startTime: Date(), forceStarted: false,
      breakStartTime: breakStart, breakEndTime: breakEnd, oneMoreMinuteUsed: ommUsed,
      oneMoreMinuteStartTime: omm)
    SharedData.createActiveSharedSession(for: s)
    return (s.id, pid)
  }

  func testGivenActiveSession_WhenOpenBreakGrant_ThenLiftsAndPersistsDeadlineAndPin() {
    let now = Date()
    let (sid, pid) = seedSession()
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.openBreakGrant(
      startDate: now, deadline: now.addingTimeInterval(300), expectedSessionId: sid,
      liveSnapshot: liveSnap(pid), applier: spy)
    XCTAssertTrue(ok)
    let after = SharedData.getActiveSharedSession()
    XCTAssertEqual(after?.breakStartTime, now)
    XCTAssertEqual(after?.breakEndDeadline, now.addingTimeInterval(300))
    XCTAssertEqual(after?.pinnedProfileConfig?.id, pid)
    XCTAssertEqual(spy.calls, [.deactivate])
  }

  func testGivenOpenBreakGrant_WhenApplierFires_ThenStateAlreadyCommitted() {  // I1 atomicity, U12
    let now = Date(); let (sid, pid) = seedSession()
    let spy = RecordingRestrictionApplier()
    spy.onDeactivate = {
      let s = SharedData.rawActiveSession
      XCTAssertEqual(s?.breakStartTime, now, "deadline+start committed BEFORE the lift")
      XCTAssertEqual(s?.breakEndDeadline, now.addingTimeInterval(300))
    }
    _ = SharedData.openBreakGrant(startDate: now, deadline: now.addingTimeInterval(300),
      expectedSessionId: sid, liveSnapshot: liveSnap(pid), applier: spy)
  }

  func testGivenWrongSessionId_WhenOpenBreakGrant_ThenFalseNoStateNoLift() {  // U9
    let now = Date(); let (_, pid) = seedSession()
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.openBreakGrant(startDate: now, deadline: now.addingTimeInterval(300),
      expectedSessionId: "stale", liveSnapshot: liveSnap(pid), applier: spy)
    XCTAssertFalse(ok)
    XCTAssertNil(SharedData.getActiveSharedSession()?.breakStartTime)
    XCTAssertTrue(spy.calls.isEmpty)
  }

  func testGivenOpenOMM_WhenOpenBreakGrant_ThenAbsorbsOMMKeepsUsed() {  // U15 / I9
    let now = Date(); let (sid, pid) = seedSession(omm: now.addingTimeInterval(-10), ommUsed: true)
    let ok = SharedData.openBreakGrant(startDate: now, deadline: now.addingTimeInterval(300),
      expectedSessionId: sid, liveSnapshot: liveSnap(pid), applier: RecordingRestrictionApplier())
    XCTAssertTrue(ok)
    let after = SharedData.getActiveSharedSession()
    XCTAssertNotNil(after?.breakStartTime)
    XCTAssertNil(after?.oneMoreMinuteStartTime, "OMM absorbed")
    XCTAssertNil(after?.oneMoreMinuteDeadline)
    XCTAssertTrue(after?.oneMoreMinuteUsed ?? false, "used stays true")
  }

  func testGivenBreakAlreadyOpen_WhenOpenBreakGrant_ThenRefused() {  // U34 own-family
    let now = Date(); let (sid, pid) = seedSession(breakStart: now.addingTimeInterval(-5))
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.openBreakGrant(startDate: now, deadline: now.addingTimeInterval(300),
      expectedSessionId: sid, liveSnapshot: liveSnap(pid), applier: spy)
    XCTAssertFalse(ok); XCTAssertTrue(spy.calls.isEmpty)
  }

  func testGivenBreakOpen_WhenOpenOMM_ThenRefusedNoState() {  // U23 / I9 second direction
    let now = Date(); let (sid, pid) = seedSession(breakStart: now.addingTimeInterval(-5))
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.openOneMoreMinuteGrant(startDate: now, deadline: now.addingTimeInterval(60),
      expectedSessionId: sid, liveSnapshot: liveSnap(pid), applier: spy)
    XCTAssertFalse(ok)
    XCTAssertNil(SharedData.getActiveSharedSession()?.oneMoreMinuteStartTime)
    XCTAssertTrue(spy.calls.isEmpty)
  }

  func testGivenNoLiveSnapshot_WhenOpenBreakGrant_ThenRefusedFailClosed() {  // U24 / X36
    let now = Date(); let (sid, _) = seedSession()
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.openBreakGrant(startDate: now, deadline: now.addingTimeInterval(300),
      expectedSessionId: sid, liveSnapshot: nil, applier: spy)
    XCTAssertFalse(ok); XCTAssertNil(SharedData.getActiveSharedSession()?.breakStartTime)
    XCTAssertTrue(spy.calls.isEmpty)
  }

  func testGivenDegradedLock_WhenOpenBreakGrant_ThenAbortsFailClosed() {  // U27
    let now = Date(); let (sid, pid) = seedSession()
    SharedData.configureLockPath(nil)  // force degraded acquisition
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.openBreakGrant(startDate: now, deadline: now.addingTimeInterval(300),
      expectedSessionId: sid, liveSnapshot: liveSnap(pid), applier: spy)
    XCTAssertFalse(ok); XCTAssertTrue(spy.calls.isEmpty)
  }

  func testGivenCommitFails_WhenOpenBreakGrant_ThenFalseNoLift() {  // U30 primitive level
    let now = Date(); let (sid, pid) = seedSession()
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.openBreakGrant(startDate: now, deadline: now.addingTimeInterval(300),
      expectedSessionId: sid, liveSnapshot: liveSnap(pid), applier: spy, commit: { _ in false })
    XCTAssertFalse(ok); XCTAssertTrue(spy.calls.isEmpty)
  }
}
```

- [ ] **Step 2: Run — expect FAIL** (no `openBreakGrant`).

- [ ] **Step 3: Implement the openers + applier**

`RestrictionGrants.swift`:
```swift
import Foundation

extension SharedData {
  /// Thin applier for a derived decision (D-C2-4 "pure core + thin applier").
  static func applyDecision(_ decision: RestrictionDecision, applier: RestrictionApplying) {
    switch decision {
    case .deactivate: applier.deactivateRestrictions()
    case .activate(let profile): applier.activateRestrictions(for: profile)
    case .bailPreserve: break
    }
  }

  /// §6.2 — open a break grant. ONE main-app critical section. Returns whether the grant opened.
  @discardableResult
  public static func openBreakGrant(
    startDate: Date, deadline: Date, expectedSessionId: String,
    liveSnapshot: ProfileSnapshot?,
    applier: RestrictionApplying = AppBlockerUtil(),
    commit: (SessionSnapshot?) -> Bool = { rawCommitActiveSession($0) }
  ) -> Bool {
    withLockStatus(blocking: true) { outcome in
      guard outcome == .acquired else { return false }                       // D-C2-3 fail-closed on degraded lock
      guard var session = rawActiveSession, session.endTime == nil,
            session.id == expectedSessionId else { return false }            // I8 identity + active
      guard session.breakStartTime == nil else { return false }              // U34 own-family: no re-break (open or consumed)
      guard let pinned = liveSnapshot else { return false }                  // §6.1a pin absent ⇒ refuse (X36)

      session.breakStartTime = startDate
      session.breakEndDeadline = deadline
      session.pinnedProfileConfig = pinned
      // I9 / MD-C2-2=A: a break absorbs any open OMM (keep `oneMoreMinuteUsed`).
      session.oneMoreMinuteStartTime = nil
      session.oneMoreMinuteDeadline = nil

      guard commit(session) else { return false }                           // X38 encode-then-commit, before any lift
      applyDecision(deriveRestriction(session: session, liveSnapshot: pinned, process: .mainApp), applier: applier)
      return true
    }
  }

  /// §6.3 — open a one-more-minute grant. ONE main-app critical section.
  @discardableResult
  public static func openOneMoreMinuteGrant(
    startDate: Date, deadline: Date, expectedSessionId: String,
    liveSnapshot: ProfileSnapshot?,
    applier: RestrictionApplying = AppBlockerUtil(),
    commit: (SessionSnapshot?) -> Bool = { rawCommitActiveSession($0) }
  ) -> Bool {
    withLockStatus(blocking: true) { outcome in
      guard outcome == .acquired else { return false }
      guard var session = rawActiveSession, session.endTime == nil,
            session.id == expectedSessionId else { return false }
      // I9 second direction: refuse if a break is open on raw fields (X32).
      guard !(session.breakStartTime != nil && session.breakEndTime == nil) else { return false }
      guard session.oneMoreMinuteStartTime == nil else { return false }      // no double-open
      guard let pinned = liveSnapshot else { return false }                  // §6.1a pin absent ⇒ refuse

      session.oneMoreMinuteStartTime = startDate
      session.oneMoreMinuteDeadline = deadline
      session.oneMoreMinuteUsed = true
      session.pinnedProfileConfig = pinned

      guard commit(session) else { return false }
      applyDecision(deriveRestriction(session: session, liveSnapshot: pinned, process: .mainApp), applier: applier)
      return true
    }
  }
}
```

- [ ] **Step 4: Run — expect PASS** (9 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/FoqosShared/Sources/FoqosShared/RestrictionGrants.swift FoqosTests/RestrictionGrantsOpenTests.swift
git commit -m "feat(c2): add openBreakGrant/openOneMoreMinuteGrant critical sections (T-C2-U9,U12,U15,U23,U24,U27,U30,U34)"
```

---
### Task 7: Shared closers `closeBreakGrantIfExpiredOrExplicit` / `closeOneMoreMinuteGrantIfExpired` (§6.5)

**Files:**
- Modify: `Packages/FoqosShared/Sources/FoqosShared/RestrictionGrants.swift`
- Test: `FoqosTests/RestrictionGrantsCloseTests.swift` (new)

**Interfaces:**
- Produces:
  - `@discardableResult closeBreakGrantIfExpiredOrExplicit(expectedSessionId:explicit:now:process:durationMinutes:liveSnapshot:applier:commit:) -> Bool`
  - `@discardableResult closeOneMoreMinuteGrantIfExpired(expectedSessionId:now:process:liveSnapshot:applier:commit:) -> Bool`
  Consumed by the extension handlers (Task 11), the ticker (Task 16), the reconciler (Task 10), and `stopBreak` (Task 15).

**I6 gates (all in one section):** identity → raw-field open gate → deadline gate (`now >= deadline`, skipped when `explicit`). Nil-deadline (legacy) grants are **stamped once** in-section: break duration from `durationMinutes` (nil ⇒ **not stampable, not expired, no close, no zero-default** — I6(c)/U22); OMM duration is the 60s constant (always stampable). The stamp is **persisted** even when not-yet-expired so a later profile edit cannot move it (I11/X31). Terminal write is a CAS (`breakEndTime` set iff nil; OMM fields cleared iff non-nil), then encode-then-commit, then derive-and-apply. The OMM closer's **break-active branch** clears OMM fields without re-blocking (#205 defense, X7). Closers proceed best-effort under a degraded lock (no fail-closed); the main app acquires blocking, the extension non-blocking (rev-6).

- [ ] **Step 1: Write the failing closer tests (T-C2-U3, U4, U5, U6, U7, U19, U22, U30, U33)**

`FoqosTests/RestrictionGrantsCloseTests.swift`:
```swift
import XCTest
@testable import FamilyFoqos
@preconcurrency import FoqosShared

final class RestrictionGrantsCloseTests: XCTestCase {
  private static let testSuiteName = "RestrictionGrantsCloseTests-\(UUID().uuidString)"
  override func setUp() { super.setUp(); SharedData.configure(suite: UserDefaults(suiteName: Self.testSuiteName)!) }
  override func tearDown() { SharedData.resetLockPath(); UserDefaults().removePersistentDomain(forName: Self.testSuiteName); super.tearDown() }

  private func snap(_ pid: UUID, enableBreaks: Bool = true, breakMinutes: Int = 5) -> SharedData.ProfileSnapshot {
    SharedData.ProfileSnapshot(
      id: pid, name: "P", selectedActivity: .init(), createdAt: Date(), updatedAt: Date(),
      order: 0, enableLiveActivity: false, enableBreaks: enableBreaks, breakTimeInMinutes: breakMinutes,
      enableStrictMode: false, enableAllowMode: false, enableAllowModeDomains: false, enableSafariBlocking: false)
  }
  @discardableResult
  private func seed(breakStart: Date? = nil, breakEnd: Date? = nil, breakDeadline: Date? = nil,
                    omm: Date? = nil, ommDeadline: Date? = nil, ommUsed: Bool = false,
                    pid: UUID = UUID(), pinned: SharedData.ProfileSnapshot? = nil) -> (String, UUID) {
    let s = SharedData.SessionSnapshot(
      id: "sess-1", tag: "t", blockedProfileId: pid, startTime: Date(), forceStarted: false,
      breakStartTime: breakStart, breakEndTime: breakEnd, oneMoreMinuteUsed: ommUsed,
      oneMoreMinuteStartTime: omm, breakEndDeadline: breakDeadline, oneMoreMinuteDeadline: ommDeadline,
      pinnedProfileConfig: pinned)
    SharedData.createActiveSharedSession(for: s)
    return (s.id, pid)
  }

  // ---- break closer CAS matrix (U3) ----
  func testGivenExpiredBreak_WhenClose_ThenClosesOnceAndReblocks() {
    let now = Date()
    let (sid, pid) = seed(breakStart: now.addingTimeInterval(-600), breakDeadline: now.addingTimeInterval(-1))
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid, explicit: false, now: now, process: .mainApp,
      durationMinutes: nil, liveSnapshot: snap(pid), applier: spy)
    XCTAssertTrue(ok)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.breakEndTime, now)
    XCTAssertEqual(spy.calls, [.activate(profileId: pid)])
    // repeat ⇒ false (already closed)
    let again = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid, explicit: false, now: now, process: .mainApp,
      durationMinutes: nil, liveSnapshot: snap(pid), applier: RecordingRestrictionApplier())
    XCTAssertFalse(again)
  }

  func testGivenIdentityMismatch_WhenCloseBreak_ThenFalseNoChange() {
    let now = Date()
    let (_, pid) = seed(breakStart: now.addingTimeInterval(-600), breakDeadline: now.addingTimeInterval(-1))
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: "stale", explicit: false, now: now, process: .mainApp,
      durationMinutes: nil, liveSnapshot: snap(pid), applier: spy)
    XCTAssertFalse(ok); XCTAssertNil(SharedData.getActiveSharedSession()?.breakEndTime); XCTAssertTrue(spy.calls.isEmpty)
  }

  // ---- deadline gate (U5) + explicit early-end ----
  func testGivenUnexpiredBreak_WhenCloseNonExplicit_ThenNoOp() {
    let now = Date()
    let (sid, pid) = seed(breakStart: now.addingTimeInterval(-60), breakDeadline: now.addingTimeInterval(240))
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid, explicit: false, now: now, process: .mainApp,
      durationMinutes: nil, liveSnapshot: snap(pid), applier: spy)
    XCTAssertFalse(ok); XCTAssertNil(SharedData.getActiveSharedSession()?.breakEndTime); XCTAssertTrue(spy.calls.isEmpty)
  }

  func testGivenUnexpiredBreak_WhenExplicitEarlyEnd_ThenClosesAndReblocks() {
    let now = Date()
    let (sid, pid) = seed(breakStart: now.addingTimeInterval(-60), breakDeadline: now.addingTimeInterval(240))
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid, explicit: true, now: now, process: .mainApp,
      durationMinutes: nil, liveSnapshot: snap(pid), applier: spy)
    XCTAssertTrue(ok)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.breakEndTime, now)
    XCTAssertEqual(spy.calls, [.activate(profileId: pid)])
  }

  // ---- nil-deadline stamp migration (U22) ----
  func testGivenLegacyNilDeadline_WhenCloseWithDuration_ThenStampsOnceThenGates() {
    let now = Date()
    // break started 6 min ago; duration 5 ⇒ stamped deadline = start+5 = now-1 ⇒ expired.
    let (sid, pid) = seed(breakStart: now.addingTimeInterval(-360), breakDeadline: nil)
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid, explicit: false, now: now, process: .mainApp,
      durationMinutes: 5, liveSnapshot: snap(pid), applier: spy)
    XCTAssertTrue(ok)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.breakEndTime, now)
  }

  func testGivenLegacyNilDeadlineNotYetExpired_WhenClose_ThenStampPersistsAndNoClose() {
    let now = Date()
    let (sid, pid) = seed(breakStart: now.addingTimeInterval(-60), breakDeadline: nil)  // start 1 min ago, dur 5 ⇒ deadline now+4
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid, explicit: false, now: now, process: .mainApp,
      durationMinutes: 5, liveSnapshot: snap(pid), applier: RecordingRestrictionApplier())
    XCTAssertFalse(ok)
    let stamped = SharedData.getActiveSharedSession()?.breakEndDeadline
    XCTAssertEqual(stamped, now.addingTimeInterval(-60).addingTimeInterval(300), "stamp persisted = start + 5min")
    // A later duration shrink must NOT move the stamp.
    _ = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid, explicit: false, now: now, process: .mainApp,
      durationMinutes: 1, liveSnapshot: snap(pid, breakMinutes: 1), applier: RecordingRestrictionApplier())
    XCTAssertEqual(SharedData.getActiveSharedSession()?.breakEndDeadline, stamped, "stamp is immutable after first eval (I11/X31)")
  }

  func testGivenLegacyNilDeadlineUnstampableInExtension_WhenClose_ThenNotExpiredNoClose() {  // U22 unstampable-in-X
    let now = Date()
    let (sid, _) = seed(breakStart: now.addingTimeInterval(-3600), breakDeadline: nil)
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid, explicit: false, now: now, process: .monitorExtension,
      durationMinutes: nil, liveSnapshot: nil, applier: RecordingRestrictionApplier())
    XCTAssertFalse(ok)
    XCTAssertNil(SharedData.getActiveSharedSession()?.breakEndTime, "no close")
    XCTAssertNil(SharedData.getActiveSharedSession()?.breakEndDeadline, "no zero-default stamp")
  }

  // ---- enableBreaks-off still closes (U19 / I11) ----
  func testGivenEnableBreaksOffMidGrant_WhenExpiredBreakClose_ThenStillClosesNormally() {
    let now = Date()
    let (sid, pid) = seed(breakStart: now.addingTimeInterval(-600), breakDeadline: now.addingTimeInterval(-1))
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid, explicit: false, now: now, process: .mainApp,
      durationMinutes: nil, liveSnapshot: snap(pid, enableBreaks: false), applier: spy)
    XCTAssertTrue(ok); XCTAssertEqual(spy.calls, [.activate(profileId: pid)])
  }

  // ---- OMM closer CAS (U4) + break-active branch (U6) + synthetic tolerance (U7) ----
  func testGivenExpiredOMM_WhenClose_ThenClearsAndReblocksUsedStaysTrue() {
    let now = Date()
    let (sid, pid) = seed(omm: now.addingTimeInterval(-120), ommDeadline: now.addingTimeInterval(-60), ommUsed: true)
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.closeOneMoreMinuteGrantIfExpired(
      expectedSessionId: sid, now: now, process: .mainApp, liveSnapshot: snap(pid), applier: spy)
    XCTAssertTrue(ok)
    XCTAssertNil(SharedData.getActiveSharedSession()?.oneMoreMinuteStartTime)
    XCTAssertTrue(SharedData.getActiveSharedSession()?.oneMoreMinuteUsed ?? false)
    XCTAssertEqual(spy.calls, [.activate(profileId: pid)])
  }

  func testGivenBreakOpen_WhenOMMCloserFires_ThenClearsOMMButDoesNotReblock() {  // U6 / #205
    let now = Date()
    let (sid, pid) = seed(breakStart: now.addingTimeInterval(-30), breakDeadline: now.addingTimeInterval(270),
                          omm: now.addingTimeInterval(-120), ommDeadline: now.addingTimeInterval(-60), ommUsed: true)
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.closeOneMoreMinuteGrantIfExpired(
      expectedSessionId: sid, now: now, process: .mainApp, liveSnapshot: snap(pid), applier: spy)
    XCTAssertTrue(ok)
    XCTAssertNil(SharedData.getActiveSharedSession()?.oneMoreMinuteStartTime, "OMM fields cleared")
    XCTAssertFalse(spy.calls.contains(.activate(profileId: pid)), "must NOT re-block during the break (#205)")
  }

  func testGivenAlreadyClosedBreak_WhenClose_ThenNoOp() {  // U7 synthetic-end tolerance
    let now = Date()
    let (sid, pid) = seed(breakStart: now.addingTimeInterval(-600), breakEnd: now.addingTimeInterval(-5),
                          breakDeadline: now.addingTimeInterval(-300))
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid, explicit: false, now: now, process: .mainApp,
      durationMinutes: nil, liveSnapshot: snap(pid), applier: RecordingRestrictionApplier())
    XCTAssertFalse(ok, "closed grant ⇒ synthetic/duplicate end no-ops")
  }

  // ---- commit failure (U30 closer) ----
  func testGivenCommitFails_WhenCloseBreak_ThenFalseNoReblock() {
    let now = Date()
    let (sid, pid) = seed(breakStart: now.addingTimeInterval(-600), breakDeadline: now.addingTimeInterval(-1))
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid, explicit: false, now: now, process: .mainApp,
      durationMinutes: nil, liveSnapshot: snap(pid), applier: spy, commit: { _ in false })
    XCTAssertFalse(ok); XCTAssertTrue(spy.calls.isEmpty)
  }

  // ---- extension degraded lock still closes best-effort (R8; U33's held-lock case is in SharedDataC2SeamTests) ----
  func testGivenDegradedLockInExtension_WhenExpiredBreak_ThenStillClosesBestEffort() {
    let now = Date()
    let (sid, pid) = seed(breakStart: now.addingTimeInterval(-600), breakDeadline: now.addingTimeInterval(-1),
                          pinned: snap(UUID()))
    SharedData.configureLockPath(nil)  // degraded
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid, explicit: false, now: now, process: .monitorExtension,
      durationMinutes: nil, liveSnapshot: snap(pid), applier: spy)
    XCTAssertTrue(ok, "closers proceed best-effort under degraded lock (R8)")
  }
}
```

- [ ] **Step 2: Run — expect FAIL** (no closers).

- [ ] **Step 3: Implement the closers**

Append to `RestrictionGrants.swift`:
```swift
extension SharedData {
  /// §6.5 — close a break grant if expired (or `explicit` early-end). ONE section, per-process.
  @discardableResult
  public static func closeBreakGrantIfExpiredOrExplicit(
    expectedSessionId: String, explicit: Bool, now: Date, process: RestrictionProcess,
    durationMinutes: Int?, liveSnapshot: ProfileSnapshot?,
    applier: RestrictionApplying = AppBlockerUtil(),
    commit: (SessionSnapshot?) -> Bool = { rawCommitActiveSession($0) }
  ) -> Bool {
    withLockStatus(blocking: process == .mainApp) { _ in
      guard var session = rawActiveSession, session.endTime == nil,
            session.id == expectedSessionId else { return false }            // I6(a) identity
      guard session.breakStartTime != nil, session.breakEndTime == nil else { return false }  // I6(b) raw open gate

      // I6(c) deadline gate with one-time stamp migration (skipped for explicit early-end).
      var didStamp = false
      if !explicit {
        var deadline = session.breakEndDeadline
        if deadline == nil {
          guard let minutes = durationMinutes, let start = session.breakStartTime else {
            return false                                                     // unstampable ⇒ not expired, no zero-default
          }
          deadline = start.addingTimeInterval(TimeInterval(minutes * 60))
          session.breakEndDeadline = deadline
          didStamp = true
        }
        guard let d = deadline, now >= d else {
          if didStamp { _ = commit(session) }                               // persist the stamp; grant unchanged (I11/X31)
          return false
        }
      }

      session.breakEndTime = now                                            // I3 CAS (breakEndTime was nil)
      guard commit(session) else { return false }                          // X38 encode-then-commit
      applyDecision(deriveRestriction(session: session, liveSnapshot: liveSnapshot, process: process), applier: applier)
      return true
    }
  }

  /// §6.5 / 7.3 — close a one-more-minute grant if expired (or `force`d — used by the X16 fail-closed
  /// close so it never mutates state outside the lock). Break-active branch clears without re-blocking (#205).
  @discardableResult
  public static func closeOneMoreMinuteGrantIfExpired(
    expectedSessionId: String, now: Date, process: RestrictionProcess,
    liveSnapshot: ProfileSnapshot?, force: Bool = false,
    applier: RestrictionApplying = AppBlockerUtil(),
    commit: (SessionSnapshot?) -> Bool = { rawCommitActiveSession($0) }
  ) -> Bool {
    withLockStatus(blocking: process == .mainApp) { _ in
      guard var session = rawActiveSession, session.endTime == nil,
            session.id == expectedSessionId else { return false }
      guard session.oneMoreMinuteStartTime != nil else { return false }     // OMM open gate

      let breakOpen = session.breakStartTime != nil && session.breakEndTime == nil
      var didStamp = false
      if !breakOpen && !force {
        // Deadline gate; OMM duration is the 60s constant ⇒ always stampable (both processes).
        var deadline = session.oneMoreMinuteDeadline
        if deadline == nil, let start = session.oneMoreMinuteStartTime {
          deadline = start.addingTimeInterval(60)
          session.oneMoreMinuteDeadline = deadline
          didStamp = true
        }
        guard let d = deadline, now >= d else {
          if didStamp { _ = commit(session) }   // persist ONLY a newly-written stamp (no per-tick re-commit)
          return false
        }
      }
      // Close OMM fields (CAS clear); keep `oneMoreMinuteUsed`.
      session.oneMoreMinuteStartTime = nil
      session.oneMoreMinuteDeadline = nil
      guard commit(session) else { return false }
      // If a break is still open, derive keeps OFF (no re-block, #205). Else re-block.
      applyDecision(deriveRestriction(session: session, liveSnapshot: liveSnapshot, process: process), applier: applier)
      return true
    }
  }
}
```

- [ ] **Step 4: Run — expect PASS** (13 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/FoqosShared/Sources/FoqosShared/RestrictionGrants.swift FoqosTests/RestrictionGrantsCloseTests.swift
git commit -m "feat(c2): add shared break/OMM closers with stamp migration + break-active branch (T-C2-U3,U4,U5,U6,U7,U19,U22,U30,U33)"
```

---
### Task 8: Session-end grant bookkeeping `closeGrantsForSessionEnd` + ingest normalization (§6.4)

**Files:**
- Modify: `Packages/FoqosShared/Sources/FoqosShared/RestrictionGrants.swift` (primitive + pure helpers)
- Modify: `Foqos/Models/BlockedProfileSessions.swift` (`endSession(now:)` :80–95; `upsertSessionFromSnapshot` :144–195)
- Modify: `Foqos/Utils/StrategyManager.swift` (`syncScheduleSessions` :830 — notification cancel)
- Test: `FoqosTests/SessionEndGrantTests.swift` (new)

**Interfaces:**
- Produces: `closeGrantsForSessionEnd(expectedSessionId:now:)`; pure `SharedData.normalizedForEnd(_:) -> SessionSnapshot`; pure `SharedData.endedSessionHadOpenGrant(_:) -> Bool`.

**Grounding:** `endSession(now:)` (:80) already writes `SharedData.setEndTime(...expectedSessionId: id)` (:82), mirrors `self.endTime` (:83), and flushes (:94) — `id` is the identity. The break reminder (`scheduleBreakReminder` :1102) uses a **random** notification id (`TimersUtil.scheduleNotification` defaults `identifier` to `UUID().uuidString`), so there is no targeted cancel; `cancelAllNotifications()` is the established tool (`stopBreak` uses it at :802). The M-side scheduler ingest is `syncScheduleSessions` (:830) → `upsertSessionFromSnapshot` (:833/:883). **Non-reentrancy verified (G10):** `endSession` is called only from strategy `stopBlocking` methods, `BlockedProfiles.swift:477`, and `SessionDebugCard.swift:89` — none inside a `SharedData.withLock` closure (`grep '\.endSession(' Foqos`), so `closeGrantsForSessionEnd`'s `withLockStatus` followed by the existing `setEndTime`/`flushActiveSession` is two clean sequential acquisitions, not a nested deadlock.

- [ ] **Step 1: Write the failing tests (T-C2-U16, U25)**

`FoqosTests/SessionEndGrantTests.swift`:
```swift
import XCTest
import SwiftData
@testable import FamilyFoqos
@preconcurrency import FoqosShared

final class SessionEndGrantTests: XCTestCase {
  private static let testSuiteName = "SessionEndGrantTests-\(UUID().uuidString)"
  override func setUp() { super.setUp(); SharedData.configure(suite: UserDefaults(suiteName: Self.testSuiteName)!) }
  override func tearDown() { UserDefaults().removePersistentDomain(forName: Self.testSuiteName); super.tearDown() }

  func testGivenOpenBreak_WhenCloseGrantsForSessionEnd_ThenBreakEndSetNoRestrictionChange() {
    let now = Date(); let pid = UUID()
    let s = SharedData.SessionSnapshot(id: "s1", tag: "t", blockedProfileId: pid, startTime: now,
      forceStarted: false, breakStartTime: now.addingTimeInterval(-60), breakEndDeadline: now.addingTimeInterval(240))
    SharedData.createActiveSharedSession(for: s)
    SharedData.closeGrantsForSessionEnd(expectedSessionId: "s1", now: now)
    let after = SharedData.getActiveSharedSession()
    XCTAssertEqual(after?.breakEndTime, now)  // bookkeeping only; no applier involved
  }

  func testGivenEndedSnapshotWithOpenBreak_WhenNormalizedForEnd_ThenGrantClosedAtMinEndDeadline() {  // U16 ingest
    let now = Date(); let pid = UUID()
    let ended = SharedData.SessionSnapshot(id: "s2", tag: "t", blockedProfileId: pid, startTime: now.addingTimeInterval(-600),
      endTime: now, breakStartTime: now.addingTimeInterval(-120), breakEndTime: nil,
      oneMoreMinuteStartTime: now.addingTimeInterval(-90),
      breakEndDeadline: now.addingTimeInterval(60), oneMoreMinuteDeadline: now.addingTimeInterval(-30))
    let norm = SharedData.normalizedForEnd(ended)
    XCTAssertEqual(norm.breakEndTime, now, "break closed at min(endTime, breakDeadline) = endTime (endTime < deadline)")
    XCTAssertNil(norm.oneMoreMinuteStartTime, "OMM fields cleared")
    XCTAssertTrue(SharedData.endedSessionHadOpenGrant(ended), "had an open grant ⇒ notifications should be cancelled")
  }

  func testGivenEndedSnapshotNoGrant_WhenEndedSessionHadOpenGrant_ThenFalse() {  // U25 negative
    let now = Date()
    let ended = SharedData.SessionSnapshot(id: "s3", tag: "t", blockedProfileId: UUID(),
      startTime: now.addingTimeInterval(-600), endTime: now)
    XCTAssertFalse(SharedData.endedSessionHadOpenGrant(ended))
  }

  @MainActor
  func testGivenEndedSnapshotIngested_WhenUpsert_ThenModelHasNoDanglingGrant() throws {
    let now = Date()
    let container = try TestModelContainer.create(); let context = ModelContext(container)
    let ended = SharedData.SessionSnapshot(id: "s4", tag: "t", blockedProfileId: UUID(),
      startTime: now.addingTimeInterval(-600), endTime: now,
      breakStartTime: now.addingTimeInterval(-120), oneMoreMinuteStartTime: now.addingTimeInterval(-90))
    BlockedProfileSession.upsertSessionFromSnapshot(in: context, withSnapshot: ended)
    let fetched = try context.fetch(FetchDescriptor<BlockedProfileSession>()).first
    XCTAssertNotNil(fetched?.breakEndTime)
    XCTAssertNil(fetched?.oneMoreMinuteStartTime)
  }
}
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement the primitive + pure helpers**

Append to `RestrictionGrants.swift`:
```swift
extension SharedData {
  /// §6.4 — normalize open grant fields at session end for bookkeeping ONLY (no restriction change).
  public static func closeGrantsForSessionEnd(expectedSessionId: String, now: Date) {
    withLockStatus(blocking: true) { _ in
      guard var session = rawActiveSession, session.id == expectedSessionId else { return }
      if session.breakStartTime != nil && session.breakEndTime == nil { session.breakEndTime = now }
      session.oneMoreMinuteStartTime = nil
      session.oneMoreMinuteDeadline = nil
      _ = rawCommitActiveSession(session)   // best-effort bookkeeping; not load-bearing
    }
  }

  /// §6.4 — pure normalization for an ENDED incoming snapshot: close any open grant at
  /// `min(endTime, deadline)`; clear OMM fields. Used on ingest of extension-ended sessions.
  public static func normalizedForEnd(_ s: SessionSnapshot) -> SessionSnapshot {
    guard let end = s.endTime else { return s }
    var out = s
    if out.breakStartTime != nil && out.breakEndTime == nil {
      out.breakEndTime = min(end, out.breakEndDeadline ?? end)
    }
    out.oneMoreMinuteStartTime = nil
    out.oneMoreMinuteDeadline = nil
    return out
  }

  /// True iff an ended snapshot still carried an open break or OMM grant (⇒ cancel stale notifications).
  public static func endedSessionHadOpenGrant(_ s: SessionSnapshot) -> Bool {
    guard s.endTime != nil else { return false }
    let breakOpen = s.breakStartTime != nil && s.breakEndTime == nil
    return breakOpen || s.oneMoreMinuteStartTime != nil
  }
}
```

- [ ] **Step 4: Wire `endSession` and the ingest**

In `BlockedProfileSessions.swift` `endSession(now:)` (:80), add as the FIRST line (before `SharedData.setEndTime` :82):
```swift
    SharedData.closeGrantsForSessionEnd(expectedSessionId: id, now: now)
    if breakStartTime != nil && breakEndTime == nil { breakEndTime = now }  // mirror to the model
```
In `upsertSessionFromSnapshot` (:144), normalize an ended incoming snapshot before copying fields — add at the top of the function:
```swift
    let snapshot = snapshot.endTime != nil ? SharedData.normalizedForEnd(snapshot) : snapshot
```
(Then the existing branches copy from the normalized `snapshot`, so the deadline-aware grant close from Task 1's field copies lands correctly.)

In `StrategyManager.syncScheduleSessions` (:830), track whether any ingested ended session carried an open grant and cancel **once after** the ingest loop (avoids nuking a freshly-scheduled reminder mid-loop; `cancelAllNotifications` is broad because no targeted break-reminder id exists — matches `stopBreak` :802). Declare `var hadDanglingGrant = false` before the loop; at each ingest site (:833 and :883) add `if SharedData.endedSessionHadOpenGrant(snapshot) { hadDanglingGrant = true }`; after the loop add:
```swift
    if hadDanglingGrant { timersUtil.cancelAllNotifications() }
```
(Given single-active-session semantics + no live users, the broad cancel is self-healing — the `FoqosApp` `.active` catch-up trio reschedules pre-activation reminders on the same foreground pass. A targeted per-session id would be preferable but none exists today.)

- [ ] **Step 5: Run — expect PASS** (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Packages/FoqosShared/Sources/FoqosShared/RestrictionGrants.swift Foqos/Models/BlockedProfileSessions.swift Foqos/Utils/StrategyManager.swift FoqosTests/SessionEndGrantTests.swift
git commit -m "feat(c2): session-end grant bookkeeping + ingest normalization (T-C2-U16, U25)"
```

---

### Task 9: Standalone `applyRestrictionsForCurrentState` (D-C2-4 convergence + M-arm flush)

**Files:**
- Modify: `Packages/FoqosShared/Sources/FoqosShared/RestrictionGrants.swift`
- Test: `FoqosTests/RestrictionApplyCurrentStateTests.swift` (new)

**Interfaces:**
- Produces: `@discardableResult applyRestrictionsForCurrentState(process:liveSnapshot:applier:) -> RestrictionDecision`. Consumed by the closers already call the deriver inline; this standalone form is the reconciler's final step (Task 10) and the M flush point (X32/U32).

- [ ] **Step 1: Write the failing tests (T-C2-U32 flush; per-process convergence)**

`FoqosTests/RestrictionApplyCurrentStateTests.swift`:
```swift
import XCTest
@testable import FamilyFoqos
@preconcurrency import FoqosShared

final class RestrictionApplyCurrentStateTests: XCTestCase {
  private static let testSuiteName = "RestrictionApplyCurrentStateTests-\(UUID().uuidString)"
  override func setUp() { super.setUp(); SharedData.configure(suite: UserDefaults(suiteName: Self.testSuiteName)!) }
  override func tearDown() { UserDefaults().removePersistentDomain(forName: Self.testSuiteName); super.tearDown() }

  private func snap(_ pid: UUID) -> SharedData.ProfileSnapshot {
    SharedData.ProfileSnapshot(id: pid, name: "P", selectedActivity: .init(), createdAt: Date(), updatedAt: Date(),
      order: 0, enableLiveActivity: false, enableBreaks: true, enableStrictMode: false,
      enableAllowMode: false, enableAllowModeDomains: false, enableSafariBlocking: false)
  }

  func testGivenNoSession_WhenMainAppApplies_ThenDeactivates() {
    let spy = RecordingRestrictionApplier()
    let d = SharedData.applyRestrictionsForCurrentState(process: .mainApp, liveSnapshot: nil, applier: spy)
    XCTAssertEqual(d, .deactivate); XCTAssertEqual(spy.calls, [.deactivate])
  }

  func testGivenNoSession_WhenExtensionApplies_ThenBailPreserve() {
    let spy = RecordingRestrictionApplier()
    let d = SharedData.applyRestrictionsForCurrentState(process: .monitorExtension, liveSnapshot: nil, applier: spy)
    XCTAssertEqual(d, .bailPreserve); XCTAssertTrue(spy.calls.isEmpty)
  }

  func testGivenEndedButPresent_WhenMainAppApplies_ThenFlushesAndDeactivates() {  // U32
    let now = Date(); let pid = UUID()
    SharedData.createActiveSharedSession(for: SharedData.SessionSnapshot(
      id: "s", tag: "t", blockedProfileId: pid, startTime: now.addingTimeInterval(-60), endTime: now))
    let spy = RecordingRestrictionApplier()
    let d = SharedData.applyRestrictionsForCurrentState(process: .mainApp, liveSnapshot: nil, applier: spy)
    XCTAssertEqual(d, .deactivate)
    XCTAssertNil(SharedData.getActiveSharedSession(), "ended-but-present flushed")
  }

  func testGivenEndedButPresent_WhenExtensionApplies_ThenBailAndDoesNotFlush() {
    let now = Date()
    SharedData.createActiveSharedSession(for: SharedData.SessionSnapshot(
      id: "s", tag: "t", blockedProfileId: UUID(), startTime: now.addingTimeInterval(-60), endTime: now))
    let d = SharedData.applyRestrictionsForCurrentState(process: .monitorExtension, liveSnapshot: nil, applier: RecordingRestrictionApplier())
    XCTAssertEqual(d, .bailPreserve)
    XCTAssertNotNil(SharedData.getActiveSharedSession(), "extension never flushes")
  }

  func testGivenSessionNoGrantWithSnapshot_WhenApplies_ThenActivate() {
    let pid = UUID()
    SharedData.createActiveSharedSession(for: SharedData.SessionSnapshot(
      id: "s", tag: "t", blockedProfileId: pid, startTime: Date(), forceStarted: false))
    let spy = RecordingRestrictionApplier()
    _ = SharedData.applyRestrictionsForCurrentState(process: .mainApp, liveSnapshot: snap(pid), applier: spy)
    XCTAssertEqual(spy.calls, [.activate(profileId: pid)])
  }
}
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement**

Append to `RestrictionGrants.swift`:
```swift
extension SharedData {
  /// D-C2-4 standalone derive-and-apply. Main app additionally FLUSHES an ended-but-present stale
  /// entry (rev-6, X32) so it cannot re-assert ON forever; the extension never flushes and never
  /// applies OFF on absence (per-process authority).
  @discardableResult
  public static func applyRestrictionsForCurrentState(
    process: RestrictionProcess, liveSnapshot: ProfileSnapshot?,
    applier: RestrictionApplying = AppBlockerUtil()
  ) -> RestrictionDecision {
    withLockStatus(blocking: process == .mainApp) { _ in
      let session = rawActiveSession
      if process == .mainApp, let s = session, s.endTime != nil {
        _ = rawCommitActiveSession(nil)   // flush stale ended entry
      }
      let decision = deriveRestriction(session: session, liveSnapshot: liveSnapshot, process: process)
      applyDecision(decision, applier: applier)
      return decision
    }
  }
}
```

- [ ] **Step 4: Run — expect PASS** (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/FoqosShared/Sources/FoqosShared/RestrictionGrants.swift FoqosTests/RestrictionApplyCurrentStateTests.swift
git commit -m "feat(c2): standalone applyRestrictionsForCurrentState with M-arm flush (T-C2-U32)"
```

---

### Task 10: Reconciler core `reconcileExpiredGrants` (§7.5, cross-process; I10)

**Files:**
- Modify: `Packages/FoqosShared/Sources/FoqosShared/RestrictionGrants.swift`
- Test: `FoqosTests/HealExpiredLiftsTests.swift` (new)

**Interfaces:**
- Produces: `reconcileExpiredGrants(process:now:liveSnapshot:breakDurationMinutes:applier:commit:)`. This is the **cross-process core** (I10 "one routine"): OMM closer → break closer → final convergence. The **main-app-only** duties (backstop re-arm, SwiftData snapshot repair, orphan sweep, legacy full-migration pin+backstop, notification cancel) are added by the M wrapper in Task 17, which calls this core. The extension calls this core directly (Task 11).

**Per-process authority (D-C2-4):** the core never mutates DeviceActivity registrations (I5 — that stays main-app-only, enforced by the CI grep in Task 18). Closers run OMM-first so the break-active branch handles the absorbed case; the final `applyRestrictionsForCurrentState` converges crash-window divergences in either direction (X22/X23).

- [ ] **Step 1: Write the failing decision-table tests (T-C2-U8; pinned re-block part of U24)**

`FoqosTests/HealExpiredLiftsTests.swift`:
```swift
import XCTest
@testable import FamilyFoqos
@preconcurrency import FoqosShared

final class HealExpiredLiftsTests: XCTestCase {
  private static let testSuiteName = "HealExpiredLiftsTests-\(UUID().uuidString)"
  override func setUp() { super.setUp(); SharedData.configure(suite: UserDefaults(suiteName: Self.testSuiteName)!) }
  override func tearDown() { UserDefaults().removePersistentDomain(forName: Self.testSuiteName); super.tearDown() }

  private func snap(_ pid: UUID, breakMinutes: Int = 5) -> SharedData.ProfileSnapshot {
    SharedData.ProfileSnapshot(id: pid, name: "P", selectedActivity: .init(), createdAt: Date(), updatedAt: Date(),
      order: 0, enableLiveActivity: false, enableBreaks: true, breakTimeInMinutes: breakMinutes,
      enableStrictMode: false, enableAllowMode: false, enableAllowModeDomains: false, enableSafariBlocking: false)
  }
  @discardableResult
  private func seed(_ b: (inout SharedData.SessionSnapshot) -> Void, pid: UUID = UUID()) -> (String, UUID) {
    var s = SharedData.SessionSnapshot(id: "s", tag: "t", blockedProfileId: pid, startTime: Date(), forceStarted: false)
    b(&s); SharedData.createActiveSharedSession(for: s); return (s.id, pid)
  }

  func testGivenExpiredBreak_WhenReconcile_ThenClosesAndReblocks() {
    let now = Date(); let (_, pid) = seed { $0.breakStartTime = now.addingTimeInterval(-600); $0.breakEndDeadline = now.addingTimeInterval(-1) }
    let spy = RecordingRestrictionApplier()
    SharedData.reconcileExpiredGrants(process: .mainApp, now: now, liveSnapshot: snap(pid), breakDurationMinutes: 5, applier: spy)
    XCTAssertNotNil(SharedData.getActiveSharedSession()?.breakEndTime)
    XCTAssertTrue(spy.calls.contains(.activate(profileId: pid)))
  }

  func testGivenExpiredOMM_WhenReconcile_ThenClosesAndReblocks() {
    let now = Date(); let (_, pid) = seed { $0.oneMoreMinuteStartTime = now.addingTimeInterval(-120); $0.oneMoreMinuteDeadline = now.addingTimeInterval(-60); $0.oneMoreMinuteUsed = true }
    let spy = RecordingRestrictionApplier()
    SharedData.reconcileExpiredGrants(process: .mainApp, now: now, liveSnapshot: snap(pid), breakDurationMinutes: 5, applier: spy)
    XCTAssertNil(SharedData.getActiveSharedSession()?.oneMoreMinuteStartTime)
    XCTAssertTrue(spy.calls.contains(.activate(profileId: pid)))
  }

  func testGivenExpiredOMMDuringBreak_WhenReconcile_ThenClosesOMMFieldsOnlyNoReblock() {
    let now = Date(); let (_, pid) = seed {
      $0.breakStartTime = now.addingTimeInterval(-30); $0.breakEndDeadline = now.addingTimeInterval(270)
      $0.oneMoreMinuteStartTime = now.addingTimeInterval(-120); $0.oneMoreMinuteDeadline = now.addingTimeInterval(-60); $0.oneMoreMinuteUsed = true
    }
    let spy = RecordingRestrictionApplier()
    SharedData.reconcileExpiredGrants(process: .mainApp, now: now, liveSnapshot: snap(pid), breakDurationMinutes: 5, applier: spy)
    XCTAssertNil(SharedData.getActiveSharedSession()?.oneMoreMinuteStartTime)
    XCTAssertFalse(spy.calls.contains(.activate(profileId: pid)), "break still open ⇒ no re-block (#205)")
  }

  func testGivenOpenUnexpiredGrant_WhenReconcile_ThenConvergesOff() {  // X22 over-block convergence
    let now = Date(); let (_, pid) = seed { $0.breakStartTime = now.addingTimeInterval(-30); $0.breakEndDeadline = now.addingTimeInterval(270) }
    let spy = RecordingRestrictionApplier()
    SharedData.reconcileExpiredGrants(process: .mainApp, now: now, liveSnapshot: snap(pid), breakDurationMinutes: 5, applier: spy)
    XCTAssertNil(SharedData.getActiveSharedSession()?.breakEndTime, "grant stays open")
    XCTAssertEqual(spy.calls.last, .deactivate, "converges OFF for the open grant")
  }

  func testGivenClosedGrantRestrictionsOff_WhenReconcile_ThenConvergesOn() {  // X23 under-block convergence
    let now = Date(); let (_, pid) = seed { $0.breakStartTime = now.addingTimeInterval(-600); $0.breakEndTime = now.addingTimeInterval(-5) }
    let spy = RecordingRestrictionApplier()
    SharedData.reconcileExpiredGrants(process: .mainApp, now: now, liveSnapshot: snap(pid), breakDurationMinutes: 5, applier: spy)
    XCTAssertEqual(spy.calls.last, .activate(profileId: pid), "converges ON for the closed grant")
  }

  func testGivenNoSession_WhenExtensionReconcile_ThenBailPreserve() {
    let spy = RecordingRestrictionApplier()
    SharedData.reconcileExpiredGrants(process: .monitorExtension, now: Date(), liveSnapshot: nil, breakDurationMinutes: nil, applier: spy)
    XCTAssertTrue(spy.calls.isEmpty)
  }

  func testGivenExpiredBreakMissingLiveButPinned_WhenExtensionReconcile_ThenReblocksFromPin() {  // U24 pinned re-block / X30
    let now = Date(); let pid = UUID(); let pinned = snap(pid)
    let (_, _) = seed({ $0.breakStartTime = now.addingTimeInterval(-600); $0.breakEndDeadline = now.addingTimeInterval(-1); $0.pinnedProfileConfig = pinned }, pid: pid)
    let spy = RecordingRestrictionApplier()
    SharedData.reconcileExpiredGrants(process: .monitorExtension, now: now, liveSnapshot: nil, breakDurationMinutes: nil, applier: spy)
    XCTAssertTrue(spy.calls.contains(.activate(profileId: pid)), "re-block from pinned config when live snapshot absent")
  }
}
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement the core**

Append to `RestrictionGrants.swift`:
```swift
extension SharedData {
  /// §7.5 reconciler CORE (cross-process, I10). OMM-first close (break-active branch handles the
  /// absorbed case), then break close, then converge. NEVER mutates DeviceActivity registrations
  /// (main-app-only duty, I5 — enforced by CI grep). The main-app wrapper (StrategyManager) adds
  /// re-arm / SwiftData repair / orphan sweep / full legacy migration / notification cancel.
  public static func reconcileExpiredGrants(
    process: RestrictionProcess, now: Date,
    liveSnapshot: ProfileSnapshot?, breakDurationMinutes: Int?,
    applier: RestrictionApplying = AppBlockerUtil(),
    commit: (SessionSnapshot?) -> Bool = { rawCommitActiveSession($0) }
  ) {
    if let session = rawActiveSession, session.endTime == nil {
      let sid = session.id
      _ = closeOneMoreMinuteGrantIfExpired(
        expectedSessionId: sid, now: now, process: process, liveSnapshot: liveSnapshot, applier: applier, commit: commit)
      _ = closeBreakGrantIfExpiredOrExplicit(
        expectedSessionId: sid, explicit: false, now: now, process: process,
        durationMinutes: breakDurationMinutes, liveSnapshot: liveSnapshot, applier: applier, commit: commit)
    }
    applyRestrictionsForCurrentState(process: process, liveSnapshot: liveSnapshot, applier: applier)
  }
}
```

- [ ] **Step 4: Run — expect PASS** (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/FoqosShared/Sources/FoqosShared/RestrictionGrants.swift FoqosTests/HealExpiredLiftsTests.swift
git commit -m "feat(c2): reconciler core reconcileExpiredGrants (T-C2-U8, U24-pinned)"
```

---
### Task 11: C2 backstop handlers + routing + legacy handler rewrite + monitor reconcile (§7.3, I5)

**Files:**
- Create: `Packages/FoqosShared/Sources/FoqosShared/Timers/BreakDeadlineBackstopActivity.swift`
- Create: `Packages/FoqosShared/Sources/FoqosShared/Timers/OneMoreMinuteDeadlineBackstopActivity.swift`
- Modify: `Packages/FoqosShared/Sources/FoqosShared/Timers/TimerActivityUtil.swift` (`getTimerActivity` switch :44–57)
- Modify: `Packages/FoqosShared/Sources/FoqosShared/Timers/BreakTimerActivity.swift` (`start`/`stop` :19–75)
- Modify: `Packages/FoqosShared/Sources/FoqosShared/Timers/OneMoreMinuteTimerActivity.swift` (`stop` :29–57)
- Modify: `FoqosDeviceMonitor/DeviceActivityMonitorExtension.swift` (:30–42)
- Test: `FoqosTests/C2BackstopRoutingTests.swift` (new)

**Interfaces:**
- Produces: `BreakDeadlineBackstopActivity.id == "BreakDeadlineBackstop"`, `OneMoreMinuteDeadlineBackstopActivity.id == "OneMoreMinuteDeadlineBackstop"` (C2-owned names, I5). Consumed by Task 12's registrar.

**Design:** the C2 backstop `stop` routes to the shared closer with `process: .monitorExtension`, resolving the **active session's own** profile snapshot for re-block config (so a stale cross-profile callback re-blocks with the session's config, not the routed activity's — X20). Legacy `BreakTimerActivity`/`OneMoreMinuteTimerActivity` handlers are rewritten to the same gated closers (bonus healing wakes). The monitor invokes `reconcileExpiredGrants` after routing every callback (§7.3 bullet 5 — every wake heals any expired grant, bounding R1 by "next wake of any kind"). **The extension never registers/deregisters** (I5); these handlers only mutate state + apply restrictions.

- [ ] **Step 1: Write the failing routing tests (T-C2-U29)**

`FoqosTests/C2BackstopRoutingTests.swift`:
```swift
import XCTest
import DeviceActivity
@testable import FamilyFoqos
@preconcurrency import FoqosShared

final class C2BackstopRoutingTests: XCTestCase {
  private static let testSuiteName = "C2BackstopRoutingTests-\(UUID().uuidString)"
  override func setUp() { super.setUp(); SharedData.configure(suite: UserDefaults(suiteName: Self.testSuiteName)!) }
  override func tearDown() { UserDefaults().removePersistentDomain(forName: Self.testSuiteName); super.tearDown() }

  private func snap(_ pid: UUID) -> SharedData.ProfileSnapshot {
    SharedData.ProfileSnapshot(id: pid, name: "P", selectedActivity: .init(), createdAt: Date(), updatedAt: Date(),
      order: 0, enableLiveActivity: false, enableBreaks: true, breakTimeInMinutes: 5, enableStrictMode: false,
      enableAllowMode: false, enableAllowModeDomains: false, enableSafariBlocking: false)
  }
  private func seedExpiredBreak(pid: UUID) {
    let now = Date()
    SharedData.setSnapshot(snap(pid), for: pid.uuidString)
    SharedData.createActiveSharedSession(for: SharedData.SessionSnapshot(
      id: "sess", tag: "t", blockedProfileId: pid, startTime: now.addingTimeInterval(-600), forceStarted: false,
      breakStartTime: now.addingTimeInterval(-600), breakEndDeadline: now.addingTimeInterval(-1),
      pinnedProfileConfig: snap(pid)))
  }

  func testGivenExpiredBreak_WhenC2BackstopNameRouted_ThenGrantClosed() {  // U29 new prefix routes
    let pid = UUID(); seedExpiredBreak(pid: pid)
    TimerActivityUtil.stopTimerActivity(
      for: DeviceActivityName(rawValue: "\(BreakDeadlineBackstopActivity.id):\(pid.uuidString)"))
    XCTAssertNotNil(SharedData.getActiveSharedSession()?.breakEndTime, "C2 backstop name closes the grant")
  }

  func testGivenExpiredBreak_WhenLegacyNameRouted_ThenAlsoClosesGrant() {  // U29 legacy still routes
    let pid = UUID(); seedExpiredBreak(pid: pid)
    TimerActivityUtil.stopTimerActivity(
      for: DeviceActivityName(rawValue: "\(BreakTimerActivity.id):\(pid.uuidString)"))
    XCTAssertNotNil(SharedData.getActiveSharedSession()?.breakEndTime, "legacy name is a bonus healing wake")
  }

  func testGivenC2Ids_WhenResolved_ThenAreDistinctFromLegacy() {
    XCTAssertEqual(BreakDeadlineBackstopActivity.id, "BreakDeadlineBackstop")
    XCTAssertEqual(OneMoreMinuteDeadlineBackstopActivity.id, "OneMoreMinuteDeadlineBackstop")
    XCTAssertNotEqual(BreakDeadlineBackstopActivity.id, BreakTimerActivity.id)  // never conflated (X37)
  }
}
```

- [ ] **Step 2: Run — expect FAIL** (new types/ids missing).

- [ ] **Step 3: Create the two C2 backstop handlers**

`BreakDeadlineBackstopActivity.swift`:
```swift
import DeviceActivity
import Foundation

/// C2-owned break backstop (I5). Distinct from the legacy `BreakScheduleActivity` name so re-arm's
/// register-if-absent never adopts a legacy `repeats:false` one-shot (X37). `start` is a no-op (the
/// in-process lift owns the grant); `stop` routes to the gated shared closer.
public class BreakDeadlineBackstopActivity: TimerActivity {
  public static let id: String = "BreakDeadlineBackstop"
  private let appBlocker: AppBlockerUtil
  public init() { self.appBlocker = AppBlockerUtil() }

  public func getDeviceActivityName(from profileId: String) -> DeviceActivityName {
    DeviceActivityName(rawValue: "\(BreakDeadlineBackstopActivity.id):\(profileId)")
  }
  public func getAllBreakDeadlineBackstopActivities(from activities: [DeviceActivityName]) -> [DeviceActivityName] {
    activities.filter { $0.rawValue.starts(with: BreakDeadlineBackstopActivity.id) }
  }
  public func start(for profile: SharedData.ProfileSnapshot) {
    Log.info("Break deadline backstop intervalDidStart - no-op", category: .timer)
  }
  public func stop(for profile: SharedData.ProfileSnapshot) {
    guard let session = SharedData.getActiveSharedSession() else { return }
    let live = SharedData.snapshot(for: session.blockedProfileId.uuidString)  // session's own config, not the routed activity's
    SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: session.id, explicit: false, now: Date(), process: .monitorExtension,
      durationMinutes: live?.breakTimeInMinutes, liveSnapshot: live, applier: appBlocker)
  }
}
```
`OneMoreMinuteDeadlineBackstopActivity.swift`:
```swift
import DeviceActivity
import Foundation

/// C2-owned OMM backstop (I5). `start` no-op; `stop` routes to the gated OMM closer.
public class OneMoreMinuteDeadlineBackstopActivity: TimerActivity {
  public static let id: String = "OneMoreMinuteDeadlineBackstop"
  private let appBlocker: AppBlockerUtil
  public init() { self.appBlocker = AppBlockerUtil() }

  public func getDeviceActivityName(from profileId: String) -> DeviceActivityName {
    DeviceActivityName(rawValue: "\(OneMoreMinuteDeadlineBackstopActivity.id):\(profileId)")
  }
  public func getAllOneMoreMinuteDeadlineBackstopActivities(from activities: [DeviceActivityName]) -> [DeviceActivityName] {
    activities.filter { $0.rawValue.starts(with: OneMoreMinuteDeadlineBackstopActivity.id) }
  }
  public func start(for profile: SharedData.ProfileSnapshot) {
    Log.info("OMM deadline backstop intervalDidStart - no-op", category: .timer)
  }
  public func stop(for profile: SharedData.ProfileSnapshot) {
    guard let session = SharedData.getActiveSharedSession() else { return }
    let live = SharedData.snapshot(for: session.blockedProfileId.uuidString)
    SharedData.closeOneMoreMinuteGrantIfExpired(
      expectedSessionId: session.id, now: Date(), process: .monitorExtension, liveSnapshot: live, applier: appBlocker)
  }
}
```

- [ ] **Step 4: Route the new ids in `TimerActivityUtil.getTimerActivity`** (:44–57), add before `default`:
```swift
    case BreakDeadlineBackstopActivity.id: return BreakDeadlineBackstopActivity()
    case OneMoreMinuteDeadlineBackstopActivity.id: return OneMoreMinuteDeadlineBackstopActivity()
```

- [ ] **Step 5: Rewrite the legacy handlers**

`BreakTimerActivity.swift` — replace `start` (:19–44) and `stop` (:46–75) bodies:
```swift
  public func start(for profile: SharedData.ProfileSnapshot) {
    // §7.3: no-op. The in-process lift (StrategyManager.startBreak) owns the grant; a lifting
    // start under the wrap shape would be a daily-unblock bug and re-exposes upstream #358.
    Log.info("Break intervalDidStart - no-op (in-process lift owns the grant)", category: .timer)
  }

  public func stop(for profile: SharedData.ProfileSnapshot) {
    // Legacy break registration ⇒ bonus healing wake. Route to the gated shared closer.
    guard let session = SharedData.getActiveSharedSession() else { return }
    let live = SharedData.snapshot(for: session.blockedProfileId.uuidString)
    SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: session.id, explicit: false, now: Date(), process: .monitorExtension,
      durationMinutes: live?.breakTimeInMinutes, liveSnapshot: live, applier: appBlocker)
  }
```
`OneMoreMinuteTimerActivity.swift` — replace `stop` (:29–57) body (keep `start` no-op):
```swift
  public func stop(for profile: SharedData.ProfileSnapshot) {
    guard let session = SharedData.getActiveSharedSession() else { return }
    let live = SharedData.snapshot(for: session.blockedProfileId.uuidString)
    SharedData.closeOneMoreMinuteGrantIfExpired(
      expectedSessionId: session.id, now: Date(), process: .monitorExtension, liveSnapshot: live, applier: appBlocker)
  }
```

- [ ] **Step 6: Monitor reconcile after routing**

In `DeviceActivityMonitorExtension.swift`, after `TimerActivityUtil.startTimerActivity(for: activity)` (:34) and `TimerActivityUtil.stopTimerActivity(for: activity)` (:41), add `reconcileAfterWake()`; add the method:
```swift
  private func reconcileAfterWake() {
    guard let session = SharedData.getActiveSharedSession(), session.endTime == nil else { return }
    // live MAY be nil (snapshot wiped) — do NOT gate the reconcile on it, or the pinned-config
    // convergence (§6.1a/X30) and X23 under-block healing are skipped exactly when they matter.
    let live = SharedData.snapshot(for: session.blockedProfileId.uuidString)
    SharedData.reconcileExpiredGrants(
      process: .monitorExtension, now: Date(), liveSnapshot: live,
      breakDurationMinutes: live?.breakTimeInMinutes, applier: appBlocker)
  }
```

**Coverage note (X23/X30 wiring):** `reconcileAfterWake` lives in the `FoqosDeviceMonitor` target, which `FoqosTests` cannot import, so it is not directly unit-testable. Its behavior with a wiped snapshot (nil `live` ⇒ re-block from the pinned config) is proven by `HealExpiredLiftsTests.testGivenExpiredBreakMissingLiveButPinned_...` (Task 10, which drives the same core with `liveSnapshot: nil`) plus device tests T-C2-D2/D4. The finding-1 fix (nil `live` no longer gates the reconcile) is what makes the shipped path reach that core.

- [ ] **Step 7: Run — expect PASS** (3 tests). **Also run the full suite once here** — this task changes shared extension code:
`xcodebuild test ... -only-testing:FoqosTests | xcpretty` — expect no regressions in `OneMoreMinuteTests`/`BreakDurationCalculableTests`.

- [ ] **Step 8: Commit**

```bash
git add Packages/FoqosShared/Sources/FoqosShared/Timers/ FoqosDeviceMonitor/DeviceActivityMonitorExtension.swift FoqosTests/C2BackstopRoutingTests.swift
git commit -m "feat(c2): C2 backstop handlers + routing + legacy rewrite + monitor reconcile (T-C2-U29)"
```

---

### Task 12: Backstop registration helpers + `BackstopRegistering` seam (main-app-only, I5)

**Files:**
- Modify: `Foqos/Utils/DeviceActivityCenterUtil.swift` (C2 backstop register/replace/re-arm/remove/presence, using `wrapAnchorInterval`)
- Create: `Foqos/Utils/BackstopRegistering.swift` (protocol + real `DeviceActivityBackstopRegistrar`)
- Create: `FoqosTests/Helpers/RecordingBackstopRegistrar.swift`
- Test: `FoqosTests/BackstopRegistrarSpyTests.swift` (new)

**Interfaces:**
- Produces: `protocol BackstopRegistering` (replace/registerIfAbsent/remove/has for break + OMM); `DeviceActivityBackstopRegistrar` (real); `RecordingBackstopRegistrar` (spy). Consumed by `StrategyManager` (Tasks 13–17).

The real registrar delegates to new `DeviceActivityCenterUtil` helpers that build a `repeats:true` schedule from `wrapAnchorInterval` under the **C2-owned names**. *Replace* (`stopMonitoring` then `startMonitoring`) is used only for fresh grants, before the lift (I5/D-C2-3). *Register-if-absent* checks `center.activities` and never stops a live registration (I5/X34). Device behavior is covered by the device checklist; the seam makes `StrategyManager` unit-testable.

- [ ] **Step 1: Write the failing spy test (T-C2-U18 register-if-absent semantics)**

`FoqosTests/BackstopRegistrarSpyTests.swift`:
```swift
import XCTest
@testable import FamilyFoqos

final class BackstopRegistrarSpyTests: XCTestCase {
  func testGivenSpy_WhenReplaceThrowsConfigured_ThenReplaceThrows() {
    let spy = RecordingBackstopRegistrar(); spy.throwOnReplaceBreak = true
    XCTAssertThrowsError(try spy.replaceBreakBackstop(profileId: UUID(), deadline: Date(), now: Date()))
  }
  func testGivenSpyReportsPresent_WhenRegisterIfAbsent_ThenReturnsFalseAndDoesNotRegister() {
    let spy = RecordingBackstopRegistrar(); spy.hasBreakBackstopReturns = true
    let registered = try! spy.registerBreakBackstopIfAbsent(profileId: UUID(), deadline: Date(), now: Date())
    XCTAssertFalse(registered)
    XCTAssertFalse(spy.calls.contains(where: { if case .registerBreakIfAbsent = $0 { return true }; return false }) == false)
    XCTAssertFalse(spy.didStartMonitoringBreak, "must not register when already present (I5 never-stop)")
  }
  func testGivenRealRegistrar_WhenConstructed_ThenConformsToProtocol() {
    let r: BackstopRegistering = DeviceActivityBackstopRegistrar()  // compile-time conformance
    XCTAssertNotNil(r)
  }
}
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Add the `DeviceActivityCenterUtil` C2 backstop helpers**

In `DeviceActivityCenterUtil.swift` (near the other activity helpers):
```swift
  // MARK: - C2 deadline backstops (main-app-only registration, I5)

  private static func breakBackstopName(_ profileId: UUID) -> DeviceActivityName {
    DeviceActivityName(rawValue: "\(BreakDeadlineBackstopActivity.id):\(profileId.uuidString)")
  }
  private static func ommBackstopName(_ profileId: UUID) -> DeviceActivityName {
    DeviceActivityName(rawValue: "\(OneMoreMinuteDeadlineBackstopActivity.id):\(profileId.uuidString)")
  }
  private static func backstopSchedule(deadline: Date, now: Date) -> DeviceActivitySchedule {
    let (start, end) = wrapAnchorInterval(endingAt: deadline, now: now)
    return DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: true)
  }

  /// Fresh-grant REPLACE (pre-lift). stop-then-start on the C2 name; a throw aborts the grant.
  static func replaceBreakBackstop(profileId: UUID, deadline: Date, now: Date) throws {
    let name = breakBackstopName(profileId); let center = DeviceActivityCenter()
    center.stopMonitoring([name])
    try center.startMonitoring(name, during: backstopSchedule(deadline: deadline, now: now))
  }
  static func replaceOneMoreMinuteBackstop(profileId: UUID, deadline: Date, now: Date) throws {
    let name = ommBackstopName(profileId); let center = DeviceActivityCenter()
    center.stopMonitoring([name])
    try center.startMonitoring(name, during: backstopSchedule(deadline: deadline, now: now))
  }
  /// Re-arm REGISTER-IF-ABSENT (never stops a live registration, I5). Returns whether it registered.
  static func registerBreakBackstopIfAbsent(profileId: UUID, deadline: Date, now: Date) throws -> Bool {
    let name = breakBackstopName(profileId)
    if DeviceActivityCenter().activities.contains(name) { return false }
    try DeviceActivityCenter().startMonitoring(name, during: backstopSchedule(deadline: deadline, now: now))
    return true
  }
  static func registerOneMoreMinuteBackstopIfAbsent(profileId: UUID, deadline: Date, now: Date) throws -> Bool {
    let name = ommBackstopName(profileId)
    if DeviceActivityCenter().activities.contains(name) { return false }
    try DeviceActivityCenter().startMonitoring(name, during: backstopSchedule(deadline: deadline, now: now))
    return true
  }
  static func removeBreakBackstop(profileId: UUID) { DeviceActivityCenter().stopMonitoring([breakBackstopName(profileId)]) }
  static func removeOneMoreMinuteBackstop(profileId: UUID) { DeviceActivityCenter().stopMonitoring([ommBackstopName(profileId)]) }
  static func hasBreakBackstop(profileId: UUID) -> Bool { DeviceActivityCenter().activities.contains(breakBackstopName(profileId)) }
  static func hasOneMoreMinuteBackstop(profileId: UUID) -> Bool { DeviceActivityCenter().activities.contains(ommBackstopName(profileId)) }
```

- [ ] **Step 4: Create the seam + real registrar**

`Foqos/Utils/BackstopRegistering.swift`:
```swift
import Foundation

/// Main-app-only DeviceActivity backstop registration seam (I5). Injected into StrategyManager /
/// the reconciler so registration ordering (replace-before-lift) and failure (fail-closed) are testable.
protocol BackstopRegistering {
  func replaceBreakBackstop(profileId: UUID, deadline: Date, now: Date) throws
  func replaceOneMoreMinuteBackstop(profileId: UUID, deadline: Date, now: Date) throws
  func registerBreakBackstopIfAbsent(profileId: UUID, deadline: Date, now: Date) throws -> Bool
  func registerOneMoreMinuteBackstopIfAbsent(profileId: UUID, deadline: Date, now: Date) throws -> Bool
  func removeBreakBackstop(profileId: UUID)
  func removeOneMoreMinuteBackstop(profileId: UUID)
  func hasBreakBackstop(profileId: UUID) -> Bool
  func hasOneMoreMinuteBackstop(profileId: UUID) -> Bool
}

struct DeviceActivityBackstopRegistrar: BackstopRegistering {
  func replaceBreakBackstop(profileId: UUID, deadline: Date, now: Date) throws {
    try DeviceActivityCenterUtil.replaceBreakBackstop(profileId: profileId, deadline: deadline, now: now)
  }
  func replaceOneMoreMinuteBackstop(profileId: UUID, deadline: Date, now: Date) throws {
    try DeviceActivityCenterUtil.replaceOneMoreMinuteBackstop(profileId: profileId, deadline: deadline, now: now)
  }
  func registerBreakBackstopIfAbsent(profileId: UUID, deadline: Date, now: Date) throws -> Bool {
    try DeviceActivityCenterUtil.registerBreakBackstopIfAbsent(profileId: profileId, deadline: deadline, now: now)
  }
  func registerOneMoreMinuteBackstopIfAbsent(profileId: UUID, deadline: Date, now: Date) throws -> Bool {
    try DeviceActivityCenterUtil.registerOneMoreMinuteBackstopIfAbsent(profileId: profileId, deadline: deadline, now: now)
  }
  func removeBreakBackstop(profileId: UUID) { DeviceActivityCenterUtil.removeBreakBackstop(profileId: profileId) }
  func removeOneMoreMinuteBackstop(profileId: UUID) { DeviceActivityCenterUtil.removeOneMoreMinuteBackstop(profileId: profileId) }
  func hasBreakBackstop(profileId: UUID) -> Bool { DeviceActivityCenterUtil.hasBreakBackstop(profileId: profileId) }
  func hasOneMoreMinuteBackstop(profileId: UUID) -> Bool { DeviceActivityCenterUtil.hasOneMoreMinuteBackstop(profileId: profileId) }
}
```

- [ ] **Step 5: Create the spy**

`FoqosTests/Helpers/RecordingBackstopRegistrar.swift`:
```swift
import Foundation
@testable import FamilyFoqos

final class RecordingBackstopRegistrar: BackstopRegistering {
  enum Call: Equatable {
    case replaceBreak(UUID), replaceOMM(UUID)
    case registerBreakIfAbsent(UUID), registerOMMIfAbsent(UUID)
    case removeBreak(UUID), removeOMM(UUID)
  }
  private(set) var calls: [Call] = []
  var throwOnReplaceBreak = false
  var throwOnReplaceOMM = false
  var throwOnRegisterIfAbsent = false
  var hasBreakBackstopReturns = false
  var hasOMMBackstopReturns = false
  private(set) var didStartMonitoringBreak = false
  private(set) var didStartMonitoringOMM = false
  enum Err: Error { case configured }

  func replaceBreakBackstop(profileId: UUID, deadline: Date, now: Date) throws {
    calls.append(.replaceBreak(profileId)); if throwOnReplaceBreak { throw Err.configured }; didStartMonitoringBreak = true
  }
  func replaceOneMoreMinuteBackstop(profileId: UUID, deadline: Date, now: Date) throws {
    calls.append(.replaceOMM(profileId)); if throwOnReplaceOMM { throw Err.configured }; didStartMonitoringOMM = true
  }
  func registerBreakBackstopIfAbsent(profileId: UUID, deadline: Date, now: Date) throws -> Bool {
    calls.append(.registerBreakIfAbsent(profileId)); if throwOnRegisterIfAbsent { throw Err.configured }
    if hasBreakBackstopReturns { return false }; didStartMonitoringBreak = true; return true
  }
  func registerOneMoreMinuteBackstopIfAbsent(profileId: UUID, deadline: Date, now: Date) throws -> Bool {
    calls.append(.registerOMMIfAbsent(profileId)); if throwOnRegisterIfAbsent { throw Err.configured }
    if hasOMMBackstopReturns { return false }; didStartMonitoringOMM = true; return true
  }
  func removeBreakBackstop(profileId: UUID) { calls.append(.removeBreak(profileId)) }
  func removeOneMoreMinuteBackstop(profileId: UUID) { calls.append(.removeOMM(profileId)) }
  func hasBreakBackstop(profileId: UUID) -> Bool { hasBreakBackstopReturns }
  func hasOneMoreMinuteBackstop(profileId: UUID) -> Bool { hasOMMBackstopReturns }
}
```

- [ ] **Step 6: Run — expect PASS** (3 tests).

- [ ] **Step 7: Commit**

```bash
git add Foqos/Utils/DeviceActivityCenterUtil.swift Foqos/Utils/BackstopRegistering.swift FoqosTests/Helpers/RecordingBackstopRegistrar.swift FoqosTests/BackstopRegistrarSpyTests.swift
git commit -m "feat(c2): backstop registration helpers + BackstopRegistering seam (T-C2-U18 registrar)"
```

---
### Task 13: `StrategyManager.startBreak` fail-closed rewrite + seam injection (§7.1, fixes #214)

**Files:**
- Modify: `Foqos/Utils/StrategyManager.swift` (init :33–47; `appBlocker` decl :31; `startBreak` :760–785; add `mirrorGrantFieldsFromShared`)
- Test: `FoqosTests/StrategyManagerBreakOMMTests.swift` (new)

**Interfaces:**
- Consumes: `RestrictionApplying`, `BackstopRegistering`, `openBreakGrant`, backstop registrar.
- Produces: injected `appBlocker: RestrictionApplying` and `backstopRegistrar: BackstopRegistering` on `StrategyManager`; `private func mirrorGrantFieldsFromShared(_:)`. Consumed by Tasks 14–17.

**Grounding:** `session.id: String` is the shared-session identity (`toSnapshot` uses it; `endSession` passes it as `expectedSessionId` :82). `startBreak` today calls the non-throwing `DeviceActivityCenterUtil.startBreakTimerActivity(for:)` (:772) which swallows the sub-15 throw internally — so the break silently never starts (#214). The rewrite registers the **C2 backstop through the throwing seam before lifting**, so failure is observable and surfaced.

- [ ] **Step 1: Inject the seams (prerequisite for Tasks 13–17)**

In `StrategyManager.swift`, change `private let appBlocker = AppBlockerUtil()` (:31) to:
```swift
  private let appBlocker: RestrictionApplying
  private let backstopRegistrar: BackstopRegistering
```
In `init` (:33–47), add two params (LAST, defaulted) and assign:
```swift
    appBlocker: RestrictionApplying = AppBlockerUtil(),
    backstopRegistrar: BackstopRegistering = DeviceActivityBackstopRegistrar()
  ) {
    // ...existing assignments...
    self.appBlocker = appBlocker
    self.backstopRegistrar = backstopRegistrar
  }
```
(`AppBlockerUtil` conforms to `RestrictionApplying` from Task 3; existing `appBlocker.activateRestrictions(for:)`/`deactivateRestrictions()` call sites at :189/:1222 keep compiling — those methods are in the protocol. The inline `AppBlockerUtil()` at `startWithTag` :1040 is out of C2's scope; leave it.)

Add the mirror helper (anywhere in the class):
```swift
  /// Copy the settled shared-session grant fields onto the SwiftData model (single source of truth =
  /// the shared snapshot, G13/X21). Call after a grant open/close.
  private func mirrorGrantFieldsFromShared(_ session: BlockedProfileSession) {
    guard let shared = SharedData.getActiveSharedSession(), shared.id == session.id else { return }
    session.breakStartTime = shared.breakStartTime
    session.breakEndTime = shared.breakEndTime
    session.breakEndDeadline = shared.breakEndDeadline
    session.oneMoreMinuteStartTime = shared.oneMoreMinuteStartTime
    session.oneMoreMinuteDeadline = shared.oneMoreMinuteDeadline
    session.oneMoreMinuteUsed = shared.oneMoreMinuteUsed
    session.pinnedProfileConfigData = shared.pinnedProfileConfig.flatMap { try? JSONEncoder().encode($0) }
    try? session.modelContext?.save()
  }
```

- [ ] **Step 2: Write the failing tests (T-C2-U10 + happy path)**

`FoqosTests/StrategyManagerBreakOMMTests.swift` (this file grows across Tasks 13–16):
```swift
import XCTest
import SwiftData
@testable import FamilyFoqos
@preconcurrency import FoqosShared

@MainActor
final class StrategyManagerBreakOMMTests: XCTestCase {
  var suiteName = ""
  var container: ModelContainer!
  var context: ModelContext!
  var applier: RecordingRestrictionApplier!
  var registrar: RecordingBackstopRegistrar!
  var manager: StrategyManager!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "StrategyManagerBreakOMMTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    container = try TestModelContainer.create()
    context = ModelContext(container)
    applier = RecordingRestrictionApplier()
    registrar = RecordingBackstopRegistrar()
    manager = StrategyManager(appBlocker: applier, backstopRegistrar: registrar)
  }
  override func tearDown() async throws {
    manager.stopTimer()
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  /// Seed a blocking session for a break-enabled profile and load it into the manager.
  @discardableResult
  private func seedActiveSession(breakMinutes: Int = 5) throws -> BlockedProfileSession {
    let profile = BlockedProfiles(name: "P")
    profile.enableBreaks = true
    profile.breakTimeInMinutes = breakMinutes
    context.insert(profile)
    let session = BlockedProfileSession.createSession(in: context, withTag: "t", withProfile: profile)
    try context.save()
    try manager.loadActiveSession(context: context)   // sets activeSession + starts ticker
    return session
  }

  func testGivenBlockingSession_WhenToggleBreakStart_ThenRegistersBeforeLiftAndOpensGrant() {
    let session = try! seedActiveSession()
    let pid = session.blockedProfile.id
    applier.onDeactivate = {
      XCTAssertTrue(self.registrar.calls.contains(.replaceBreak(pid)), "backstop registered BEFORE the lift (I5)")
    }
    manager.toggleBreak(context: context)
    XCTAssertEqual(registrar.calls.first, .replaceBreak(pid))
    XCTAssertEqual(applier.calls, [.deactivate])
    let shared = SharedData.getActiveSharedSession()
    XCTAssertNotNil(shared?.breakStartTime)
    XCTAssertNotNil(shared?.breakEndDeadline)
    XCTAssertNotNil(shared?.pinnedProfileConfig)
    XCTAssertNil(manager.errorMessage)
  }

  func testGivenBackstopRegistrationThrows_WhenToggleBreakStart_ThenFailClosedNoLiftNoState() {  // U10 / #214
    let session = try! seedActiveSession()
    registrar.throwOnReplaceBreak = true
    manager.toggleBreak(context: context)
    XCTAssertNil(SharedData.getActiveSharedSession()?.breakStartTime, "no grant opened")
    XCTAssertTrue(applier.calls.isEmpty, "restrictions never lifted")
    XCTAssertNotNil(manager.errorMessage, "failure surfaced (fixes #214 silent no-op)")
    _ = session
  }
}
```

- [ ] **Step 3: Run — expect FAIL** (init signature / behavior).

- [ ] **Step 4: Rewrite `startBreak` (:760–785)**

```swift
  private func startBreak(context: ModelContext) {
    guard let session = activeSession else {
      Log.info("No active session to start break", category: .strategy); return
    }
    guard session.isBreakAvailable else {   // UI-layer availability guard (unchanged, 7.1 step 1)
      Log.info("Break is not available", category: .strategy); return
    }
    let now = Date()
    let profile = session.blockedProfile
    let deadline = now.addingTimeInterval(TimeInterval(profile.breakTimeInMinutes * 60))
    let live = BlockedProfiles.getSnapshot(for: profile)

    // 7.1 step 3 — register the backstop BEFORE lifting (D-C2-3). Throw ⇒ abort fail-closed.
    do {
      try backstopRegistrar.replaceBreakBackstop(profileId: profile.id, deadline: deadline, now: now)
    } catch {
      errorMessage = "Couldn't start your break. Please try again."
      Log.error("startBreak: backstop registration failed: \(error.localizedDescription)", category: .timer)
      return
    }

    // 7.1 step 4 — open the grant (one section: identity, OMM absorption, lift).
    let opened = SharedData.openBreakGrant(
      startDate: now, deadline: deadline, expectedSessionId: session.id, liveSnapshot: live, applier: appBlocker)
    guard opened else {
      backstopRegistrar.removeBreakBackstop(profileId: profile.id)   // undo the just-made registration
      try? loadActiveSession(context: context)
      errorMessage = "This session changed. Please try again."       // #237-style (X14)
      return
    }
    backstopRegistrar.removeOneMoreMinuteBackstop(profileId: profile.id)  // OMM absorbed by openBreakGrant
    mirrorGrantFieldsFromShared(session)

    // 7.1 step 5 — now-truthful side effects.
    scheduleBreakReminder(profile: profile)
    WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")
    liveActivityManager.updateBreakState(session: session)
  }
```

- [ ] **Step 5: Run — expect PASS** (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Foqos/Utils/StrategyManager.swift FoqosTests/StrategyManagerBreakOMMTests.swift
git commit -m "feat(c2): startBreak fail-closed rewrite + seam injection (T-C2-U10, #214)"
```

---

### Task 14: `StrategyManager.startOneMoreMinute` rewrite (§7.4, fixes #207)

**Files:**
- Modify: `Foqos/Utils/StrategyManager.swift` (`startOneMoreMinute` :165–194)
- Test: `FoqosTests/StrategyManagerBreakOMMTests.swift` (extend)

**Grounding:** today `startOneMoreMinute` (:165) already aborts before lifting because `startOneMoreMinuteActivity` throws (:178–184) — but it never *surfaces* the failure and the whole feature is a silent no-op because the 60s window always exceeds nothing it can register (#207). The rewrite registers the C2 backstop (wrap-anchor, honorable at 60s) and opens the grant, surfacing failure.

- [ ] **Step 1: Write the failing tests (T-C2-U11 + happy path)**

Extend `StrategyManagerBreakOMMTests`:
```swift
  func testGivenBlockingSession_WhenStartOneMoreMinute_ThenRegistersAndOpensGrant() {
    let session = try! seedActiveSession()
    let pid = session.blockedProfile.id
    manager.startOneMoreMinute(context: context)
    XCTAssertEqual(registrar.calls.first, .replaceOMM(pid))
    XCTAssertEqual(applier.calls, [.deactivate])
    let shared = SharedData.getActiveSharedSession()
    XCTAssertNotNil(shared?.oneMoreMinuteStartTime)
    XCTAssertNotNil(shared?.oneMoreMinuteDeadline)
    XCTAssertTrue(shared?.oneMoreMinuteUsed ?? false)
    XCTAssertNil(manager.errorMessage)
    _ = session
  }

  func testGivenBackstopThrows_WhenStartOneMoreMinute_ThenFailClosedNoLift() {  // U11 / #207
    _ = try! seedActiveSession()
    registrar.throwOnReplaceOMM = true
    manager.startOneMoreMinute(context: context)
    XCTAssertNil(SharedData.getActiveSharedSession()?.oneMoreMinuteStartTime)
    XCTAssertTrue(applier.calls.isEmpty)
    XCTAssertNotNil(manager.errorMessage)
  }
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Rewrite `startOneMoreMinute` (:165–194)**

```swift
  func startOneMoreMinute(context: ModelContext) {
    guard let session = activeSession else {
      Log.info("No active session for one more minute", category: .strategy); return
    }
    guard session.isOneMoreMinuteAvailable else {   // UI-layer availability guard (unchanged)
      Log.info("One more minute is not available", category: .strategy); return
    }
    let now = Date()
    let profile = session.blockedProfile
    let deadline = now.addingTimeInterval(60)
    let live = BlockedProfiles.getSnapshot(for: profile)

    do {
      try backstopRegistrar.replaceOneMoreMinuteBackstop(profileId: profile.id, deadline: deadline, now: now)
    } catch {
      errorMessage = "Couldn't grant one more minute. Please try again."
      Log.error("startOneMoreMinute: backstop registration failed: \(error.localizedDescription)", category: .timer)
      return
    }

    let opened = SharedData.openOneMoreMinuteGrant(
      startDate: now, deadline: deadline, expectedSessionId: session.id, liveSnapshot: live, applier: appBlocker)
    guard opened else {
      backstopRegistrar.removeOneMoreMinuteBackstop(profileId: profile.id)
      try? loadActiveSession(context: context)
      errorMessage = "This session changed. Please try again."
      return
    }
    mirrorGrantFieldsFromShared(session)
    liveActivityManager.updateOneMoreMinuteState(session: session)
    WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")
  }
```

- [ ] **Step 4: Run — expect PASS** (2 new tests).

- [ ] **Step 5: Commit**

```bash
git add Foqos/Utils/StrategyManager.swift FoqosTests/StrategyManagerBreakOMMTests.swift
git commit -m "feat(c2): startOneMoreMinute rewrite via C2 backstop + grant (T-C2-U11, #207)"
```

---
### Task 15: `stopBreak` early-end + raw-field `toggleBreak` routing + visible affordance (§7.2, fixes #260/X32)

**Files:**
- Modify: `Foqos/Utils/StrategyManager.swift` (`stopBreak` :787–812; `toggleBreak` :152–163)
- Modify: `Foqos/Models/BlockedProfileSessions.swift` (add `isBreakOpenRawFields`)
- Modify: `Foqos/Components/BlockedProfileCards/ProfileTimerButton.swift` (:8–9, :24–25, :82) and its call site `Foqos/Components/BlockedProfileCards/BlockedProfileCard.swift:158`
- Test: `FoqosTests/StrategyManagerBreakOMMTests.swift` (extend); `FoqosTests/BlockedProfileSessionTests.swift` (extend for the pure predicate)

**Grounding:** `stopBreak` today guards on `!session.isBreakAvailable` (:793) — the wrong guard (#260): it re-blocks nothing and relies on the extension callback. `toggleBreak` routes on `isBreakActive` (:158, `enableBreaks`-conjuncted). The break button shows only `if isBreakAvailable` (ProfileTimerButton :82). All three must switch to the raw-field open predicate so a mid-break `enableBreaks`-off edit cannot strand the user (X32).

- [ ] **Step 1: Write the failing tests (T-C2-U14 two-tap; raw-field routing under enableBreaks-off; pure predicate)**

Extend `BlockedProfileSessionTests`:
```swift
  func testGivenBreakOpenRawFields_WhenEnableBreaksOff_ThenIsBreakOpenRawFieldsStaysTrue() {
    let profile = BlockedProfiles(name: "P"); profile.enableBreaks = false
    let session = BlockedProfileSession(tag: "t", blockedProfile: profile)
    session.breakStartTime = Date(); session.breakEndTime = nil
    XCTAssertTrue(session.isBreakOpenRawFields)   // raw fields ignore enableBreaks (I11)
    XCTAssertFalse(session.isBreakActive)          // enableBreaks-conjuncted ⇒ false
  }
```
Extend `StrategyManagerBreakOMMTests`:
```swift
  func testGivenBreakStarted_WhenToggleBreakAgain_ThenClosesReblocksAndDeregisters() {  // U14 / X1
    let session = try! seedActiveSession()
    let pid = session.blockedProfile.id
    manager.toggleBreak(context: context)   // start
    manager.toggleBreak(context: context)   // stop (raw-field open ⇒ stopBreak)
    let shared = SharedData.getActiveSharedSession()
    XCTAssertNotNil(shared?.breakEndTime, "grant closed (committed) before deregister (I7)")
    XCTAssertEqual(applier.calls, [.deactivate, .activate])
    XCTAssertEqual(registrar.calls, [.replaceBreak(pid), .removeBreak(pid)], "removeBreak is last (I7)")
    XCTAssertFalse(session.isBreakAvailable, "break consumed this session")
  }

  func testGivenBreakOpenAndEnableBreaksOff_WhenToggleBreak_ThenStillRoutesToStop() {  // X32 anti-stranding
    let session = try! seedActiveSession()
    manager.toggleBreak(context: context)                // start
    session.blockedProfile.enableBreaks = false          // mid-break edit
    try? context.save()
    manager.toggleBreak(context: context)                // must still stop, not mis-route to start
    XCTAssertNotNil(SharedData.getActiveSharedSession()?.breakEndTime, "raw-field routing ends the break")
  }
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Add the raw-field predicate to the model**

In `BlockedProfileSessions.swift` (near `isBreakActive` :31):
```swift
  /// Raw-field break-open predicate (I11) — NOT `enableBreaks`-conjuncted. Drives enforcement routing
  /// and the stop-break affordance so a mid-break `enableBreaks`-off edit cannot strand the user (X32).
  var isBreakOpenRawFields: Bool {
    return breakStartTime != nil && breakEndTime == nil
  }
```

- [ ] **Step 4: Route `toggleBreak` on raw fields (:152–163)**

```swift
  func toggleBreak(context: ModelContext) {
    guard let session = activeSession else {
      Log.info("No active session to toggle break", category: .strategy); return
    }
    if session.isBreakOpenRawFields {   // was: session.isBreakActive
      stopBreak(context: context)
    } else {
      startBreak(context: context)
    }
  }
```

- [ ] **Step 5: Rewrite `stopBreak` (:787–812)**

```swift
  private func stopBreak(context: ModelContext) {
    guard let session = activeSession else { return }
    guard session.isBreakOpenRawFields else {   // 7.2 step 1 — raw-field guard (was !isBreakAvailable at :793)
      Log.info("No open break to stop", category: .strategy); return
    }
    let now = Date()
    let profile = session.blockedProfile
    let live = BlockedProfiles.getSnapshot(for: profile)

    // 7.2 step 2 — explicit early-end close (skips the deadline gate); re-blocks in-process.
    let closed = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: session.id, explicit: true, now: now, process: .mainApp,
      durationMinutes: profile.breakTimeInMinutes, liveSnapshot: live, applier: appBlocker)
    guard closed else {
      try? loadActiveSession(context: context)
      errorMessage = "This session changed. Please try again."
      return
    }
    mirrorGrantFieldsFromShared(session)

    // 7.2 step 3 — THEN deregister (I7: a synthetic intervalDidEnd now observes a closed grant).
    backstopRegistrar.removeBreakBackstop(profileId: profile.id)
    timersUtil.cancelAllNotifications()
    WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")
    liveActivityManager.updateBreakState(session: session)
  }
```

- [ ] **Step 6: Keep the stop-break affordance visible on raw-field open**

In `ProfileTimerButton.swift`, add an input after `isBreakActive` (:9):
```swift
  let isBreakOpenRawFields: Bool
```
Change `breakMessage` (:24–25):
```swift
  var breakMessage: String {
    let showingStop = isBreakActive || isBreakOpenRawFields
    return "Hold to" + (showingStop ? " Stop Break" : " Start Break")
  }
```
Change the break button visibility (:82):
```swift
      if isBreakAvailable || isBreakOpenRawFields {
```
Update the three `#Preview` `ProfileTimerButton(...)` inits (:117/:131/:145) and the real call site `BlockedProfileCard.swift:158` to pass `isBreakOpenRawFields: session.isBreakOpenRawFields` (previews may pass `false`).

- [ ] **Step 7: Run — expect PASS** (3 tests). Build once to confirm the view call sites compile.

- [ ] **Step 8: Commit**

```bash
git add Foqos/Utils/StrategyManager.swift Foqos/Models/BlockedProfileSessions.swift Foqos/Components/BlockedProfileCards/ FoqosTests/StrategyManagerBreakOMMTests.swift FoqosTests/BlockedProfileSessionTests.swift
git commit -m "feat(c2): stopBreak early-end + raw-field routing + visible affordance (T-C2-U14, #260, X32)"
```

---

### Task 16: Foreground ticker expiry executor + deadline-driven countdown (§7.4b, fixes #205 foreground)

**Files:**
- Modify: `Foqos/Utils/StrategyManager.swift` (`startTimer` loop :196–218; add `evaluateGrantExpiry`, `grantCountdownRemaining`)
- Test: `FoqosTests/StrategyManagerBreakOMMTests.swift` (extend)

**Grounding:** the 1-second `timerTask` loop (:198–217) today only recomputes `elapsedTime` from `breakStartTime + breakTimeInMinutes` and performs **no** expiry action (grounding confirmed). C2 assigns it as the foreground executor for BOTH grant types (7.4b), deregistering the backstop **only on a true close** (rev-6), and drives all countdowns from the **persisted deadline** (U35).

- [ ] **Step 1: Write the failing tests (T-C2-U17, U35)**

Extend `StrategyManagerBreakOMMTests`:
```swift
  func testGivenExpiredBreak_WhenEvaluateGrantExpiry_ThenClosesAndRemovesBackstop() {  // U17
    let session = try! seedActiveSession()
    let now = Date()
    manager.toggleBreak(context: context)  // opens grant
    // Force the deadline into the past on both shared + model.
    if var s = SharedData.getActiveSharedSession() { s.breakEndDeadline = now.addingTimeInterval(-1); SharedData.rawCommitActiveSession(s) }
    session.breakEndDeadline = now.addingTimeInterval(-1)
    applier = RecordingRestrictionApplier()  // fresh to isolate the close
    registrar.clearForAssertion()            // helper: reset recorded calls (add to spy)
    manager.evaluateGrantExpiry(now: now)
    XCTAssertNotNil(SharedData.getActiveSharedSession()?.breakEndTime)
  }

  func testGivenUnexpiredBreak_WhenEvaluateGrantExpiry_ThenNoOp() {  // U17 negative
    let session = try! seedActiveSession()
    let now = Date()
    manager.toggleBreak(context: context)
    manager.evaluateGrantExpiry(now: now)  // deadline is now+300 ⇒ not expired
    XCTAssertNil(SharedData.getActiveSharedSession()?.breakEndTime)
    _ = session
  }

  func testGivenBreakDeadline_WhenGrantCountdownRemaining_ThenFromDeadlineNotProfileDuration() {  // U35
    let session = try! seedActiveSession(breakMinutes: 5)
    let now = Date()
    manager.toggleBreak(context: context)
    // countdown ≈ 300s from the persisted deadline
    let r1 = manager.grantCountdownRemaining(now: now)
    XCTAssertNotNil(r1); XCTAssertEqual(r1!, 300, accuracy: 2)
    session.blockedProfile.breakTimeInMinutes = 1   // shrink the profile duration mid-break
    try? context.save()
    let r2 = manager.grantCountdownRemaining(now: now)
    XCTAssertEqual(r2!, 300, accuracy: 2, "countdown follows the persisted deadline, not the edited duration")
  }
```
(Add to `RecordingRestrictionApplier`/`RecordingBackstopRegistrar` a `func clearForAssertion() { calls.removeAll() }` convenience.)

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Add the executor + countdown helpers**

In `StrategyManager.swift`:
```swift
  /// 7.4b — foreground expiry executor for BOTH grant types. Deregister only on a TRUE close (rev-6).
  func evaluateGrantExpiry(now: Date = Date()) {
    guard let session = activeSession else { return }
    let profile = session.blockedProfile
    let live = BlockedProfiles.getSnapshot(for: profile)
    if session.oneMoreMinuteStartTime != nil {
      let closed = SharedData.closeOneMoreMinuteGrantIfExpired(
        expectedSessionId: session.id, now: now, process: .mainApp, liveSnapshot: live, applier: appBlocker)
      if closed { backstopRegistrar.removeOneMoreMinuteBackstop(profileId: profile.id); mirrorGrantFieldsFromShared(session) }
    }
    if session.breakStartTime != nil && session.breakEndTime == nil {
      let closed = SharedData.closeBreakGrantIfExpiredOrExplicit(
        expectedSessionId: session.id, explicit: false, now: now, process: .mainApp,
        durationMinutes: profile.breakTimeInMinutes, liveSnapshot: live, applier: appBlocker)
      if closed { backstopRegistrar.removeBreakBackstop(profileId: profile.id); mirrorGrantFieldsFromShared(session) }
    }
  }

  /// 7.4b — remaining seconds for the open grant, derived from the PERSISTED deadline (U35).
  func grantCountdownRemaining(now: Date = Date()) -> TimeInterval? {
    guard let session = activeSession else { return nil }
    if session.breakStartTime != nil && session.breakEndTime == nil, let d = session.breakEndDeadline {
      return max(0, d.timeIntervalSince(now))
    }
    if session.oneMoreMinuteStartTime != nil, let d = session.oneMoreMinuteDeadline {
      return max(0, d.timeIntervalSince(now))
    }
    return nil
  }
```
Rewrite the `timerTask` loop body (:198–217) so each tick runs the executor and derives the countdown from the deadline:
```swift
    timerTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { break }
        guard let self, let session = self.activeSession else { break }
        let now = Date()
        self.evaluateGrantExpiry(now: now)                       // 7.4b expiry executor
        if let remaining = self.grantCountdownRemaining(now: now) {
          self.elapsedTime = remaining                            // deadline-driven (U35)
        } else {
          let rawElapsedTime = now.timeIntervalSince(session.startTime)
          self.elapsedTime = rawElapsedTime - session.calculateBreakDuration()
        }
      }
    }
```

- [ ] **Step 4: Run — expect PASS** (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Foqos/Utils/StrategyManager.swift FoqosTests/StrategyManagerBreakOMMTests.swift FoqosTests/Helpers/C2Spies.swift FoqosTests/Helpers/RecordingBackstopRegistrar.swift
git commit -m "feat(c2): foreground ticker expiry executor + deadline countdown (T-C2-U17, U35)"
```

---
### Task 17: Reconciler M-wrapper + `loadActiveSession` wiring (§7.5 M-duties, I5/X16/X30/U31)

**Files:**
- Modify: `Packages/FoqosShared/Sources/FoqosShared/RestrictionGrants.swift` (add `completeGrantMigration`)
- Modify: `Foqos/Utils/StrategyManager.swift` (add `reconcileGrants`, `rearmBackstopsIfNeeded`, `failClosedCloseBreak`/`failClosedCloseOMM`; wire into `loadActiveSession` :89–110)
- Test: `FoqosTests/HealExpiredLiftsTests.swift` (extend for `completeGrantMigration`); `FoqosTests/StrategyManagerBreakOMMTests.swift` (extend for the M-wrapper duties)

**Grounding (GC2):** the M reconciler hook is `loadActiveSession` (the sink for HomeView :236/:277/:282/:299), **not** `FoqosApp`. Wire `reconcileGrants(context:)` there. The extension side (Task 11) already calls the FoqosShared core. `BlockedProfiles.updateSnapshot(for:)` (:541) is the M snapshot-repair primitive.

**M-only duties layered on the Task-10 core:** legacy **full** migration (completion-keyed: stamp + pin + C2 backstop — U31); backstop **re-arm** (register-if-absent, never stop — I5); on re-arm failure, **fail-closed close** (X16); snapshot **repair** via `updateSnapshot`; **orphan sweep** (hygiene).

- [ ] **Step 1: Write the failing `completeGrantMigration` tests (T-C2-U31)**

Extend `HealExpiredLiftsTests`:
```swift
  func testGivenLegacyOpenBreakNoDeadlineNoPin_WhenCompleteMigration_ThenStampsAndPins() {  // U31
    let now = Date(); let pid = UUID(); let pinned = snap(pid)
    let (_, _) = seed({ $0.breakStartTime = now.addingTimeInterval(-60) }, pid: pid)  // deadline nil, pin nil
    let changed = SharedData.completeGrantMigration(
      expectedSessionId: "s", breakDurationMinutes: 5, pinned: pinned, now: now)
    XCTAssertTrue(changed)
    let s = SharedData.getActiveSharedSession()
    XCTAssertEqual(s?.breakEndDeadline, now.addingTimeInterval(-60).addingTimeInterval(300))
    XCTAssertEqual(s?.pinnedProfileConfig?.id, pid)
  }

  func testGivenXAlreadyStampedDeadlineButNoPin_WhenCompleteMigration_ThenStillPins() {  // completion-keyed, not nil-keyed
    let now = Date(); let pid = UUID(); let pinned = snap(pid)
    let (_, _) = seed({ $0.breakStartTime = now.addingTimeInterval(-60); $0.breakEndDeadline = now.addingTimeInterval(240) }, pid: pid)
    let changed = SharedData.completeGrantMigration(expectedSessionId: "s", breakDurationMinutes: 5, pinned: pinned, now: now)
    XCTAssertTrue(changed, "pin still completed even though deadline was already stamped")
    XCTAssertEqual(SharedData.getActiveSharedSession()?.pinnedProfileConfig?.id, pid)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.breakEndDeadline, now.addingTimeInterval(240), "existing deadline untouched")
  }

  func testGivenFullyMigratedGrant_WhenCompleteMigration_ThenNoChange() {
    let now = Date(); let pid = UUID(); let pinned = snap(pid)
    let (_, _) = seed({ $0.breakStartTime = now.addingTimeInterval(-60); $0.breakEndDeadline = now.addingTimeInterval(240); $0.pinnedProfileConfig = pinned }, pid: pid)
    XCTAssertFalse(SharedData.completeGrantMigration(expectedSessionId: "s", breakDurationMinutes: 5, pinned: pinned, now: now))
  }
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement `completeGrantMigration`**

Append to `RestrictionGrants.swift`:
```swift
extension SharedData {
  /// §7.5.1 M full migration — completion-keyed (rev-6, U31): stamp missing deadlines AND pin the
  /// re-block config for any OPEN grant. Keyed on missing pieces (not nil-deadline) so an earlier
  /// X-side stamp cannot skip the pin. Returns whether anything changed. Backstop registration is a
  /// separate main-app step (registration is never a FoqosShared duty, I5).
  @discardableResult
  public static func completeGrantMigration(
    expectedSessionId: String, breakDurationMinutes: Int, pinned: ProfileSnapshot?, now: Date,
    commit: (SessionSnapshot?) -> Bool = { rawCommitActiveSession($0) }
  ) -> Bool {
    withLockStatus(blocking: true) { _ in
      guard var s = rawActiveSession, s.endTime == nil, s.id == expectedSessionId else { return false }
      var changed = false
      if s.breakStartTime != nil && s.breakEndTime == nil {
        if s.breakEndDeadline == nil, let start = s.breakStartTime {
          s.breakEndDeadline = start.addingTimeInterval(TimeInterval(breakDurationMinutes * 60)); changed = true
        }
        if s.pinnedProfileConfig == nil, let pinned { s.pinnedProfileConfig = pinned; changed = true }
      }
      if s.oneMoreMinuteStartTime != nil {
        if s.oneMoreMinuteDeadline == nil, let start = s.oneMoreMinuteStartTime {
          s.oneMoreMinuteDeadline = start.addingTimeInterval(60); changed = true
        }
        if s.pinnedProfileConfig == nil, let pinned { s.pinnedProfileConfig = pinned; changed = true }
      }
      guard changed else { return false }
      return commit(s)
    }
  }
}
```

- [ ] **Step 4: Implement the M wrapper + wiring**

In `StrategyManager.swift`:
```swift
  /// §7.5 reconciler — MAIN-APP entry. Calls the cross-process core, then performs the main-app-only
  /// duties: full legacy migration (stamp+pin+backstop), backstop re-arm, snapshot repair, orphan sweep.
  func reconcileGrants(context: ModelContext, now: Date = Date()) {
    guard let session = activeSession else {
      SharedData.applyRestrictionsForCurrentState(process: .mainApp, liveSnapshot: nil, applier: appBlocker)
      return
    }
    let profile = session.blockedProfile
    BlockedProfiles.updateSnapshot(for: profile)                 // 7.5.4 snapshot repair (rebuild app-group snapshot)
    let live = BlockedProfiles.getSnapshot(for: profile)

    // 7.5.1–2, 6: stamp/close expired + converge (core).
    SharedData.reconcileExpiredGrants(
      process: .mainApp, now: now, liveSnapshot: live, breakDurationMinutes: profile.breakTimeInMinutes, applier: appBlocker)
    mirrorGrantFieldsFromShared(session)

    // For a still-open grant: complete migration + re-arm the C2 backstop.
    if let shared = SharedData.getActiveSharedSession(), shared.id == session.id, shared.endTime == nil,
       SharedData.hasOpenGrant(shared) {
      SharedData.completeGrantMigration(
        expectedSessionId: session.id, breakDurationMinutes: profile.breakTimeInMinutes, pinned: live, now: now)
      mirrorGrantFieldsFromShared(session)
      rearmBackstopsIfNeeded(profileId: profile.id, now: now)
    }
    DeviceActivityCenterUtil.removeC2BackstopsExcept(profileId: profile.id)  // 7.5.5 orphan sweep (hygiene)
  }

  /// 7.5.3 re-arm: register the C2 backstop iff absent (never stop, I5). Failure ⇒ fail-closed close (X16).
  private func rearmBackstopsIfNeeded(profileId: UUID, now: Date) {
    guard let shared = SharedData.getActiveSharedSession() else { return }
    if shared.breakStartTime != nil, shared.breakEndTime == nil, let d = shared.breakEndDeadline, now < d {
      do { _ = try backstopRegistrar.registerBreakBackstopIfAbsent(profileId: profileId, deadline: d, now: now) }
      catch { failClosedCloseBreak(profileId: profileId, now: now) }
    }
    if shared.oneMoreMinuteStartTime != nil, let d = shared.oneMoreMinuteDeadline, now < d {
      do { _ = try backstopRegistrar.registerOneMoreMinuteBackstopIfAbsent(profileId: profileId, deadline: d, now: now) }
      catch { failClosedCloseOMM(profileId: profileId, now: now) }
    }
  }

  /// X16 fail-closed close: no OS wake can be guaranteed ⇒ end the (possibly unexpired) grant early,
  /// re-block, cancel notifications, surface why. Consumes the one-per-session grant.
  private func failClosedCloseBreak(profileId: UUID, now: Date) {
    guard let session = activeSession else { return }
    let live = BlockedProfiles.getSnapshot(for: session.blockedProfile)
    _ = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: session.id, explicit: true, now: now, process: .mainApp,
      durationMinutes: session.blockedProfile.breakTimeInMinutes, liveSnapshot: live, applier: appBlocker)
    mirrorGrantFieldsFromShared(session)
    backstopRegistrar.removeBreakBackstop(profileId: profileId)
    timersUtil.cancelAllNotifications()
    errorMessage = "Your break ended early — it couldn't be scheduled in the background."
  }
  private func failClosedCloseOMM(profileId: UUID, now: Date) {
    guard let session = activeSession else { return }
    let live = BlockedProfiles.getSnapshot(for: session.blockedProfile)
    // `force: true` closes the OMM grant in-section regardless of its deadline — no out-of-lock raw write.
    _ = SharedData.closeOneMoreMinuteGrantIfExpired(
      expectedSessionId: session.id, now: now, process: .mainApp, liveSnapshot: live, force: true, applier: appBlocker)
    mirrorGrantFieldsFromShared(session)
    backstopRegistrar.removeOneMoreMinuteBackstop(profileId: profileId)
    timersUtil.cancelAllNotifications()
    errorMessage = "One more minute ended early — it couldn't be scheduled in the background."
  }
```
Add the orphan-sweep helper to `DeviceActivityCenterUtil.swift`:
```swift
  /// 7.5.5 — remove any C2 backstop registered for a profile OTHER than `profileId` (hygiene; I9 means
  /// at most one grant is ever active). Never load-bearing (leaked registrations no-op forever).
  static func removeC2BackstopsExcept(profileId: UUID) {
    let keepBreak = "\(BreakDeadlineBackstopActivity.id):\(profileId.uuidString)"
    let keepOMM = "\(OneMoreMinuteDeadlineBackstopActivity.id):\(profileId.uuidString)"
    let center = DeviceActivityCenter()
    let stale = center.activities.filter {
      let r = $0.rawValue
      let isC2 = r.starts(with: BreakDeadlineBackstopActivity.id) || r.starts(with: OneMoreMinuteDeadlineBackstopActivity.id)
      return isC2 && r != keepBreak && r != keepOMM
    }
    if !stale.isEmpty { center.stopMonitoring(stale) }
  }
```
Wire the reconciler into `loadActiveSession` (:89): inside the `if activeSession?.isActive == true` block (:98–107), after `startTimer()` (:99), add:
```swift
      reconcileGrants(context: context)   // §7.5 M reconcile on launch + every foreground pass (GC2)
```

- [ ] **Step 5: Write the M-wrapper wiring test (re-arm + fail-closed)**

Extend `StrategyManagerBreakOMMTests`:
```swift
  func testGivenOpenUnexpiredBreakBackstopAbsent_WhenReconcile_ThenRearmsIfAbsent() {  // U18 re-arm
    let session = try! seedActiveSession()
    manager.toggleBreak(context: context)                 // open grant (registrar recorded replaceBreak)
    registrar.hasBreakBackstopReturns = false             // simulate absent
    registrar.clearForAssertion()
    manager.reconcileGrants(context: context)
    XCTAssertTrue(registrar.calls.contains(.registerBreakIfAbsent(session.blockedProfile.id)))
  }

  func testGivenRearmThrows_WhenReconcile_ThenFailClosedClosesBreak() {  // X16
    let session = try! seedActiveSession()
    manager.toggleBreak(context: context)
    registrar.throwOnRegisterIfAbsent = true
    manager.reconcileGrants(context: context)
    XCTAssertNotNil(SharedData.getActiveSharedSession()?.breakEndTime, "fail-closed close ends the grant")
    XCTAssertNotNil(manager.errorMessage)
    _ = session
  }
```

- [ ] **Step 6: Run — expect PASS** (3 + 2 tests). Run the full `FoqosTests` suite once — this task changes `loadActiveSession`, exercised by many tests.

- [ ] **Step 7: Commit**

```bash
git add Packages/FoqosShared/Sources/FoqosShared/RestrictionGrants.swift Foqos/Utils/StrategyManager.swift Foqos/Utils/DeviceActivityCenterUtil.swift FoqosTests/
git commit -m "feat(c2): reconciler M-wrapper (migration/re-arm/repair/fail-closed) + loadActiveSession wiring (T-C2-U31, U18, X16)"
```

---

### Task 18: CI guard script (T-C2-U21, U28, guard-parity)

**Files:**
- Create: `scripts/check-c2-guards.sh`
- Modify: the CI workflow that runs `scripts/check-sync-guards.sh` (add a call to the new script) — locate via `grep -rn "check-sync-guards" .github`
- Test: the script itself (run it; it must exit non-zero on a planted violation, zero on clean tree)

**Interfaces:** three grep-based invariants that a future edit cannot silently break (all are silent-lock-loss or lost-bound hazards, not compile errors):
1. **U21** — `AppBlockerUtil` stays lock-free: no `withLock`/`SharedData.` accessor call inside `AppBlockerUtil.swift`.
2. **U28** — the extension never mutates registrations: no `startMonitoring`/`stopMonitoring` in `FoqosDeviceMonitor/` or in the extension-reachable backstop handlers.
3. **Guard-parity** — C2 grant sections never call the public `withLock`-wrapped `SharedData` accessors inside a `withLockStatus` body (silent lock-loss, D-C2-4(ii)).

- [ ] **Step 1: Write the script**

`scripts/check-c2-guards.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0

# (1) T-C2-U21 — AppBlockerUtil must stay lock-free (G15).
if grep -nE 'withLock|SharedData\.(get|set|end|start|clear|flush|create)' \
     Packages/FoqosShared/Sources/FoqosShared/AppBlockerUtil.swift; then
  echo "❌ AppBlockerUtil must not lock or read SharedData (G15/T-C2-U21)"; fail=1
fi

# (2) T-C2-U28 — the monitor extension must never mutate DeviceActivity registrations (I5).
if grep -rnE '\.(startMonitoring|stopMonitoring)\(' FoqosDeviceMonitor/; then
  echo "❌ Extension must not call start/stopMonitoring (I5/T-C2-U28)"; fail=1
fi
# The extension-reachable backstop/legacy handlers likewise never register:
for f in Packages/FoqosShared/Sources/FoqosShared/Timers/BreakDeadlineBackstopActivity.swift \
         Packages/FoqosShared/Sources/FoqosShared/Timers/OneMoreMinuteDeadlineBackstopActivity.swift \
         Packages/FoqosShared/Sources/FoqosShared/Timers/BreakTimerActivity.swift \
         Packages/FoqosShared/Sources/FoqosShared/Timers/OneMoreMinuteTimerActivity.swift; do
  if grep -nE '\.(startMonitoring|stopMonitoring)\(' "$f"; then
    echo "❌ $f (extension-reachable) must not register (I5)"; fail=1
  fi
done

# (3) Guard-parity — no public withLock-wrapped SharedData accessor inside a C2 grant section.
# RestrictionGrants.swift bodies run inside withLockStatus; they must use rawActiveSession /
# rawCommitActiveSession, never getActiveSharedSession()/set*/end*/create* (non-reentrant → silent lock loss).
if grep -nE 'SharedData\.(getActiveSharedSession|setBreak|setOneMoreMinute|clearOneMoreMinute|setEndTime|endActiveSharedSession|createActiveSharedSession|flushActiveSession)\(' \
     Packages/FoqosShared/Sources/FoqosShared/RestrictionGrants.swift; then
  echo "❌ RestrictionGrants sections must use raw* seams, not public withLock accessors (D-C2-4(ii))"; fail=1
fi

if [ "$fail" -eq 0 ]; then echo "✅ C2 guards passed"; fi
exit $fail
```

- [ ] **Step 2: Make it executable and run on the clean tree**

Run:
```bash
chmod +x scripts/check-c2-guards.sh
./scripts/check-c2-guards.sh
```
Expected: `✅ C2 guards passed`, exit 0.

- [ ] **Step 3: Prove it catches a violation**

Temporarily add `_ = SharedData.getActiveSharedSession()` inside a `RestrictionGrants.swift` section, run the script, confirm it exits non-zero with the guard-parity message, then revert the planted line.

- [ ] **Step 4: Wire into CI**

Locate the CI step that runs `scripts/check-sync-guards.sh` (`grep -rn "check-sync-guards" .github`) and add a sibling step invoking `scripts/check-c2-guards.sh` in the same job.

- [ ] **Step 5: Commit**

```bash
git add scripts/check-c2-guards.sh .github/
git commit -m "chore(c2): CI guards for lock-free AppBlockerUtil, no-extension-registration, section raw-reads (T-C2-U21, U28)"
```

---
## Device Verification (manual checklist for the implementer's PR)

The simulator does not run DeviceActivity; run these on a device build. Attach os_log observations to the PR.

| ID | Scenario | Pass criteria |
|---|---|---|
| T-C2-D1 | #260 two-tap: start break → immediate stop | Shields return **instantly**; session continues; break shows consumed. |
| T-C2-D2 | 5-minute break, app backgrounded through expiry (MD-C2-1 = A) | Shields return within deadline + ~1 min. |
| T-C2-D3 | OMM backgrounded at expiry; then OMM foreground | Background: shields within ~1–2 min (R2). Foreground: exact at 60s. |
| T-C2-D4 | Kill app mid-break; wait past deadline; relaunch | Immediate heal on relaunch (reconciler in `loadActiveSession`, X10). |
| T-C2-D5 | (Optional, non-blocking) `stopMonitoring` synthetic `intervalDidEnd` | Confirms R4's separate-issue exposure; **out of C2 scope** — file separately if positive. |
| T-C2-D6 | §10 probe #2 — wrap-anchor short-lead `intervalDidEnd` delivery | **✅ ALREADY RUN AND PASSED 2026-07-07** (contract §10). No re-run unless the deployment target or registration shape changes. |

**Also run once on device:** open the app on a **stop-scheduled profile mid-session** and watch whether the stop-schedule re-registration coalesces or emits a synthetic end — this is the **R4** half-probe. **It is tracked OUTSIDE C2** (§1 of the contract); if positive, file it as its own issue. Do **not** modify `StrategyManager` :107/:666 or `scheduleStopActivity` under this plan.

---

## Notes carried from the contract (do not re-litigate)

- **MD-C2-1/2/3 = A, settled.** Keep 5/10/15/30 break durations (no sub-15 lower clamp — `getTimeIntervalStartAndEnd` stays upper-bound-only, :422–424). A break **absorbs** an open OMM (one-way; early-ending the break forfeits the absorbed remainder — accepted). Bounded OMM background overrun accepted (R2).
- **R1–R8 residuals** are accepted and documented in the contract; this plan does not attempt to close R1 (dead-app dropped-callback window) beyond the reconciler's "next wake of any kind" bound. No iOS mechanism closes R1 to zero.
- **R4 (stop-schedule re-registration)** is out of scope — see above.
- **Contract ambiguities encountered while writing this plan:** none blocked translation. Three contract *citations* were wrong (GC1/GC2/GC8/GC9 in §Grounding Corrections) but the *mechanism* was unambiguous; the corrected file targets are used. If an implementer hits a genuine mechanism ambiguity, STOP and flag it rather than improvising (Global Constraints).

---

## Self-Review (author checklist, run against the contract)

**Spec coverage — every contract §6/§7 element has a task:** schema+pin §6.1/6.1a → T1; `wrapAnchorInterval` §6.7 → T2; applier seam → T3; deriver §6.6/D-C2-4 → T4; encode-then-commit + section runner §D-C2-4(ii)(iii)/rev-6 → T5; `openBreakGrant`/`openOneMoreMinuteGrant` §6.2/6.3 → T6; closers §6.5 → T7; `closeGrantsForSessionEnd` §6.4 → T8; `applyRestrictionsForCurrentState` §6.6 → T9; reconciler core §7.5 → T10; extension handlers §7.3 → T11; registration helpers §6.7/I5 → T12; `startBreak` §7.1 → T13; `startOneMoreMinute` §7.4 → T14; `stopBreak`+routing §7.2 → T15; ticker §7.4b → T16; M-reconciler duties §7.5 → T17; guards D-C2-4/I5 → T18. **No §6/§7 element unassigned.**

**Invariant coverage:** I1–I11 each map to a test in the Mapping Table §A. **Interleaving coverage:** X1–X38 each map in §B. **Named-scenario coverage:** T-C2-U1–U35 and T-C2-D1–D6 each map in §C. Verified no gaps.

**Type/signature consistency (checked across tasks):** `RestrictionDecision`/`RestrictionProcess` (T4) used identically in T6–T10, T17. `openBreakGrant`/`openOneMoreMinuteGrant` signatures (T6) match their `StrategyManager` call sites (T13/T14). Closer signatures (T7) match every caller (T10 core, T11 handlers, T15 stopBreak, T16 ticker, T17 fail-closed). `BackstopRegistering` methods (T12) match spy (T12) and all `StrategyManager` calls (T13–T17). `session.id: String` used as `expectedSessionId` everywhere (matches `endSession` :82). `mirrorGrantFieldsFromShared` (T13) reused by T14–T17. Backstop ids `"BreakDeadlineBackstop"`/`"OneMoreMinuteDeadlineBackstop"` (T11) referenced consistently in T12/T18.

**Placeholder scan:** no "TBD"/"handle appropriately"/"similar to Task N"; every code step shows complete code; every run step gives the exact command + expected result. One deliberately-flagged CONFIRM-ON-IMPLEMENT item (T5, the `configureLockPath` nil-forcing signature) — grounding verified the seam exists at `SharedData.swift:41–56`; the implementer confirms the exact call. This is a verification note, not a placeholder.

**Known coupling to verify at build (not blocking the plan):** T13's `appBlocker` type change (`AppBlockerUtil` → `RestrictionApplying`) must keep the two existing call sites (:189, :1222) compiling — both call only protocol methods (verified in grounding). T16's `[weak self]` ticker rewrite must preserve the existing `stopTimer()` cancellation contract.

---

## Skeptic Pass (1 adversarial round, 2026-07-07)

Per the reduced-ceremony budget (the design itself had five adversarial rounds), one skeptic reviewed this plan for **contract-conformance and test-coverage gaps only**. Eight findings, all accepted and folded in:

1. *(major, mechanism)* Task 11 `reconcileAfterWake` gated the extension reconcile on a non-nil live snapshot, wiring the §6.1a/X30 pinned-config convergence **out** of the missing-snapshot case → guard relaxed to allow nil `live` (falls back to the pin).
2. *(major, lock discipline)* Task 17 `failClosedCloseOMM` mutated state with an **out-of-lock** raw write (the OMM closer lacked a force path) → added `force:` to `closeOneMoreMinuteGrantIfExpired`; the fail-closed close now runs in-section.
3. *(major, test strength)* T-C2-U33 was "tested" via the nil-lockPath branch, never exercising the `LOCK_NB` bounded retry → added a real **held-lock** test in Task 5; U33 remapped there.
4. *(major, coverage)* X23/X30 mapping was falsely green because the mapped test bypassed the (then-broken) wiring → resolved by fix #1; coverage note added that the extension wiring is proven by the Task-10 core test + device (the extension target isn't unit-testable from `FoqosTests`).
5. *(minor, perf/correctness)* The OMM closer re-committed the full snapshot every non-expired tick → added a `didStamp` flag (mirrors the break closer); commits only a newly-written stamp.
6. *(minor, scope)* Task 8 cancelled notifications per ingest-iteration → cancel **once after** the loop, gated on a flag.
7. *(minor, consistency)* T-C2-U14 method name mismatched the mapping table → mapping aligned to the real method.
8. *(minor, verification)* `endSession` non-reentrancy was unverified → grounded (no `withLock`-nested caller) and noted in Task 8.

No finding challenged the mechanism (D-C2-1/2/4, I5, §6.1a, encode-then-commit, wrap-anchor). The two blocking-before-implementation items (#1, #2) are fixed above.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-07-c2-short-interval-break-omm.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration. **REQUIRED SUB-SKILL:** superpowers:subagent-driven-development. Note the AGENTS.md constraint: **no parallel builds/tests** — Xcode/simulator contention means implementation runs ONE stream at a time; subagents here must serialize any task that builds or tests.

**2. Inline Execution** — execute tasks in this session using superpowers:executing-plans, batching with review checkpoints.

**Sequencing note:** Tasks 1–10 are pure/FoqosShared and unit-testable without device concerns; Tasks 11–17 touch the extension and main app (build the whole workspace); Task 18 is CI. Boot the simulator ONCE (UUID) before Task 1 and reuse it. Request code review before merging (AGENTS.md).

**Which approach?**










