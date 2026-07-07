# C2 Design Contract — Short-Interval Enforcement & Break / One-More-Minute Lifecycle

- **Epic:** #263 (2026-07 defect audit), bundle **C2**
- **Issues:** #207 (OMM 60-second DeviceActivity always aborts), #214 (5/10-minute breaks never start), #205 (OMM expiry re-blocks mid-break), #260 (early break end never re-applies restrictions — CONFIRMED critical)
- **Status:** DESIGN CONTRACT — this is not an implementation plan and not code. A separate session writes the prescriptive plan from this contract.
- **Date:** 2026-07-06 (rev 6: 2026-07-07), authored against `main` @ `8c86df2` (post-C1 #275, post-D1 #279, post-D2 #277). **Rev 6** — five adversarial rounds' findings folded in; see §13 for the round log and the honest verification-status note.
- **Verification:** adversarial interleaving rounds per the A1/S0 standard; see §13 for the round log.

---

## 1. Scope and non-goals

**In scope**

1. The enforcement mechanism for sub-15-minute restriction-lift windows: 5/10-minute breaks (#214) and the 60-second one-more-minute (#207).
2. In-process break-end (#260), including the two-tap permanent-unblock reproduction.
3. The one-more-minute–expiry-during-break interaction (#205) — semantics proposed here as MAINTAINER DECISION MD-C2-2.
4. Whether the 5/10-minute break picker options survive — MAINTAINER DECISION MD-C2-1.

**Out of scope (binding boundaries)**

- C1's interval validation for session timers and schedules (#212/#228) — shipped in PR #275; this contract *reuses* its seams and changes none of them.
- D1's background-stop policy and monitor-extension stop/start semantics (#206/#229/#236/#239/#243/#261) — shipped in PR #279; this contract composes with it and re-gates nothing.
- The pre-existing stop-schedule re-registration risk flagged in the #260 verdict §2 (`scheduleStopActivity` stop-then-start on a live registration at every app open). C2 does not fix those sites — see §11 R4 and the probe in §10.
- Live Activity push-based updates from the extension (residual R3).
- Upstream `awaseem/foqos` behavior.

---

## 2. Grounding facts (verified against `main` @ 8c86df2)

| # | Fact | Where |
|---|------|-------|
| G1 | DeviceActivity rejects monitored intervals shorter than 15 minutes (`intervalTooShort`); the constraint is on window **length**, not distance-to-end. | `DeviceActivityLimits.minimumIntervalMinutes`; C1 plan |
| G2 | C1's shipped stop-anchor reshape: a `repeats: true` window with `intervalStart = stop+1min` (wrap, length 1439 min) legally delivers `intervalDidEnd` at a stop time that is only minutes away. | `DeviceActivityCenterUtil.stopScheduleInterval` (:455–469), consumed with `repeats: true` (:64, :130) |
| G3 | Break today: `startBreakTimerActivity` registers `now → now+N`, `repeats: false`; the **extension** lifts restrictions on `intervalDidStart` and re-blocks + writes `breakEndTime` on `intervalDidEnd`. The main app never lifts or re-blocks for breaks. | `DeviceActivityCenterUtil.swift:226–248`; `BreakTimerActivity.swift` |
| G4 | For N ∈ {5, 10} the break registration throws `intervalTooShort`, swallowed at `Log.info` (:246); `startBreak` proceeds to schedule the reminder and update UI for a break that never began (#214). | `DeviceActivityCenterUtil.swift:240–247`; `StrategyManager.startBreak` (:760–785) |
| G5 | `stopBreak` performs no re-block and no `breakEndTime` write — it deregisters the activity and reloads state "set in a different thread" (#260). The only re-blocker is the extension's `intervalDidEnd`, whose delivery is undocumented and demonstrably flaky in the field (upstream #358). | `StrategyManager.stopBreak` (:787–812); #260 verdict §§1–3 |
| G6 | OMM today: `startOneMoreMinuteActivity` registers a 60-second window with second precision; `startMonitoring` always throws; `startOneMoreMinute` correctly aborts **before** lifting — the feature is a silent no-op everywhere (#207). | `DeviceActivityCenterUtil.swift:309–348`; `StrategyManager.startOneMoreMinute` (:165–194) |
| G7 | OMM historically enforced only in the foreground via an in-process `Timer` + `resumeOneMoreMinuteIfNeeded()`; as-designed intent is 60 seconds enforced regardless of app state. | deviation-report.md deviation #1; as-built feature doc §OMM |
| G8 | `OneMoreMinuteTimerActivity.stop()` re-blocks whenever `oneMoreMinuteStartTime != nil` with no break-state check; a break may legally start during OMM's window (`isBreakAvailable` has no OMM condition), so OMM expiry re-blocks mid-break (#205). The converse is blocked today only by a **UI-layer, profile-derived** predicate (`isOneMoreMinuteAvailable` requires `!isBreakActive`, whose `enableBreaks` conjunct a profile edit can falsify mid-break) — NOT a structural impossibility; rev 3 enforces it structurally (§6.3). | `OneMoreMinuteTimerActivity.swift:29–57`; `BlockedProfileSessions.swift:26–29, 31–35, 42–44` |
| G9 | D1 shipped and binding: pure `BackgroundStopPolicy` (channels `.shortcut`/`.schedule`/`.takeover`), identity-gated `endActiveSharedSession(expectedSessionId:)`, atomic `startSchedulerSessionTakingOver(profileId:expectedVictimId:)`, `ProfileStopConditions` on `ProfileSnapshot`, and identity-gated break/OMM mutators (all taking `expectedSessionId`). All D1 MDRs settled = A. | `BackgroundStopPolicy.swift`; `SharedData.swift:395–542`; D1 plan |
| G10 | `SharedData.withLock` is the app-group mutual-exclusion primitive (non-reentrant; a withLock-wrapped method must never be called from inside another withLock closure). `activeSharedSessionMatchesExpected` is the identity gate. | `SharedData.swift:72–78, 464–478` |
| G11 | Extension handlers already guard: `BreakTimerActivity.stop` on `breakStartTime != nil && breakEndTime == nil` + profile match; `BreakTimerActivity.start` on session/profile match. `TimerActivityUtil` routes by activity-name prefix `"<TypeId>:<profileId>"`. | `BreakTimerActivity.swift`; `TimerActivityUtil.swift` |
| G12 | Session-end cleanup already removes all break/OMM/strategy activities (`onSessionCreation .ended`), and foreground hooks exist: `FoqosApp` `scenePhase == .active` block; `HomeView` → `loadActiveSession`. | `StrategyManager.swift:697–748`; `FoqosApp.swift:135–164` |
| G13 | `ProfileSnapshot.breakTimeInMinutes` exists; `SessionSnapshot` carries `breakStartTime`, `breakEndTime`, `oneMoreMinuteUsed`, `oneMoreMinuteStartTime` (no deadlines). Optional-field additions to these Codable snapshots are back-compat safe (D1 precedent; also: no live users). | `SharedData.swift:140–262` |
| G14 | The C1 chokepoint clamp is deliberately upper-bound only; the sub-15 lower bound is explicitly C2's remit (C1 MAINTAINER DECISION 3 = defer). | `DeviceActivityCenterUtil.swift:422–423`; C1 plan MD3 |
| G15 | `AppBlockerUtil.activateRestrictions(for:)`/`deactivateRestrictions()` are pure `ManagedSettingsStore` writes on the shared named store; they take a pre-fetched `ProfileSnapshot`, perform no `SharedData` reads, and acquire no lock. | `AppBlockerUtil.swift` (whole file) |
| G16 | Registration *presence* is introspectable via `center.activities` (names — shipped, used by debug tooling and `removeAll*` helpers). `schedule(for:)` exists in the SDK but is used nowhere in this repo; rev 4's re-arm rule (I5) needs only name-presence, so nothing load-bearing rests on `schedule(for:)`. | `DeviceActivityCenterUtil.swift:295–399` |
| G17 | M session-**start** paths ship THREE orderings *(inventory corrected round 3)*: (i) **apply-then-persist** — `ManualBlockingStrategy.swift:29–39` (`activateRestrictions` :30 before `createSession`→`createActiveSharedSession` :32–39/`BlockedProfileSessions.swift:138`), `startWithTag` :1040→:1042, `startRemoteSession` :1222→:1225 — lock-free (G15); (ii) **persist-then-apply** — D1's extension paths (`ScheduleTimerActivity.swift:117`→`:127`); (iii) **persist-then-apply-BY-CALLBACK** — the timer strategies (`ShortcutTimerBlockingStrategy.swift:33–40`, `NFCTimerBlockingStrategy.swift:47–54`, `QRTimerBlockingStrategy.swift:46–53`): `createSession` persists, no in-process restriction call at all; restrictions land only when the extension's `StrategyTimerActivity.start` fires on `intervalDidStart` (`StrategyTimerActivity.swift:36`) — a pre-existing #358-class delivery dependence for *initial* blocking, out of C2's scope but load-bearing for §7.5's per-process rules and the serial-executor inventory. Classes (ii)/(iii) self-converge toward ON against any deriver; only class (i) is anti-convergent in its gap, which is what D-C2-4's per-process rule neutralizes. | verified rounds 2–3 |

---

## 3. Decision record — mechanism choice

### D-C2-1: Deadline-authoritative lifting (CHOSEN)

**Every restriction-lift (break or OMM) persists an absolute wall-clock deadline to the app-group snapshot in the same atomic action that lifts restrictions. All grant transitions — open, early close, expiry close — are executed in-process by whichever process observes them first, as single critical-section state+restriction mutations. DeviceActivity is demoted from mechanism-of-record to a redundant, deadline-gated background executor, registered in the C1 wrap-anchor shape so that sub-15-minute deadlines are honorable.**

**Why this and not the alternatives:**

| Alternative | Verdict |
|---|---|
| **A. Status quo** (extension callback is the mechanism of record) | Rejected — this *is* #260: a child-safety enforcement step resting entirely on an undocumented, contested, field-flaky callback. The verdict's fix invariant mandates in-process execution. |
| **B. In-process only** (historical `Timer` + foreground resume, deviation #1 as-built) | Rejected — zero background enforcement; deviation #1's as-designed explicitly wants backgrounded expiry enforced. Kept as *one layer*, not the design. |
| **C. BGTaskScheduler / BGAppRefreshTask** | Rejected as an enforcement layer — iOS schedules these discretionarily (hours of slack, none when force-quit); it would be a second unreliable callback pretending to be a mechanism. |
| **D. Local notification at expiry** | Not enforcement — requires the user to act against their own interest mid-doomscroll. Not part of correctness. |
| **E. Raise every duration to ≥15 minutes and keep plain `now→end` windows** | Rejected — kills OMM (hard-coded 60s) entirely and forces the #214 picker question to "remove", while *still* leaving #260's callback-of-record defect for 15/30-minute breaks. |
| **F. ManagedSettings-native scheduling** | Does not exist — `ManagedSettingsStore` has no timer; DeviceActivity is the only OS scheduler that can wake code, which is why it stays as the backstop. |

**Correctness posture (the A1 rule):** no property in §4 depends on any DeviceActivity callback firing, firing once, firing on time, or not firing spuriously. Callbacks only *shrink the residual window* (§11) during which a backgrounded device stays unblocked past a deadline.

### D-C2-2: Backstop shape — reuse the shipped wrap-anchor, uniformly

The backstop registration for **both** breaks (all durations, including 15/30) and OMM is:

```
intervalEnd   = ceilToMinute(deadline)          // hh:mm of the next minute boundary ≥ deadline
intervalStart = intervalEnd + 1 minute (mod 24h) // wrap; window length 1439 min ≥ 15
repeats       = true
```

- **Why wrap, not a lengthened one-shot** (e.g. `repeats:false` with `intervalStart` in the past): the wrap shape is the *shipped, field-exercised* C1 seam (G2). A backdated one-shot start relies on a second undocumented DeviceActivity behavior (whether a non-repeating schedule whose start components already passed is honored today). The A1 standard forbids new cleverness where a shipped seam exists.
- **Why uniform across durations:** one interval builder, one handler contract, one test surface. Splitting ≥15-minute breaks onto the legacy `now→end` shape would preserve two code paths *and* keep the legacy shape's dependence on `intervalDidStart` for the lift, which D-C2-1 removes.
- **Why `ceilToMinute`:** DeviceActivity's honored resolution is the minute (second components are not reliably honored, per #207's history). Ceiling guarantees the callback can only be **late**, never early — an early backstop would push toward re-blocking during a still-valid grant, which is #205's failure class. Lateness is bounded (≤59s + delivery latency) and only ever *after* the deadline. (`ceilToMinute` of an exact boundary may round to the next minute; the mandatory property is "never early", not tie-break choice.)
- **Consequences accepted and neutralized:** `repeats: true` means the interval re-fires daily and `intervalDidStart` fires at registration and daily. Both are neutralized structurally: `start` handlers are no-ops (§7.3), closers are gate-guarded (I6), and orphaned registrations are swept by cleanup and reconciliation (§7.5). **No cleanup is load-bearing for blocking correctness** — a leaked registration's callbacks are no-ops forever.

### D-C2-3: Fail-closed at every point where the OS wake is at stake (rev 4)

- **At grant time** (user taps break/OMM): the backstop is registered **before** restrictions lift. If registration throws, the grant is aborted, no state is written, restrictions stay on, and the error is surfaced via `errorMessage` (fixing #207's and #214's silent-no-op UX in one stroke). The fresh-grant *replace* (stop-then-start on the grant's name, I5) is safe here precisely because it precedes the lift: a stop-success/start-failure aborts the grant while restrictions are still on — nothing was destroyed that a live grant depended on.
- **At re-arm** (M relaunch mid-grant, §7.5): re-arm is **register-only-if-absent** — it never stops a live registration, so "destroy-without-recreate" is structurally impossible after a grant is open (round-3 fix; rev 3's introspect-and-replace is withdrawn). If the backstop is absent (legacy upgrade, OS eviction) and registration **fails**, the grant has no OS wake left: M **closes the grant fail-closed** — re-block, CAS-close, `errorMessage` — rather than running an unbounded-residual grant. (Rev 3's heal-forward is withdrawn: it silently traded a child-safety bound for UX in exactly the case where the user's device is least likely to return to the app.)
- **At lock acquisition** (see D-C2-4): grant-*openers* abort (fail-closed, no lift) when the app-group lock cannot actually be acquired.

### D-C2-4: Derived, critical-section restriction application (rev 2 — from round-1 findings)

Rev 1 prescribed per-transition restriction calls with per-transition orderings, which round 1 broke four ways (ordering contradiction between 7.2 and 7.3; non-atomic gate-read→apply letting a stale executor re-block a fresh grant; crash windows between state write and restriction call with no converging arm; a lift that could land after a lost identity race). Rev 2 replaces all of that with one structural rule:

**Restriction state is a *derived function of persisted state*, applied atomically with the state change.** A single FoqosShared function — call it `applyRestrictionsForCurrentState()` (naming is the plan's) — computes and applies the desired `ManagedSettingsStore` state from the current app-group snapshot:

```
no active shared session                            → restrictions OFF  (MAIN APP ONLY — see per-process rule)
active session with an open grant (raw fields §5)   → restrictions OFF
active session, no open grant                       → restrictions ON, config precedence:
                                                        live profile snapshot → session-pinned config (§6.1a) → BAIL-AND-PRESERVE
```

The **session-pinned config** (rev 4) is a copy of the blocking configuration written onto the `SessionSnapshot` at grant-open (§6.1a) precisely so the re-block after a grant can never be held hostage by a missing profile snapshot: the round-3 confirmed trace — snapshot wiped mid-break (the `profileSnapshots` setter drops the whole key on encode failure, `SharedData.swift:312–318`), grant closes at deadline, every extension wake bails, restrictions stay off until a voluntary app open — is dead, because the closer's derive re-blocks from the pinned copy in either process. BAIL-AND-PRESERVE remains only for the no-grant-was-ever-opened corner (where current restrictions are whatever session start applied — preserved, not regressed).

and **every grant transition executes as ONE `withLock` critical section**: `{ gates → state mutation → derive-and-apply }`. Openers and closers in both processes use it; the reconciler ends with a derive-and-apply. Two rules added in rev 3 (round-2 confirmed findings):

- **Per-process derivation authority.** The `no session → OFF` arm executes **only in the main app**. The extension's derive-and-apply treats "no active shared session" as bail-and-preserve. Reason (G17 class (i)): the manual-family M start paths apply restrictions *before* persisting the shared session, outside any lock; an extension wake landing in that gap would read "no session", deactivate, and leave a whole just-started session running unblocked — with no crash and no dropped callback. The extension therefore never un-blocks on *absence* of state (D1's explicitly gated stop/takeover paths are unchanged and out of scope); it only converges *grant* states and session⇒ON. The main-app arm is safe against G17 class (i) because the plan MUST compile the **complete inventory of M code paths that persist a shared session** (the StrategyManager flows AND the timer-strategy closures reachable from `TimerDurationView` — G17's corrected inventory) and assert they share the M reconciler's serial executor (all main-actor today; the plan enforces via annotations). Classes (ii)/(iii) self-converge (any post-persist reader derives ON); note that class (ii) also executes **in M** via `PreActivationReminderScheduler.catchUpMissedScheduleStarts` (foreground catch-up runs `ScheduleTimerActivity.start` in-process) — include it in the serial-executor inventory. Note on class (iii): the session⇒ON arm means a reconciler wake can now apply a timer-strategy session's *initial* restrictions before its `intervalDidStart` arrives — a strictly beneficial side effect (it heals the pre-existing #358-class dependence of initial blocking on callback delivery), recorded here so the plan treats it as intended.
- **The missing-snapshot row is pinned** (per the table above): no guessing, bail-and-preserve at the end of the precedence chain, and the **main-app reconciler owns repair** — rebuild the snapshot from SwiftData (`BlockedProfiles.updateSnapshot`) when the profile exists, else end the orphaned session through the existing identity-gated teardown. The extension never repairs (no SwiftData access) — but with the session-pinned config it no longer needs to for any post-grant re-block.
- **Lock acquisition is not assumed** (rev 4, round-3 finding): `SharedData.withLock` as shipped proceeds *unlocked* with a log on three failure paths (nil lock path, `open()` failure, `flock()` failure — `SharedData.swift:79–96`). C2's critical-section runner must therefore **surface acquisition failure**, and grant-openers abort fail-closed on it (D-C2-3). Closers and derive-and-apply proceed best-effort under a degraded lock (refusing would trade an unbounded under-block for a race), re-validating their gates immediately before applying; the narrowed race is residual R8, and every "structurally impossible"/"serialized" claim in this contract is scoped to *acquired-lock* execution. **Extension-side acquisition is bounded, not blocking** (rev 6, round-5 finding): a *suspended* (frozen, not dead) main app can hold the flock indefinitely — `flock` releases on death, not on freeze — and a blocking `LOCK_EX` would wedge every extension wake behind it until the extension watchdog kills it. The extension's section runner therefore acquires with `LOCK_NB` + bounded retry; on timeout it treats the attempt as degraded-lock (closers best-effort per R8, no wedge). **Definition (rev 6): "active shared session" throughout this contract means present AND `endTime == nil`.** The ended-but-present state is reachable (`setEndTime` and `flushActiveSession` are separate sections in `endSession` — a kill between them leaves an ended snapshot under the key); derive-and-apply treats it as *no session* (so the M arm applies OFF and flushes the stale entry; a presence-based reading would re-assert ON forever for an ended session). **Guard parity** (rev 6): the in-section raw-read discipline (rule (ii)) gets the same CI/regression guard as AppBlockerUtil — an accidental public-accessor call inside a section is a silent lock-loss, not a deadlock, and would invisibly void the serialization claims.

Remaining consequences:

- **Serialization.** A closer's gate-check, terminal CAS, and restriction application cannot interleave with an opener's state write + lift: both hold the same lock. The stale-executor race is structurally impossible, and X14's identity-race abort is automatic (a failed gate means no state change means no restriction change — atomically).
- **Crash convergence.** A process dying inside the section (after the state write, before the store write completes) leaves persisted state ahead of restriction state; the *next* derive-and-apply by any process converges it. Every wake path ends in one (§7.5), so divergence is transient and bounded by "next wake", in either direction, never permanent.
- **Ordering disputes dissolve.** There is no CAS-vs-re-block order to argue about: the CAS and the apply are one atomic unit; the deregistration and UI work happen after the section (their loss is cosmetic, swept later).
- **Lock-hygiene and persistence constraints (binding on the plan):** (i) `AppBlockerUtil` stays lock-free (true today, G15) — the plan MUST add a regression guard (comment + test or CI grep) since a future `withLock` inside it would deadlock (G10 non-reentrancy); (ii) all inputs needed inside the section (the profile snapshot for ON) are read via raw suite reads *inside the same lock body*, never via the public `withLock`-wrapped accessors; (iii) **encode-then-commit** (rev 5, round-4 confirmed): the shipped `activeSharedSession` setter DELETES the key when `JSONEncoder` fails (`SharedData.swift:364–370`), so a C2 grant write could silently destroy the session it is granting against and then lift restrictions against "no session". C2 primitives therefore never use remove-on-failure writes: they encode the new `SessionSnapshot` to `Data` first; encode failure ⇒ the stored value is left untouched and the primitive **aborts fail-closed before any restriction change** (openers return false with `errorMessage`; closers return false and retry at the next wake, safe-late). Pinning §6.1a's config enlarges the encoded payload, which is exactly why this rule exists — and why the pin should be the minimal subset `AppBlockerUtil` consumes; (iv) DeviceActivity registration/deregistration stays OUTSIDE the section.
- **Scope.** D1's shipped paths (`StopScheduleTimerActivity.stop`, `ScheduleTimerActivity.start/.stop`) keep their existing explicit activate/deactivate calls — out of scope. Their persist-then-apply ordering is self-converging against racing derivers (any reader after the persist derives the same result). M's session-**start** paths are the opposite (apply-then-persist, G17) and are NOT rewritten by C2 — the per-process rule above is what makes them safe against the reconciler; a plan-level option to additionally flip them to persist-then-apply is welcome hardening but not required by this contract.

---

## 4. Invariants

Every implementation of this contract MUST satisfy all of these. They are the properties the adversarial rounds attack.

- **I1 — Deadline-with-lift.** Restrictions are never deactivated for a grant unless the corresponding absolute deadline is persisted in the app-group `SessionSnapshot` — atomically with the lift, inside the same critical section (D-C2-4).
- **I2 — Initiator executes.** Every open and close is executed in-process by an actor that observed its condition (main app for user taps and foreground expiry via its 1-second ticker; extension for background expiry; reconciler for healing). No transition's execution is delegated to a hoped-for future callback.
- **I3 — Exactly-once transition, any-number-of-executors.** Terminal writes are compare-and-set inside the critical section: `breakEndTime` set iff currently nil; `oneMoreMinuteStartTime` cleared iff currently non-nil; both identity-gated on `expectedSessionId`. Racing executors produce one logical transition.
- **I4 — No callback in the correctness argument.** All §9 interleavings must resolve safely assuming any subset of DeviceActivity callbacks is dropped, duplicated, delayed, or delivered synthetically (including a synthetic `intervalDidEnd` from `stopMonitoring` — the design is correct under **both** resolutions of that contested fact; §10).
- **I5 — Backstop freshness and preservation.** A grant's backstop registration encodes the *current* grant's deadline, established as follows. **C2 backstops use NEW, C2-owned activity-name prefixes** (e.g. `BreakDeadlineBackstop:<profileId>`, `OneMoreMinuteDeadlineBackstop:<profileId>` — naming is the plan's; rev 5): they can never be conflated with a legacy pre-C2 registration, whose `repeats:false` shape has no daily re-fire and whose adoption as "the backstop" would silently void R1's bound (round-4 confirmed). `TimerActivityUtil` routes the new prefixes to the same gated closers; legacy `BreakScheduleActivity:`/`OneMoreMinuteActivity:` callbacks keep routing to the (now no-op-start, gated-closer-stop) handlers as bonus healing wakes; session-end cleanup and the orphan sweep cover both prefix families. **Fresh grants replace** (stop-then-start on the C2 name) *before the lift*; a failure aborts the grant fail-closed (D-C2-3). **Re-arm registers only if the C2 name is absent** from `center.activities` (G16) and NEVER stops a live registration — so once a grant is open, no C2 code path can destroy its OS wake without replacing it. Mismatch cannot survive on a C2 name: a live registration there was necessarily created by this grant's own fresh-grant replace (whose failure would have aborted the grant). Re-arm registration failure ⇒ fail-closed grant close (D-C2-3). **All DeviceActivity registration mutations are main-app-only: the extension never calls `startMonitoring`/`stopMonitoring`** (its reconciler duties are state transitions and derive-and-apply only). Synthetic callbacks from the fresh-grant replacement are neutralized by I6 (no grant is open yet at that moment).
- **I6 — Universally gated closers.** *Every* closer — extension handler, main-app ticker, reconciler — passes, inside the critical section: (a) the session identity gate; (b) the grant-open gate on **raw fields** (§5); (c) `now >= deadline` from the snapshot. **Nil-deadline (legacy upgrade-window) grants are migrated, not interpreted:** the first evaluator to encounter an open grant with a nil deadline stamps `deadline := start + duration` — duration read *inside the same critical section* with pinned precedence (break: the live profile snapshot's `breakTimeInMinutes`, else — M only — the SwiftData profile's value; OMM: the 60s constant). **If no duration source is available in-section (extension + missing snapshot): do NOT stamp, do NOT close — the grant is explicitly NOT expired for this evaluation** (safe-late; M's next wake repairs the snapshot and stamps). Defaulting the duration (e.g. to 0) is explicitly forbidden — a zero-duration stamp would early-close a valid legacy grant. After the one-time stamp, I11's edit-immunity holds unconditionally; the residual (a profile edit landing between the app update and the very first evaluation shifts the migrated deadline once) is R7. **Legacy migration is an M duty and is COMPLETION-keyed, not nil-deadline-keyed** (rev 6): every M reconcile checks each open grant for the fully migrated shape — deadline stamped, re-block config pinned (§6.1a), C2 backstop registered (I5) — and completes whatever is missing (pin-source precedence: live profile snapshot, else rebuild from SwiftData; both unavailable ⇒ leave unpinned and retry next M wake, the grant staying M-bounded per R7). Keying migration on the nil deadline alone would let an earlier X-side stamp "de-legacy" the grant and permanently skip the pin and backstop (round-5 finding). Once complete, the grant is indistinguishable from a C2-opened one. Exceptions to (c): the user's explicit early break end (7.2) skips it by design; session-end grant closure (§6.4) skips it and performs no restriction change of its own; the **D-C2-3 fail-closed close on a lost backstop** (re-arm registration failure) skips it by design — M closes an unexpired grant early because its OS wake cannot be guaranteed (the §6.5 closers expose this explicit mode for both grant families).
- **I7 — Terminal-state-before-deregistration.** `stopMonitoring` on a grant's backstop is called only after the critical section that closed the grant has committed, so a synthetic `intervalDidEnd` observes a closed grant and no-ops.
- **I8 — Identity gates everywhere.** Every cross-process mutation of session-scoped state goes through identity-gated primitives (G9 pattern). No new un-gated mutator is introduced. Gated writes report failure to their caller; a failed gate aborts the whole transition (automatic under D-C2-4 — the state change and restriction change share the section).
- **I9 — One grant family at a time, enforced structurally in BOTH directions (under MD-C2-2 = A).** Opening a break closes any open OMM grant *in the same critical section* (one composite primitive, §6.2 — not two lock acquisitions), AND `openOneMoreMinuteGrant` refuses (returns false) when a break is open **on raw fields, inside its section** (§6.3) — the UI's `isOneMoreMinuteAvailable` is convenience, not enforcement (I11; its `enableBreaks`-derived conjunct can be falsified by a mid-break profile edit, G8). No observer can ever read both grants open. The OMM closer's break-active guard (7.3) remains as defense in depth regardless of MD-C2-2's outcome.
- **I10 — Single reconciler.** Exactly one "heal expired lifts" routine (§7.5), shared by app-side hooks and extension entry points. Session-end grant closure is a distinct, dedicated primitive (§6.4) — *not* the reconciler — so healing and teardown semantics cannot blur.
- **I11 — Raw-field enforcement predicates.** All enforcement logic (gates, state machine, derive-and-apply) reads raw session fields (`breakStartTime`, `breakEndTime`, `oneMoreMinuteStartTime`, deadlines). Profile-derived conveniences (`isBreakActive`'s `enableBreaks` conjunct, `isBreakAvailable`) gate only the *user-facing start affordance*. A mid-grant profile edit (local or remote) therefore cannot alter a running grant's lifecycle or make enforcement states unreachable.

---

## 5. State machine

Session-scoped restriction-grant state, derived from **raw** `SessionSnapshot` fields (I11; no new state enum is stored — the machine is a *reading* of the fields, which keeps every observer consistent):

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │ BLOCKING            (breakStartTime == nil || breakEndTime != nil)  │
  │ (restrictions ON)   && oneMoreMinuteStartTime == nil                │
  └─────────────────────────────────────────────────────────────────────┘
      │ tap OMM (once/session,                     ▲ OMM closes: now ≥ ommDeadline
      │  not during break)                         │  (ticker/extension/reconciler)
      ▼                                            │
  ┌─────────────────────────────────────────────────────────────────────┐
  │ OMM_OPEN            oneMoreMinuteStartTime != nil                   │
  │ (restrictions OFF)  oneMoreMinuteDeadline persisted (I1)            │
  └─────────────────────────────────────────────────────────────────────┘
      │ tap break — one composite section closes OMM & opens break (I9)
      ▼
  ┌─────────────────────────────────────────────────────────────────────┐
  │ BREAK_OPEN          breakStartTime != nil && breakEndTime == nil    │
  │ (restrictions OFF)  breakEndDeadline persisted (I1)                 │
  └─────────────────────────────────────────────────────────────────────┘
      │ early end (tap; 7.2)  │ natural end (now ≥ deadline; ticker /   │ session end (any
      │                       │  extension backstop / reconciler)       │  channel; grants
      ▼                       ▼                                         ▼  closed, §6.4)
  BLOCKING (breakEndTime != nil ⇒ break consumed this session)       SESSION_ENDED
```

BLOCKING → OMM_OPEN and {BLOCKING, OMM_OPEN} → BREAK_OPEN happen only in the main app (user taps; app is foreground by definition). Closing transitions can be executed by either process; I3/I6 make them exactly-once and safe.

`SESSION_ENDED` (any channel — manual, D1 schedule stop, takeover, remote) supersedes everything: the shared session is removed or replaced, so every subsequent grant callback fails the identity gate and no-ops. Grant fields on an ended session are historical data, normalized per §6.4/§7.5.

**Availability rules preserved (UI layer, I11):** one break per session (`breakEndTime != nil` ⇒ consumed); one OMM per session (`oneMoreMinuteUsed`); OMM unavailable during a break (existing `isOneMoreMinuteAvailable`); break button available during OMM (existing behavior, now with I9 semantics).

**Transient divergences** between restriction state and persisted state (in either direction) arise from a process dying inside a critical section (X22/X23), from M's pre-existing apply-then-persist session-start ordering meeting an extension wake (G17/X28 — the reason for D-C2-4's per-process rule), or from D1's out-of-scope lock-external restriction calls (X29). They are not part of the machine — derive-and-apply (D-C2-4, with its per-process authority rules) converges each at the next authorized wake, in the direction of persisted state. §9 X22–X24 and X28–X29 walk them; R6 states the bounds honestly.

---

## 6. App-group schema and primitive additions (FoqosShared)

Contract-level requirements; exact naming is the plan's choice but semantics are fixed:

1. **Schema:** `SessionSnapshot.breakEndDeadline: Date?` and `SessionSnapshot.oneMoreMinuteDeadline: Date?` — optional Codable additions (back-compat safe, G13), mirrored on `BlockedProfileSession` and round-tripped by `toSnapshot()`/`upsertSessionFromSnapshot`. *Explicit deadlines, not derivation from `profile.breakTimeInMinutes`,* so a mid-session profile edit, stale profile snapshot, or clock-derived recomputation can never move a running grant's deadline, and two processes can never disagree on it. Legacy nil-deadline open grants (a break running across the app update) are **stamped once** at first evaluation per I6(c)'s migration rule — never re-derived per-evaluation (rev 3; the rev-2 "late-biased fallback" was profile-edit-sensitive and is withdrawn).
1a. **Session-pinned re-block config** (rev 4): the `SessionSnapshot` gains an optional pinned copy of the session profile's blocking configuration (the `ProfileSnapshot`, or the subset `AppBlockerUtil` consumes — plan's choice), written inside the grant-open section from the live profile snapshot. **If the live snapshot is absent at open time, the grant is refused** (fail-closed: a grant whose re-block config cannot be guaranteed must not lift restrictions; M's reconciler repair + user retry is the recovery). The pinned copy is retained until session end (not cleared at grant close, so post-close wakes can keep re-asserting ON from it) and sits second in the derive precedence (D-C2-4).
2. **`openBreakGrant(startDate:deadline:expectedSessionId:) -> Bool`** — ONE critical section: identity gate (report failure); **raw-field own-family refusal** (refuse if a break is already open or already consumed — I11; the UI's `isBreakAvailable` is convenience, not enforcement; symmetric with §6.3's break-open refusal, rev 6); **pin the re-block config (§6.1a; absent ⇒ refuse)**; write `breakStartTime` + `breakEndDeadline`; **absorb any open OMM grant** (clear `oneMoreMinuteStartTime`/`oneMoreMinuteDeadline`, keep `oneMoreMinuteUsed == true`) per I9/MD-C2-2=A; derive-and-apply (→ OFF). Aborts fail-closed if the lock cannot be acquired (D-C2-3/D-C2-4). Returns whether the grant opened.
3. **`openOneMoreMinuteGrant(startDate:deadline:expectedSessionId:) -> Bool`** — same shape: identity gate; **raw-field break-open gate** (refuse, returning false, if `breakStartTime != nil && breakEndTime == nil` — I9's second direction; the caller surfaces the same abort UX as an identity failure); **pin the re-block config (§6.1a; absent ⇒ refuse)**; write `oneMoreMinuteStartTime` + deadline + `oneMoreMinuteUsed = true`; derive-and-apply (→ OFF). Aborts fail-closed on lock-acquisition failure.
4. **`closeGrantsForSessionEnd(expectedSessionId:)`** — identity-gated CAS that closes any open grant *for bookkeeping only* (set `breakEndTime = now` iff nil-and-started; clear OMM fields), performing **no restriction change** (session teardown owns restrictions). Invoked from the session-end funnel: `BlockedProfileSession.endSession(now:)` before its SharedData end-time write. For sessions ended *by the extension* (D1 channels — which do not call this), the same normalization happens **on ingest**: consumers of completed snapshots (`syncScheduleSessions`/`upsertSessionFromSnapshot` for ended sessions) close open grant fields at `min(endTime, deadline)` — and the M-side ingest also cancels any still-pending break/OMM notifications for the ended session (hardening: a D1 schedule stop mid-break must not leave a dangling "Break almost over!" reminder). Neither path is load-bearing for blocking (identity gates already neutralize post-end callbacks); this is bookkeeping/analytics/notification correctness.
5. **`closeBreakGrantIfExpiredOrExplicit(...) -> Bool` / `closeOneMoreMinuteGrantIfExpired(...) -> Bool`** — the shared closer bodies (used by extension handlers, the main-app ticker, and the reconciler): ONE critical section applying I6's gates (with the early-end variant skipping the deadline gate, and the OMM closer's break-active branch closing without changing the desired state — see 7.3), the terminal CAS, and derive-and-apply. Return whether they closed.
6. **`applyRestrictionsForCurrentState()`** — D-C2-4's derive-and-apply; also invocable standalone under its own section (reconciler's final step). Reads raw suite state + the session profile's snapshot inside the lock body (never via public `withLock` accessors — G10); calls the lock-free `AppBlockerUtil` (G15, with the mandated regression guard). Implements the full four-row derivation table **including the pinned missing-snapshot row (bail-and-preserve) and the per-process no-session rule** (D-C2-4); takes/derives a caller-process capability so the extension physically cannot invoke the M-only arms.
7. **Interval builder** beside `stopScheduleInterval`: `wrapAnchorInterval(endingAt deadline: Date, now: Date) -> (intervalStart, intervalEnd)` implementing D-C2-2 (pure, unit-testable). **Registration helpers** (main-app-only, I5): fresh-grant *replace* (pre-lift) and re-arm *register-if-absent* (name presence via `center.activities`, G16).

---

## 7. Component contracts

### 7.1 `StrategyManager.startBreak` (fixes #214's silent no-op)

1. Guards: active session, `isBreakAvailable` (UI-layer, unchanged).
2. `deadline = now + profile.breakTimeInMinutes * 60`.
3. **Replace-register** the backstop (wrap-anchor; I5). Throws ⇒ abort: no state written, no lift, `errorMessage` set (D-C2-3). A failed 5-minute break now *visibly* fails; the reminder in step 5 is never scheduled (#214's misleading-notification symptom gone). A synthetic end from the replacement no-ops (no open grant yet, I6b).
4. `openBreakGrant(...)` (§6.2 — one section: identity gate, grant write, OMM absorption, lift). Returns false ⇒ abort, reload, surface the #237-style "session changed" message (X14). Mirror the fields to the SwiftData model + save; remove the OMM backstop registration if one existed (outside the section, I5/I7 ordering irrelevant here since the OMM grant is already closed).
5. Reminder scheduling, widget reload, Live Activity update (existing calls, now truthful).

### 7.2 `StrategyManager.stopBreak` (the #260 fix — early end)

1. Guard: break-open on **raw fields** (I11 — not `isBreakAvailable`, the current wrong guard at :793). The `toggleBreak` ROUTING must likewise branch on the raw-field break-open predicate, not `isBreakActive`'s `enableBreaks`-conjuncted version — otherwise a mid-break `enableBreaks`-off edit would strand the user unable to end their own break early (the deadline closers would still end it, but the tap would silently misroute). The same I11 principle extends to the **tap target itself**: the plan must keep the stop-break affordance visible while a break is open on raw fields (today the button hides with `isBreakAvailable` — a raw-field-open break must still render its "Hold to Stop Break" control).
2. `closeBreakGrantIfExpiredOrExplicit(explicit: true, ...)` (§6.5 — one section: identity gate, open gate, CAS `breakEndTime = now`, derive-and-apply → ON). Returns false (identity/open gate lost — e.g. a takeover or another executor won) ⇒ same abort UX as 7.1 step 4: reload + #237-style message. Otherwise mirror to model, save.
3. **Then** deregister the backstop (I7 — a synthetic `intervalDidEnd` now observes a closed grant and no-ops), cancel break notifications, widget/Live Activity updates.

Two taps in any rhythm produce grant-open → grant-closed with restrictions on, entirely in-process. The #260 failure state (`isBreakActive` stuck true, restrictions off, backstop deleted) is unreachable.

### 7.3 Extension handlers (`FoqosShared/Timers`)

- **`BreakTimerActivity.start` → no-op** (log only). The lift is in-process (7.1). *Required*, not optional: under the wrap shape `intervalDidStart` fires at registration and daily; a lifting `start` would be a daily unblock bug. (Also removes break-start's exposure to upstream-#358 flakiness entirely.)
- **`BreakTimerActivity.stop`** → `closeBreakGrantIfExpiredOrExplicit(explicit: false, ...)`: I6 gates (identity; raw-field open gate; `now >= breakEndDeadline` — nil deadline ⇒ the I6(c) one-time stamp-then-gate migration, with the duration read in-section, never from the handler's routing-time profile parameter), CAS, derive-and-apply — one section. Before/duplicate/stale/synthetic callbacks no-op at the gates; the daily re-fire no-ops once closed.
- **`OneMoreMinuteTimerActivity.start` → no-op** (already is; stays).
- **`OneMoreMinuteTimerActivity.stop`** → `closeOneMoreMinuteGrantIfExpired(...)`: identity gate; OMM-open gate; **break-active branch** (raw fields): if a break is open, close the OMM fields *without* altering desired restrictions (derive-and-apply keeps OFF because the break grant is open) — #205's defense in depth under any MD-C2-2 outcome; deadline gate (nil ⇒ stamp `start + 60s` per I6(c)); CAS; derive-and-apply.
- **`DeviceActivityMonitorExtension.intervalDidStart/intervalDidEnd`** additionally invoke the reconciler (§7.5) after routing, so *every* extension wake heals any expired grant of any type — each DeviceActivity event app-wide becomes a healing opportunity (this bounds R1 by "next wake of any kind", not "next wake of the right activity").

### 7.4 `StrategyManager.startOneMoreMinute` (fixes #207)

1. Guards (unchanged): active session, `isOneMoreMinuteAvailable`.
2. `deadline = now + 60`.
3. Replace-register backstop (wrap-anchor at `ceilToMinute(deadline)`; I5). Throws ⇒ abort + surface `errorMessage` (the #207 verdict's missing-feedback point).
4. `openOneMoreMinuteGrant(...)` (§6.3). False (identity failure OR the raw-field break-open refusal, I9) ⇒ abort as in 7.1 step 4, deregister the just-registered backstop. Mirror to model, save.
5. UI updates (existing).

### 7.4b Foreground expiry executor (rev 2 — was unassigned)

The existing 1-second `timerTask` loop (`startTimer`, `StrategyManager.swift:196–218`) is the **assigned foreground executor for BOTH grant types**: each tick, if an open grant's `now >= deadline` (raw fields + snapshot deadlines), invoke the corresponding shared closer (§6.5), then — **only if the closer returned true** — deregister its backstop (rev 6: on a false return the grant may still be open, and destroying its only OS wake would contradict I5/X38's abort-and-retry story; a false return means retry next tick), mirror to the model, refresh UI. **All user-facing countdown surfaces (this ticker's display, the widget, the Live Activity) count down to the persisted deadline, not to a live-profile-derived duration** (rev 6) — otherwise a mid-break duration edit makes the screen contradict enforcement (a perceived early re-block or overrun). This restores G7's exact-60s foreground OMM and gives breaks the same exactness while foreground. The ticker already runs whenever a session is active (`loadActiveSession`/`activateSession` start it).

### 7.5 The reconciler — `healExpiredLifts` (one routine, I10)

Callable from both processes (FoqosShared, `BackgroundStopPolicy` pattern: pure decision core + thin appliers), with **per-process duties** (rev 4 — the extension performs state transitions and derivation ONLY; all DeviceActivity registration mutations and repairs are main-app-only, I5). For the current active shared session (if any), in order:

1. **Legacy-grant migration** (I6(c)): stamp explicit deadlines on any legacy open grant (one-time, in-section, with I6(c)'s duration-source precedence; unstampable in X ⇒ explicitly not-expired this evaluation). **In M, migration is complete:** stamp + pin the re-block config (§6.1a) + register the C2 backstop (I5), making the grant indistinguishable from a C2-opened one.
2. **Expired open grants** (raw fields; `now >=` deadline): invoke the shared closers (§6.5) — OMM first (its break-active branch handles the absorbed case), then break.
3. **Backstop re-arm (M only):** for an open, unexpired grant, register the backstop iff its name is absent from `center.activities` (I5 — never stop a live registration). Registration failure ⇒ fail-closed grant close (D-C2-3).
4. **Missing-snapshot repair (M only):** session live but its profile snapshot absent ⇒ rebuild from SwiftData (`BlockedProfiles.updateSnapshot`) if the profile exists, else end the orphaned session via the existing identity-gated teardown (D-C2-4 pinned row).
5. **Orphan sweep (M only):** stop grant activities registered for any profile other than the active session's (or any grant activity when no session). Hygiene; never load-bearing (D-C2-2).
6. **`applyRestrictionsForCurrentState()`** — converges divergences (D-C2-4) in the direction of persisted state, **under the per-process authority rules**: the extension's invocation converges grant states and session⇒ON (live snapshot, else session-pinned config) but never applies OFF for "no session" and bails-and-preserves at the end of the precedence chain; the main-app invocation implements all rows.

Invocation points: (a) `loadActiveSession` (launch + every foreground pass); (b) the `FoqosApp` `scenePhase == .active` block; (c) extension callback entry (7.3, steps 1–2 and 6 only). The M-side reconciler MUST execute on the same serial executor as **every M code path that persists a shared session**. The plan compiles that inventory **by grepping every call site of `createSession`/`createActiveSharedSession`/`createSessionForScheduler`/`startSchedulerSessionTakingOver` reachable from the main app — NOT by trusting any enumeration in this contract** (rev 6: G17's "corrected" list was itself shown incomplete in round 5 — the legacy NFC/QR strategies are additional class-(i) sites) — and asserts main-actor execution across all of them. The main-app applier also mirrors closes into SwiftData and refreshes UI surfaces. **Session end is NOT a reconciler invocation** — teardown uses §6.4 (`closeGrantsForSessionEnd`) inside the existing end funnel, and the `.ended` cleanup (G12) already removes grant activities, so nothing re-arms a backstop during teardown.

### 7.6 Composition with D1 (no changes to D1 code)

- Schedule stop / takeover mid-grant: D1's handlers operate via identity-gated primitives (G9). When they end/replace the session, every outstanding grant callback fails the identity gate (I8) and no-ops; orphaned registrations are swept (§7.5.5); ingest normalization (§6.4) keeps history truthful. A takeover's `activateRestrictions(for: newProfile)` correctly supersedes the old grant's lifted state — restrictions follow the *session*; grants are strictly session-scoped. D1's explicit restriction calls are consistent with derive-and-apply's function (D-C2-4 scope note).
- `BackgroundStopPolicy` is not consulted by grant logic: breaks/OMM are not session *stops*; they are session-scoped restriction grants initiated by the foreground user. No new policy channel.
- The D1 takeover racing a grant-open/close is serialized by the shared lock (both mutate under `withLock`); whichever commits second sees the other's state (X13/X14).

---

## 8. MAINTAINER DECISIONS (open — product calls, not design calls)

### MD-C2-1 — Do the 5- and 10-minute break options survive?

The wrap-anchor mechanism makes them honorable: `intervalDidEnd` at a deadline 5 minutes out is legal (G2), foreground expiry is exact (7.4b), background expiry is late by ≤59s + delivery latency.

- **Option A (recommended): keep 5/10/15/30.** The mechanism now honors them; removing them was only ever a workaround for G4. No copy changes needed (the "Break almost over" reminder already guards `breakTimeInMinutes >= 2`).
- **Option B: raise the floor to 15.** Smaller test surface; hides the ±1-minute background precision; but it degrades a shipped affordance to dodge a mechanism this contract must build anyway for OMM's 60 seconds.

### MD-C2-2 — Semantics of OMM expiry during a break (#205)

- **Option A (recommended): starting a break absorbs the open OMM grant** (one atomic composite, §6.2/I9; `oneMoreMinuteUsed` stays true — the user has spent their OMM either way, and its remaining seconds are exchanged for the break's longer unblocked window; note honestly that a user who then *early-ends* the break forfeits whatever OMM remainder was absorbed — the exchange is one-way, which the recommended UX accepts as the natural meaning of "starting a break"). There is then no OMM-expiry event to mishandle; no overlapping-grant state exists.
- **Option B: grants run concurrently; OMM expiry defers to the break.** Behaviorally identical for the user; structurally keeps a dead 60-second timer alive during a 5–30-minute break purely to be ignored. More states, no benefit.
- **Option C: OMM expiry re-blocks mid-break** (current as-coded behavior treated as intended). Rejected: it is the defect (#205).

Whichever option is chosen, the break-active branch in the OMM closer (7.3) ships as defense in depth — under A it also covers the removal-raced-with-callback interleaving (§9 X7).

### MD-C2-3 — Accept bounded background overrun for OMM?

Deviation #1's as-designed says OMM enforces "exactly 60 seconds … regardless of app state". On iOS this is not strictly achievable: no third process exists, DeviceActivity's honored resolution is the minute, and delivery latency is nonzero.

- **Option A (recommended): accept the bounded overrun.** Foreground: exact 60s (7.4b). Background: 60s + ceil-to-minute (≤59s) + delivery latency, healed at the next wake of any kind. The closest any iOS app can get; stated honestly as R2.
- **Option B: floor-to-minute (re-block early in background).** Guarantees ≤60s but can cut a granted OMM to near zero and violates the never-early gate (I6c) — it would need a tolerance carve-out reintroducing #205-class early re-blocks. Not recommended.
- **Option C: revert to foreground-only enforcement** (historical as-built). Rejected — contradicts the recorded as-designed intent (deviation #1).

---

## 9. Interleaving analysis

Notation: **M** = main app, **X** = monitor extension, **†** = process killed, **⚡** = callback (droppable/duplicable/late/synthetic per I4). Safe terminal state: *restrictions match persisted grant state, or the divergence is a crash-window transient that the next wake's derive-and-apply (D-C2-4) converges.* "Safe-late" = restrictions off past deadline, healed at next wake (bounded residual R1/R2, never permanent).

| # | Interleaving | Resolution |
|---|---|---|
| X1 | **Two-tap #260 repro:** M start break; M stop break immediately | 7.1 then 7.2 — fully in-process, each one critical section. Grant closed, restrictions on, backstop removed after (I7). No callback involved. |
| X2 | Stop break; synthetic ⚡`intervalDidEnd` from 7.2 step 3's `stopMonitoring` | Grant was CAS-closed in step 2's committed section (I7) ⇒ open-gate fails ⇒ no-op. Correct under both resolutions of the contested fact (§10). |
| X3 | Natural expiry, app foreground | 7.4b ticker executes the shared closer in-process. A later ⚡ no-ops at the CAS/open gate (I3). |
| X4 | Natural expiry, app backgrounded, ⚡ delivered | X closer: gates pass ⇒ CAS + derive-and-apply (→ ON) in one section. M reconciles UI/SwiftData at next foreground (§7.5a/b). |
| X5 | Natural expiry, backgrounded, ⚡ **never** delivered | Safe-late: healed at next wake of any kind — foreground (§7.5a/b), any extension callback (§7.5c), or the wrap window's daily re-fire. R1; ≤24h while the wrap registration survives (bound conditional per R1; legacy grants gain it at first M-wake migration). |
| X6 | ⚡ delivered twice, or very late (after early end / session end) | Open gate, CAS (I3), or identity gate (I8) ⇒ no-op. |
| X7 | Expired-OMM ⚡ in flight while M starts a break | Both bodies are critical sections on one lock ⇒ serialized. X first: legitimate expiry close (re-block), then M's `openBreakGrant` lifts — a ≤seconds flicker, correct both times. M first: OMM absorbed (I9); X's closer then hits its break-active branch ⇒ closes nothing (already closed), derive-and-apply keeps OFF. No mid-break re-block in any ordering (contrast rev 1, where gate-read→apply was not atomic). |
| X8 | Break at 12:00:30, N=5 ⇒ deadline 12:05:30 ⇒ backstop end 12:06 | ⚡ ~12:06: `now ≥ deadline` ✓ ⇒ close. Never early (D-C2-2). Foreground expiry exact at 12:05:30 if M alive (7.4b). |
| X9 | App † mid-break; relaunch before deadline | `loadActiveSession` → §7.5: grant open, unexpired ⇒ re-arm registers iff the backstop name is absent (I5 — no stop of a live registration, no synthetic-⚡ risk); step 6 re-asserts OFF; ticker resumes. |
| X10 | App † mid-break; relaunch **after** deadline; ⚡ was dropped | §7.5.2 closes + §7.5.6 applies ON; SwiftData mirrored. (#260 verdict §5's foreground-reconciliation recommendation.) |
| X11 | App † mid-break; never relaunched; ⚡ dropped | Wrap window re-fires next day (D-C2-2) ⇒ X4 a day late; or any other activity's callback triggers §7.5c sooner. Bounded per R1. |
| X12 | D1 schedule stop lands mid-break | Identity-gated session end (G9); restrictions already off, D1's `deactivateRestrictions` idempotent. Later break ⚡ fails identity ⇒ no-op. Orphan swept (§7.5.5); history normalized on ingest (§6.4). |
| X13 | D1 scheduled takeover mid-break (victim not protected) | Atomic swap under the lock; `activateRestrictions(for: newProfile)` supersedes. Old-grant ⚡ fails identity ⇒ no-op. |
| X14 | Takeover racing `openBreakGrant`/`openOneMoreMinuteGrant` | Serialized by the lock. Swap first ⇒ the open's identity gate fails ⇒ returns false ⇒ **no state and no lift, atomically** (D-C2-4) ⇒ M aborts + reloads with the #237-style message. Open first ⇒ takeover sees the grant-open session as the victim and proceeds per D1 policy; grant dies with the session (X13). |
| X15 | Backstop registration throws at grant time (e.g. `excessiveActivities`) | 7.1/7.4 step 3 aborts before any state/lift; error surfaced; restrictions never lifted (fail-closed, D-C2-3). |
| X16 | Backstop absent at re-arm (legacy/OS eviction) and registration fails | Fail-closed grant close (D-C2-3 rev 4): re-block + CAS-close + `errorMessage`. No unbounded-residual grant can exist. (Rev-3 heal-forward withdrawn — round-3 confirmed it broke R1's bound.) Rev-6 semantics pin: this close runs in M, so it also cancels the pending break/OMM notifications; it consumes the one-per-session grant (inherent in the CAS — `errorMessage` explains why), an accepted UX cost of a rare failure. |
| X17 | Session ends (manual M path) mid-grant | `endSession` invokes `closeGrantsForSessionEnd` (§6.4, bookkeeping-only) before the end-time write; `.ended` cleanup removes grant activities (G12); teardown owns restrictions. Late ⚡ fails identity. Extension-ended sessions get the same bookkeeping on ingest (§6.4). |
| X18 | Clock jumps backward mid-grant | Deadlines are absolute: `now ≥ deadline` becomes false ⇒ closers wait; grant runs long by the delta (safe-late class). Forward jump ⇒ immediate expiry — safe direction (re-block). No unsigned math. |
| X19 | Break 23:58, N=5 ⇒ deadline 00:03(+1d) ⇒ end 00:03, anchor 00:04 | Pure modulo-1440 wrap, same as shipped `stopScheduleInterval` (which handles sub-00:15 stops in production). Unit scenario T-C2-U2. |
| X20 | Same profile: session ends, new session + new break, then a stale ⚡ from the old registration | Handler reads the **current** snapshot: identity/profile pass, grant open — but I6(c) compares `now` to the *current grant's* deadline ⇒ unexpired ⇒ no-op. (This is why the gate reads current state, not callback timing.) Expired current grant + stale ⚡ = a correct close, whoever the messenger. |
| X21 | `upsertSessionFromSnapshot` overwrites model fields mid-transition | Snapshot writes are lock-serialized, CAS-terminal (I3); the model mirror copies the settled snapshot (G13 + the two deadline fields). No third source of truth. |
| X22 | M † inside `openBreakGrant` between the UserDefaults commit and the store write | Persisted: open grant; actual: restrictions ON. Transient outside the machine (§5). Next wake (user relaunches — they were mid-tap) ⇒ §7.5.6 derive-and-apply ⇒ OFF; break resumes from its persisted deadline; only the dead time is lost (grant is NOT silently burned). Never permanent. |
| X23 | Executor † inside a closer between the CAS and the store write | Persisted: closed grant; actual: restrictions OFF. The rev-1 "permanent #260 via crash window" — now converges at the next wake's derive-and-apply (§7.5.6 runs on every launch/foreground/extension event) ⇒ ON. Bounded by next-wake, same class as R1, and strictly rarer (requires a mid-section death, not a dropped callback). |
| X24 | M † between 7.1 step 3 (backstop replaced) and step 4 (grant open) | No state, restrictions still ON, one leaked registration whose callbacks no-op forever (I6b) and which is swept (§7.5.5) or replaced by the next grant (I5 replace-register). |
| X25 | Leaked registration from a previous grant adopted by a new grant *(rev-1 defect)* | Impossible now: fresh grants replace-register (I5), so the backstop always encodes the current deadline; at re-arm, a live registration under the grant's name is necessarily this grant's own or a deadline-compatible legacy one (I5's mismatch-cannot-survive argument). |
| X26 | Remote/local profile edit mid-grant (`enableBreaks` off, `breakTimeInMinutes` changed) | Enforcement reads raw fields + stored deadlines (I11, §6.1): the running grant's lifecycle is untouched (legacy nil-deadline grants: untouched after the one-time stamp — X31/R7); only *future* availability changes. UI derived-property quirks are contained: the OMM primitive refuses structurally (X32), and the early-end tap routes on raw fields (7.2), so no quirk carries enforcement weight. |
| X27 | Two M entry points race (ticker expiry vs user's early-end tap) | Same-process serialization plus the shared closer's CAS (I3): one closes, the other no-ops at its gates. |
| X28 | M starts a session (apply-then-persist, G17); an extension wake lands in the apply→persist gap *(round-2 confirmed)* | Rev-2's unconditional "no session ⇒ OFF" would have deactivated a just-started session for up to a whole session length. Rev 3: the extension **has no OFF-on-no-session arm** (D-C2-4 per-process rule) ⇒ it bails; M's persist completes; safe. The M-side reconciler cannot occupy the gap because it shares M's serial executor (§7.5). |
| X29 | D1 takeover: X persists the successor session (`:117`) and applies ON (`:127`) outside the lock; M opens a grant on the successor between the two | The window is the two adjacent statements in X (sub-millisecond) and M can only open a grant on a session it has already *observed* (a `loadActiveSession` pass) — not humanly reachable inside the window. If it ever happened: state = open grant + ON, a §5 transient converged at the next reconcile (D1's code is out of scope; noted, not re-engineered). |
| X30 | Live session, profile snapshot missing (encode-failure key wipe `SharedData.swift:312–318`, or remote delete racing an un-ingested scheduler session) | For **C2-opened or M-migrated grants**: derive re-blocks from the **session-pinned config** (§6.1a) in either process — the round-3 "every X wake bails forever" trace is dead for this population. The never-granted corner reaches bail-and-preserve (current restrictions preserved, not regressed). The un-migrated legacy corner (no pin exists yet) is R7(ii): converges at the next app open, honestly scoped. The **M reconciler repairs** in all cases (§7.5.4). |
| X31 | Legacy nil-deadline break (opened pre-update) + mid-grant `breakTimeInMinutes` shrink (local or remote) | Rev-2's per-evaluation fallback would have early re-blocked. Rev 3: first evaluator **stamps** the deadline once (in-section duration read, I6(c)); later edits cannot move it (I11 restored). Residual: an edit landing before the very first evaluation shifts the one-time stamp — R7. |
| X32 | Mid-break `enableBreaks`-off edit, then user taps OMM (UI predicate wrongly lights up) *(round-2 confirmed I9 breach)* | `openOneMoreMinuteGrant`'s raw-field break-open refusal (§6.3) returns false inside the section ⇒ no state, no lift, backstop deregistered, abort UX (7.4 step 4). Both-open is unreachable regardless of UI predicates. The same edit also must not strand the user's early-end tap — 7.2's raw-field toggle-routing AND visible-affordance requirements. |
| X33 | Timer-strategy session start (G17 class (iii)): persist, then restrictions arrive only via `StrategyTimerActivity.start` on `intervalDidStart` | Pre-existing #358-class exposure for *initial* blocking, out of C2's scope — but C2's session⇒ON derive arm now *heals* it at any reconciler wake (D-C2-4 class-(iii) note): a missed `intervalDidStart` no longer leaves the session unblocked past the next wake. No C2 path regresses it (extension bail preserves; ON needs live-or-pinned config — pinned absent pre-grant, live snapshot present in the normal case). |
| X34 | Re-arm destroys the backstop then fails to re-create (round-3 confirmed against rev 3) | Impossible in rev 4: re-arm never stops a live registration (I5 register-if-absent); the only stop-then-start is the fresh-grant replace, which precedes the lift and aborts fail-closed (D-C2-3). X-side: the extension performs no registration mutations at all (I5), so a mid-operation extension kill cannot orphan a grant. |
| X35 | Degraded lock (`withLock` proceed-unlocked fallbacks, `SharedData.swift:79–96`): stale unlocked closer races a fresh grant | Openers abort fail-closed on acquisition failure (D-C2-3/D-C2-4), so a grant can never *open* into a degraded-lock race. A degraded closer re-validates gates immediately before applying; the surviving sliver (unlocked closer preempted between re-validation and apply while a locked opener commits) is R8 — a transient converging at the next wake, and requiring two independent rare conditions. |
| X36 | Grant-open attempted while the profile snapshot is missing | Refused fail-closed inside the section (§6.1a): no pin ⇒ no lift. M reconciler repairs the snapshot; user retries. Prevents ever opening a grant whose re-block config is unavailable. |
| X37 | Legacy `repeats:false` registration under the pre-C2 name adopted as "the backstop" (round-4 confirmed against rev 4) | Impossible in rev 5: C2 backstops live under **new C2-owned names** (I5), so re-arm's register-if-absent installs the wrap backstop regardless of legacy registrations; the legacy one-shot remains a bonus healing wake routed to the gated closers. First M wake also fully migrates the grant (I6(c)). R1's daily-re-fire bound holds for every migrated/C2-opened grant. |
| X38 | Encode failure inside a grant-open write (the shipped setter would delete the session key — round-4 confirmed) | Encode-then-commit (D-C2-4 (iii)): the primitive encodes first; on failure it leaves the stored value untouched and aborts fail-closed **before** any restriction change — no lift against a destroyed session, I1 preserved. Closers likewise abort-and-retry (safe-late). |

**Round-exit criterion:** a full adversarial round (fresh attackers, all lenses) produces zero interleavings ending in an unsafe terminal state — restrictions off with no persisted open grant *and no wake that converges it*; a permanently stuck open grant; a re-block during a valid grant that no wake converges; or a violated invariant.

---

## 10. The contested fact and the device probe

**Does `DeviceActivityCenter.stopMonitoring` deliver a (synthetic) `intervalDidEnd`?** Undocumented; community evidence split (#260 verdict §2).

**This design is correct under both resolutions** (I4; X2, X24, X25): if synthetic ends fire, I7's commit-before-deregister ordering plus the I6 gates make them no-ops; if they never fire, nothing here relies on them. **No branch of this contract requires the probe to be run first.**

The ~5-minute probe from the #260 verdict §5 remains **recommended, non-blocking** maintainer follow-up — not for C2, but because it determines whether the *pre-existing* stop-schedule re-registration sites (`StrategyManager.swift:107` on every launch, `activateSession` :666, and the verdict's audit list) are a second live bug (a synthetic end there flows into D1's policy-gated `StopScheduleTimerActivity.stop`, which would legitimately end a schedule-stoppable session early — D1's gate filters *who may stop*, not *whether stop-time was reached*). Out of C2's scope (§1); the probe result decides whether it becomes its own issue.

**Probe (verbatim intent from the verdict):** active session with breaks → start break → end early → watch os_log for `intervalDidEnd for activity: BreakScheduleActivity:` (`DeviceActivityMonitorExtension.swift:40`) and observe shields. Repeat for the stop-schedule re-registration (open the app mid-session on a stop-scheduled profile).

**Probe #2 — wrap-anchor short-lead delivery (REQUIRED before implementation; ~10 minutes on device; rev 6).** The backstop rides on `intervalDidEnd` being delivered for a wrap window that is *already in progress* at registration, with the end only 1–5 minutes away. The C1 stop-schedule seam exercises the same wrap shape, but no code path in this repo has been *device-observed* delivering a short-lead mid-window end, and the repo's own foreground catch-up machinery exists because DeviceActivity has skipped in-progress events before — so "field-exercised" (G2/D-C2-2) covers the shape's *legality*, not this *delivery property*. Probe: register a wrap-anchor activity ending 2–3 minutes out (debug hook), background the app, watch os_log for the extension's `intervalDidEnd`. **If delivery fails**, the layered design still functions (in-process transitions, foreground exactness, reconciler healing at every other wake) but the *background* bound claims (R1's ≤24h via daily re-fire aside, the prompt background close) weaken to next-wake-of-any-kind — which changes the MD-C2-1 recommendation (5/10-minute breaks would be honorable only foreground-promptly) and must be fed back into this contract before the plan is written.

---

## 11. Honest residuals

- **R1 — Dead-app, dropped-callback window.** If the app is killed at (or before) a grant deadline *and* the backstop callback is never delivered, restrictions stay lifted until the next wake of any kind: app open, any extension callback for any activity (§7.5c), or the wrap window's daily re-fire (≤24h). **The ≤24h bound is conditional on the wrap registration itself surviving:** if the OS evicts the registration while the app is dead, no process exists to re-create it, and the residual extends to the next app open — unrepairable by any design (stated per round 4; the same applies to every Screen Time app). Legacy pre-C2 grants gain the bound at their first M-wake migration (I6(c)); before it, they are M-open-bounded (R7). **No iOS mechanism can close this class to zero** — during a grant the apps are unshielded (no shield extension runs), ManagedSettings has no scheduler, BGTask timing is discretionary. The design bounds what is boundable and heals at first opportunity (I10).
- **R2 — OMM background precision.** Backgrounded OMM overruns by up to ~59s (ceil-to-minute) plus DeviceActivity delivery latency (empirically up to minutes). Foreground OMM is exact. Accepted under MD-C2-3 = A.
- **R3 — UI staleness after extension-executed closes.** The extension cannot update the Live Activity (needs the app process or push); a background-closed grant shows stale Live Activity/in-app state until the next foreground reconcile. Pre-existing (#260 verdict §3c), narrowed (foreground closes are immediate) but not eliminated. Widget-timeline reloads from the extension are #238's remit.
- **R4 — Pre-existing stop-schedule re-registration exposure.** Unchanged by C2 (grant paths touch only their own activity names, and only from the main app); settled by the §10 probe; tracked outside this bundle.
- **R5 — `excessiveActivities` budget.** Each active grant adds one registration (≤1 concurrent under I9, plus session-level activities) — far under the ~20-activity budget; the fail-closed grant path (X15) is the designed behavior if other features ever exhaust it.
- **R6 — Restriction/state divergence transients.** Restrictions can diverge from persisted state until the next *authorized* wake: (i) a process dying inside or between critical sections (X22/X23, the §6.4-funnel gap — over-blocking for openers, under-blocking for closers); (ii) M's pre-existing apply-then-persist session-start gap (X28 — neutralized for the extension by D-C2-4's per-process rule, so no C2 code widens it); (iii) the pre-existing teardown gap "session removed, deactivate not yet run" — with the extension's OFF-on-no-session arm removed, this over-blocking transient heals only at the next **main-app** wake (a deliberate trade: the alternative was X28's under-blocking of whole sessions); (iv) G17 class (iii)'s pre-existing callback-dependent *initial* blocking for timer-strategy sessions, which C2 improves (X33) but does not own. All converge; none is permanent; every under-blocking case requires a process death (mid- or between-section), and the death-free divergences are all in the over-blocking (safe) direction.
- **R7 — Legacy upgrade-window grants (rev 5, honest scope).** A break running across the C2 app update has no persisted deadline, no pinned config, and only its legacy `repeats:false` one-shot registration. It is **fully migrated at the first main-app wake post-update** (stamp + pin + C2 backstop, I6(c)/I5); the extension can stamp-and-close it earlier only while the profile snapshot is present. Until a migrating M wake: (i) a profile-duration edit moves the eventual stamp once; (ii) if the profile snapshot is also wiped, the extension can neither stamp, close, nor re-block it — the corner converges only at the next app open (this is the honest bound; X30's "trace is dead" claim applies to C2-opened/migrated grants); (iii) a dropped legacy one-shot callback has no daily re-fire behind it. One grant, upgrade-window only, requires the update to land mid-break; with no live users, near-theoretical — but stated, not hidden.
- **R8 — Degraded-lock best-effort mode.** `SharedData.withLock` as shipped proceeds unlocked (with a log) if the lock file cannot be opened or flocked. C2 openers refuse to run in that mode (D-C2-3); closers/derive proceed best-effort with immediate pre-apply re-validation. The surviving hazard — an unlocked, preempted closer applying a stale re-block over a freshly opened grant (X35) — needs two independent rare conditions, is over-blocking-direction, and converges at the next wake. Serialization claims in this contract are scoped to acquired-lock execution.

---

## 12. Named test scenarios

Unit-testable without a device (pure functions, CAS primitives, closer bodies with injected `now` and seam-injected blocker/center spies — per AGENTS.md pin-time rules):

| ID | Scenario |
|---|---|
| T-C2-U1 | `wrapAnchorInterval`: 5-min deadline mid-day ⇒ end = ceil-minute, start = end+1, length 1439; never-early property across `now` second offsets 0…59 |
| T-C2-U2 | `wrapAnchorInterval` midnight wrap (X19): deadline 00:03 ⇒ anchor 00:04 |
| T-C2-U3 | Break closer CAS matrix: closes once; repeat ⇒ false; identity mismatch ⇒ false; already-closed ⇒ false |
| T-C2-U4 | OMM closer CAS matrix: same; `oneMoreMinuteUsed` stays true after close |
| T-C2-U5 | Deadline gate: ⚡ before deadline ⇒ no-op incl. X20 stale-callback (current grant's deadline consulted); at/after ⇒ close; nil deadline ⇒ one-time stamp (I6(c)) then gate |
| T-C2-U6 | OMM closer break-active branch: break open ⇒ OMM fields closed, restrictions remain OFF (#205 regression; X7 both orderings) |
| T-C2-U7 | Synthetic-end tolerance (X2): closed grant ⇒ closer no-ops (closed-by-early-end and closed-by-prior-executor variants) |
| T-C2-U8 | Reconciler decision table: {expired break, expired OMM, expired OMM during break, open unexpired (backstop present/absent/mismatched), no session, crash-window divergence both directions} ⇒ {close+ON, close+ON, close-fields-only, verify/replace, OFF, converge} |
| T-C2-U9 | `openBreakGrant`/`openOneMoreMinuteGrant` identity failure ⇒ returns false, no state, no restriction change (X14) |
| T-C2-U10 | `startBreak` fail-closed (X15): registration throws ⇒ no state, no lift, error surfaced, reminder NOT scheduled (#214 regression) |
| T-C2-U11 | `startOneMoreMinute` fail-closed: same for OMM (#207 regression) |
| T-C2-U12 | I1 atomicity: grant-open section commits deadline+start+lift together; no observable intermediate (spy-order assertion) |
| T-C2-U13 | Snapshot round-trip: deadlines carried by `toSnapshot`/`upsertSessionFromSnapshot`; legacy nil-deadline snapshots decode and are stamped on first evaluation |
| T-C2-U14 | Early-end sequence (X1): close section commits before deregistration (I7); `isBreakAvailable` false after (one-break-per-session) |
| T-C2-U15 | I9 absorption: `openBreakGrant` during open OMM ⇒ single section leaves {break open, OMM closed, `oneMoreMinuteUsed` true}; no intermediate both-open state observable |
| T-C2-U16 | Session end mid-grant (X17): `endSession` closes grant fields without restriction change; ingest normalization closes grant fields on an extension-ended completed snapshot |
| T-C2-U17 | Ticker expiry executor (7.4b): open break/OMM with passed deadline ⇒ closer invoked; unexpired ⇒ not |
| T-C2-U18 | I5 freshness/preservation: fresh grant replaces a leaked same-name registration (X25) *before* the lift and aborts fail-closed on failure; re-arm registers iff absent and NEVER stops a live registration (X34); re-arm registration failure ⇒ fail-closed grant close (X16) |
| T-C2-U19 | I11: `enableBreaks` flipped off mid-grant ⇒ closers/reconciler still close the grant normally (X26) |
| T-C2-U20 | `applyRestrictionsForCurrentState` derivation table per process: main app {no session, open break, open OMM, session+snapshot, session+NO snapshot} ⇒ {OFF, OFF, OFF, ON, bail-preserve}; extension {same inputs} ⇒ {bail-preserve, OFF, OFF, ON, bail-preserve} (X28/X30) |
| T-C2-U21 | AppBlockerUtil lock-free regression guard (D-C2-4): no `withLock`/SharedData accessor use inside AppBlockerUtil (grep-based CI check or equivalent) |
| T-C2-U22 | Nil-deadline stamp (X31): first evaluation writes `start + in-section duration` once; a subsequent `breakTimeInMinutes` shrink does NOT move it; no early close before the stamped deadline; **unstampable in X (missing snapshot) ⇒ not-expired, no close, no zero-default** (I6(c)) |
| T-C2-U23 | `openOneMoreMinuteGrant` break-open refusal (X32): break open on raw fields (incl. `enableBreaks == false`) ⇒ returns false, no state written, no restriction change |
| T-C2-U24 | Missing-snapshot handling (X30/X36): grant-open refused when no live snapshot to pin; closer derive re-blocks from the pinned config when the live snapshot is missing (both processes); M reconciler rebuilds the snapshot when the SwiftData profile exists, ends the orphan session when it doesn't |
| T-C2-U25 | Ingest of an extension-ended session cancels its pending break/OMM notifications (§6.4 hardening) |
| T-C2-U26 | Derive config precedence (D-C2-4): live snapshot wins; pinned config used when live absent; bail-preserve only when both absent; pinned config retained after grant close until session end |
| T-C2-U27 | Lock-acquisition surfacing: openers abort (no state, no lift) when the section runner reports acquisition failure; closers proceed with pre-apply re-validation (X35) |
| T-C2-U28 | Extension never mutates registrations (I5): no `startMonitoring`/`stopMonitoring` reachable from extension-side reconciler/closer code paths (CI grep or target-membership assertion) |
| T-C2-U29 | C2 backstop names (X37): new prefixes route to the gated closers via `TimerActivityUtil`; legacy prefixes still route (bonus wakes); session-end cleanup + orphan sweep cover both prefix families; re-arm's register-if-absent checks the C2 name only |
| T-C2-U30 | Encode-then-commit (X38): injected encode failure in a grant-open ⇒ stored session untouched, primitive returns false, no restriction change; same for a closer (retry-safe) |
| T-C2-U31 | Legacy full migration, completion-keyed (R7, rev 6): open legacy grant ⇒ stamped + pinned + C2 backstop in one M reconcile; an X-side stamp beforehand does NOT prevent M from completing pin+backstop; thereafter identical to a C2-opened grant (incl. X30 pinned re-block) |
| T-C2-U32 | "Active shared session" definition (rev 6): ended-but-present snapshot (endTime set, key present) ⇒ derive treats as no-session; M arm flushes the stale entry and applies OFF; never re-asserts ON for an ended session |
| T-C2-U33 | Extension bounded lock acquisition (rev 6): a held lock ⇒ extension runner times out into degraded mode (no indefinite block); openers N/A in X |
| T-C2-U34 | `openBreakGrant` own-family refusal (rev 6): break already open or consumed ⇒ false, no state, no restriction change |
| T-C2-U35 | Countdown surfaces derive from the persisted deadline (rev 6): mid-grant `breakTimeInMinutes` edit does not move the displayed countdown |

Device-level (manual checklist for the implementer's PR; simulator does not run DeviceActivity):

| ID | Scenario |
|---|---|
| T-C2-D1 | #260 two-tap repro: break start → immediate stop ⇒ shields return instantly; session continues; break consumed |
| T-C2-D2 | 5-minute break end-to-end backgrounded (MD-C2-1 = A): shields return within deadline + ~1 min |
| T-C2-D3 | OMM backgrounded at expiry: shields return within ~1–2 min (R2); foreground OMM exact |
| T-C2-D4 | Kill app mid-break; wait past deadline; relaunch ⇒ immediate heal (X10) |
| T-C2-D5 | §10 probe #1 (optional, non-blocking): synthetic `intervalDidEnd` on `stopMonitoring` — settles R4's separate issue |
| T-C2-D6 | §10 probe #2 (**REQUIRED before implementation**): wrap-anchor short-lead mid-window `intervalDidEnd` delivery — validates the backstop's core delivery property; a negative result feeds back into MD-C2-1 and this contract |

---

## 13. Adversarial verification log

- **Round 1 (2026-07-06, VOID as a verification round — but findings accepted):** 3 of 5 attackers completed (interleavings, atomicity, semantics; framework + consistency died on rate limits), 13 raw findings; all verifier panels died on rate limits, so no finding was independently adjudicated. The author triaged all 13 directly; **8 distinct defect clusters were accepted and fixed in rev 2:**
  1. 7.2/7.3 ordering contradiction + crash-window permanent unblock → dissolved by D-C2-4 (atomic section; no CAS-vs-apply order exists).
  2. Non-atomic gate-read→apply letting a stale executor re-block a fresh grant (#205 reborn) → dissolved by D-C2-4 serialization (X7).
  3. Crash between grant-open write and lift (grant running shielded, "burned") → the reconciler's final derive-and-apply converges (X22; rev 2 made this arm unconditional, rev 3 scoped it per-process — see round 2 fix 1); grant not burned.
  4. I5 register-if-absent adopting a leaked stale-deadline registration → I5 rewritten: replace on fresh grant, introspect on re-arm (X25, G16).
  5. §7.5(d)/X17 contradiction (unexpired grants never closed at session end; re-arm-before-cleanup; missed entry points) → dedicated `closeGrantsForSessionEnd` in the end funnel + ingest normalization; reconciler no longer invoked at teardown (§6.4, I10).
  6. I9 unimplementable as two lock acquisitions → single composite `openBreakGrant` (§6.2).
  7. Enforcement predicates leaning on `enableBreaks`-derived properties (remote-edit hazard) → I11 raw-field rule (X26).
  8. Foreground break natural-expiry executor unassigned → §7.4b assigns the ticker for both grant types.
  Additionally I6 now binds ALL closers (not just extension handlers), and main-app closers re-validate identity inside their sections — the atomicity attacker's remaining finding.
- **Round 2 (2026-07-06, COMPLETE — 68 agents, 0 errors):** 5 fresh attackers (all lenses), 21 raw findings, each judged by a 3-refuter panel; **5 confirmed** (≥2 surviving votes), 16 refuted. All 5 confirmed findings accepted and fixed in rev 3:
  1. *(interleavings, 3/3)* Extension reconciler's unconditional "no session ⇒ OFF" races M's apply-then-persist session-start (G17) — a whole session could run unblocked with no crash → **D-C2-4 per-process derivation authority** (extension never applies OFF-on-no-session; M-side reconciler pinned to M's serial executor); §5/R6 reachability claims corrected; X28.
  2. *(interleavings, 3/3)* + 4. *(atomicity, 3/3)* Nil-deadline fallback was profile-edit-sensitive and read from a routing-time profile parameter — "late-biased" false, I11/X26 contradicted → **stamp-once migration** at first evaluation with in-section duration read (I6(c)); R7; X31.
  3. *(framework, 2/3)* `applyRestrictionsForCurrentState` had an undefined missing-snapshot row with divergent literal implementations (one a permanent under-block loop) → **pinned bail-and-preserve row + M-only repair path** (§7.5.4); X30.
  5. *(semantics, 3/3)* I9's OMM-during-break direction rested on a profile-derived UI predicate; an `enableBreaks`-off edit mid-break let both grants open → **raw-field break-open refusal inside `openOneMoreMinuteGrant`** (§6.3); G8 corrected; X32; plus 7.2's raw-field toggle-routing requirement.
  Also folded from refuted-but-factually-correct fragments: G16 provenance corrected (API unused in repo; plan must verify on min target, with unconditional-replace fallback); MD-C2-2 Option A text made honest about early-end forfeiture; 7.2 closer-false behavior pinned; §6.4 ingest now cancels dangling break/OMM notifications.
- **Round 3 (2026-07-06, COMPLETE — 59 agents, 0 errors):** 5 fresh attackers, 18 raw findings, 3-refuter panels; **6 confirmed**, 12 refuted. All 6 accepted and fixed in rev 4:
  1. *(interleavings, 3/3)* G17 factually false — the timer strategies (Shortcut/NFC/QR) are a third class, persist-then-apply-BY-CALLBACK, with no in-process restriction call → G17 rewritten as a three-class inventory; serial-executor assertion re-scoped to the full inventory; X33 notes C2's session⇒ON arm *heals* the pre-existing class-(iii) callback dependence.
  2. *(interleavings, 3/3)* + 4. *(consistency, 2/3)* Missing-snapshot bail after a grant closes = death-free under-block with no hard bound (every X wake bails; only a voluntary app open converges) → **session-pinned re-block config** written at grant-open (§6.1a; grant refused if unavailable — X36), derive precedence live→pinned→bail (D-C2-4); R6's direction/bound claims corrected.
  3. *(framework, 3/3)* Re-arm's stop-then-start could destroy the grant's only OS wake (stop-succeeds/start-fails, or extension killed between) → re-arm is **register-only-if-absent, never stops** (I5); the only stop-then-start is the pre-lift fresh-grant replace (fail-closed); **the extension performs no registration mutations at all**; re-arm registration failure ⇒ fail-closed grant close (D-C2-3; rev-3 heal-forward withdrawn); `schedule(for:)` dependence dropped (G16 rewritten to name-presence only).
  5. *(atomicity, 2/3)* `withLock` documents three proceed-unlocked fallbacks; "structurally impossible" overclaimed → openers fail-closed on lock-acquisition failure; closers best-effort with pre-apply re-validation; claims scoped to acquired-lock execution; R8; X35.
  6. *(semantics, 3/3)* I6(c)'s stamp had no defined duration source under a missing snapshot (one literal reading closes a valid legacy grant via a zero default) → duration-source precedence pinned; unstampable-in-X ⇒ explicitly not-expired; zero-defaulting forbidden.
  Also folded from refuted-but-real fragments: the stop-break affordance must stay visible on raw-field break-open (7.2), completing X32's anti-stranding.
- **Round 4 (2026-07-07, COMPLETE — 56 agents, 0 errors; a first launch was voided by rate limits with zero attackers run and was fully re-run):** 5 fresh attackers, 17 raw findings, 3-refuter panels; **4 confirmed**, 13 refuted. All 4 accepted and fixed in rev 5:
  1.+3. *(interleavings 3/3, framework 3/3)* Register-if-absent adopted the legacy `repeats:false` registration under the same name — no daily re-fire, R1's ≤24h bound void, and I5's never-stop rule forbade repair → **C2-owned backstop activity names** (never conflated with legacy; legacy callbacks remain bonus healing wakes; X37) + **full legacy migration at first M wake** (stamp + pin + C2 backstop, I6(c)); R1's bound stated as conditional on registration survival (eviction-while-dead is unrepairable by any design).
  2. *(interleavings, 3/3)* X30's "round-3 trace is dead" overclaimed for un-migrated legacy grants (no pin exists) → X30 scoped to C2-opened/migrated grants; R7 rewritten with the honest next-app-open bound for the legacy+wiped-snapshot corner.
  4. *(consistency, 2/3)* The shipped `activeSharedSession` setter deletes the key on encode failure, so a grant-open could lift restrictions against a destroyed session (I1 violation, unsafe (a)) — and §6.1a's pin enlarges the payload → **encode-then-commit rule** for all C2 mutators (encode first; failure ⇒ stored value untouched, abort fail-closed pre-apply; X38); pin scoped to the minimal AppBlockerUtil subset.
  Also folded: I6's exception list gains the D-C2-3 lost-backstop fail-closed close (both grant families; a refuted-but-real consistency fragment); G17's M inventory gains `catchUpMissedScheduleStarts`.
- **Round 5 (2026-07-07, attackers COMPLETE / panels rate-limited — author-triaged like round 1):** all 5 fresh attackers ran against rev 5 and produced 13 raw findings; ~30 of the 39 refuter-panel agents died on a session rate limit, so panel adjudication is incomplete (the workflow's mechanical "0 confirmed" is an artifact of dead panels). Per the credit-budget directive, the author triaged all 13 directly; **all were accepted (none overturned the mechanism) and folded into rev 6:**
  1. X-side deadline stamp "de-legacies" a grant before M's first wake, skipping pin+backstop forever *(3 attacker variants)* → migration is **completion-keyed** (missing pin/backstop, not nil deadline; I6(c)); pin-source precedence pinned for the missing-snapshot case.
  2. `openBreakGrant` lacked the own-family raw-field refusal §6.3 has → added (§6.2).
  3. "Field-exercised" overclaimed for short-lead mid-window `intervalDidEnd` delivery → **probe #2 added as REQUIRED before implementation** (§10, T-C2-D6), with the negative-result feedback path stated.
  4. A *suspended* M holding the flock would wedge every extension wake behind a blocking `LOCK_EX` → extension acquisition is `LOCK_NB` + bounded retry, degrading to R8 semantics instead of wedging (D-C2-4).
  5. "Active shared session" was undefined against the reachable ended-but-present snapshot ⇒ presence-based derive would re-assert ON forever → defined as present AND `endTime == nil`; ended-but-present ⇒ no-session, M flushes (D-C2-4).
  6. G17's inventory shown incomplete again (legacy NFC/QR class-(i) sites) → the serial-executor inventory is now **grep-derived by the plan, never trusted from this contract** (§7.5).
  7. Stale §7.5 step-number cross-references after the rev-4 renumbering → corrected throughout.
  8. 7.4b's unconditional deregister on the closer-false path → deregister only on a true return (7.4b).
  9. Guard parity: in-section raw-read discipline gets the same CI guard as AppBlockerUtil (silent lock-loss hazard; D-C2-4).
  10. Countdown surfaces derived from the live profile while enforcement follows the deadline → all countdowns display from the persisted deadline (7.4b).
  11. The D-C2-3 fail-closed close's UX semantics under-specified → pinned at X16 (cancels notifications; consumes the grant; `errorMessage` explains).
- **VERIFICATION STATUS (honest):** rounds 2–4 each ran to full completion with independent 3-refuter panels (183 agents total, 0 errors) and each produced confirmed findings that were fixed and re-attacked by the next round's fresh attackers. Rounds 1 and 5 had their panels killed by rate limits and were author-triaged instead. **The strict A1 exit — one fully panel-verified round with zero confirmed findings — has NOT been achieved**; the closest statement supported by the evidence is: no attacker in any round found a defect that survives rev 6's text, the core mechanism (D-C2-1/2/4) has been stable since rev 2/3, and the finding trajectory moved monotonically from architectural races (round 2) to upgrade-window and documentation corners (rounds 4–5). The maintainer may optionally fund one more fully-panel-verified round against rev 6 before the prescriptive plan is written; the REQUIRED device probe (§10 #2, T-C2-D6) gates implementation regardless.
- Exit criterion for any future round: a full panel-verified round with zero breaking interleavings (§9 criterion).
