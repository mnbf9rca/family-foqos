# #307 Diagnosis Protocol — `state=disabled` during enabled operation

> **For agentic workers:** This is a **diagnosis protocol, not a fix**. Deliverables (1)–(3) below are executed as throwaway *probe commits* per house rules (never merged), a two-device capture run, and a decision made only *after* the capture names the mechanism. Steps use checkbox (`- [ ]`) syntax for tracking. REQUIRED SUB-SKILL at execution time: `superpowers:executing-plans`.

**Goal:** Add throwaway instrumentation that, in **one** two-device capture, names which mechanism drives `SyncEngineController.state == .disabled` while `ProfileSyncManager.isEnabled == true`, so the eventual fix is proportionate and correctly tiered.

**Approach:** All state writes are silent today, so the 17 `disabled` reads in the 2026-07-10 distribution are unattributable. The probes (a) attribute every `state=` read to a specific writer via a single `didSet` choke point + call-stack, (b) prove/kill instance-churn via a per-instance tag, and (c) surface the account-change event the leading hypothesis depends on. Then a scripted two-device run yields per-hypothesis signatures; then — and only then — the decision table selects the fix.

**Tech stack:** Swift 6, `@MainActor` `SyncEngineController`, CKSyncEngine driver seam, `Log` framework (category `.sync`).

## Global Constraints (copied verbatim from house rules / issue #307)

- **Plan-only. No fix in this pass.** Diagnosis first; the fix is a separate session gated on the capture (issue "Fix protocol" step 1).
- **Throwaway probe commits.** Instrumentation lands as clearly-marked `[#307 PROBE]` commits that are **reverted before any fix PR** — never force-amend, use Git revert (AGENTS.md).
- **Probe build must be Debug / `-Onone`.** Call-stack frame discrimination (Probes B/D) is unreliable under release inlining — pin the capture build to the Debug configuration.
- **Logging:** use `Log.debug(..., category: .sync)`; never log lock codes/PII. UUIDs, tags, timestamps, state values are acceptable.
- **Anchors are line-verified against `origin/main`** (worktree `plan-307-diagnosis`, HEAD `3a5eee2`) at authoring time; re-run a citation refresh (Task 0) before landing probes, since surrounding PRs move line numbers.

---

## Section 0 — Verified structural facts (the reframe)

Grounded and cross-checked first-hand against the working tree. These reframe the issue's hypothesis ranking **before** any capture:

1. **Production constructs exactly ONE controller instance.** `ProfileSyncManager.attachEngine` is idempotency-gated (`ProfileSyncManager.swift:166`, `guard engineController == nil else { return }`); its own comment states *"in production nothing else ever nils `engineController`, so this only ever fires once."* The strong owner `ownedEngineController` and the weak facade `engineController` both point at that single object (`:189-190`). **⇒ H2-as-separate-objects is not supported by production code.** The repro can only *disprove* H2, not reproduce it (a second instance requires the test-only re-attach path leaking to prod).

2. **`state` and `isEnabled` are independent variables on two different objects.** `state: SyncEngineState` (`SyncEngineController.swift:37`, default `.disabled`) vs `@Published var isEnabled` (`ProfileSyncManager.swift:27`). Nothing keeps them in lockstep. So "`state=disabled` while `isEnabled==true`" is *structurally expected* the moment any silent writer sets `.disabled` without flipping `isEnabled`.

3. **The only line that ever prints `state=` is `requestSync`** (`SyncEngineController+Cutover.swift:10`). It reads `self.state` then **unconditionally** calls `driver?.fetchChanges()` / `driver?.sendChanges()`. The only no-op is `driver == nil` — **not** a state guard. `stop()` sets `.disabled` but never nils `driver`, so `.disabled` + live driver = accidental sync. This is the entire "works only accidentally" mechanism.

4. **Every state write is silent, and there is no single choke-point.** Writers: `start()`→`.bootstrapping` (`:143`), `stop()`→`.disabled` (`:214`), `handleZoneDeletions .purged`→`.purged` (`:307`), `handleAccountChange`→`.disabled` (`:325`), `handleDidFetchChanges`→`.steady` (`:650`), plus init default (`:37`). None log the transition.

5. **STRONGEST LEAD (H1 sub-case): `handleAccountChange` (`:321-326`).** On a CKSyncEngine `.accountChange` event (dispatched at `handle(_:)` `:275-276`) it sets `state = .disabled`, bumps `namespaceGeneration`, cancels `startupTask`/`flushTask` — **but never re-runs `start()`, never touches `isEnabled`, never logs.** Its comment defers namespace reconstruction to *"the app reconstructing the controller/store (Phase F, N11)"* — grep-confirmed **unimplemented**. Result: after any account change the single instance sits permanently at `state=.disabled` while the still-live `driver` keeps syncing. This matches the symptom and the disabled-heavy distribution better than purge.

6. **Purge is disconfirmed as the source (H3).** `.purged` (`:307-308`) sets `state = .purged` (a *distinct* value from `.disabled`) **and** `SharedData.deviceSyncEnabled = false`. The issue reports neither a `purged` read nor `deviceSyncEnabled=false` in the capture. Reset (`ResetController.beginReset`) writes neither `state` nor `deviceSyncEnabled` and emits its own `Reset sync: enqueue …` logs — also absent.

**Net:** the diagnosis pivots from **H2 (stale instance)** to **H1 (stale *state field* on the single instance)**, with `handleAccountChange` the prime suspect. The probes must still *distinguish* all four, and — critically — the repro must *trigger the account-change path*, which the naïve toggle-off/on protocol does not.

---

## Section 1 — Instrumentation diff (throwaway probes)

> Anchors verified against HEAD `3a5eee2`. Re-verify with Task 0 before editing.

### Task 0: Citation refresh (do first, every probe session)

- [ ] **Step 1:** Re-locate each anchor — line numbers drift with sibling PRs.

```bash
cd <worktree>
grep -n "private(set) var state: SyncEngineState" Foqos/CloudKit/SyncEngine/SyncEngineController.swift   # ~:37
grep -n "func stop()" Foqos/CloudKit/SyncEngine/SyncEngineController.swift                                # ~:204
grep -n "func handleAccountChange" Foqos/CloudKit/SyncEngine/SyncEngineController.swift                   # ~:321
grep -n "case .accountChange" Foqos/CloudKit/SyncEngine/SyncEngineController.swift                        # ~:275
grep -n "case .purged:" Foqos/CloudKit/SyncEngine/SyncEngineController.swift                              # ~:299
grep -n "func requestSync" Foqos/CloudKit/SyncEngine/SyncEngineController+Cutover.swift                   # ~:9
grep -n '\$isEnabled' Foqos/CloudKit/ProfileSyncManager.swift                                            # ~:76
grep -n "isEnabled = SharedData.deviceSyncEnabled" Foqos/CloudKit/ProfileSyncManager.swift                # ~:72
grep -n "engineController = controller" Foqos/CloudKit/ProfileSyncManager.swift                          # ~:190
grep -n "static var deviceSyncEnabled" Packages/FoqosShared/Sources/FoqosShared/SharedData.swift          # ~:674
```

### Probe Shared: per-instance tag (H2 discriminator)

- [ ] Add a computed `instanceTag` next to the `state` property in `SyncEngineController.swift` (near `:37`):

```swift
// [#307 PROBE] stable per-instance id for H2 (stale-instance) attribution. Cheap, no state.
var instanceTag: String { String(UInt(bitPattern: ObjectIdentifier(self).hashValue) & 0xFFFFF, radix: 16) }
// [#307 PROBE] monotonic state-write sequence (H4 discriminator — see Probe D / requestSync).
private(set) var stateWriteSeq: Int = 0
```

> `instanceTag` uses `ObjectIdentifier(self).hashValue`, which is **per-process seeded** — tags are stable within one device's run but **NOT comparable across the two devices' logs**. Compare tags only within a single device's capture.

### Probe D: every state transition + instance identity (the choke point)

- [ ] Replace `SyncEngineController.swift:37` (`private(set) var state: SyncEngineState = .disabled`) with a `didSet`-instrumented version:

```swift
private(set) var state: SyncEngineState = .disabled {
  didSet {
    // [#307 PROBE] didSet does NOT fire for the init default — construction is logged separately.
    stateWriteSeq += 1
    Log.debug(
      "[#307 tag=\(instanceTag) seq=\(stateWriteSeq) main=\(Thread.isMainThread)] " +
      "state \(oldValue) -> \(state) caller=" +
      Thread.callStackSymbols.dropFirst().prefix(3).joined(separator: " | "),
      category: .sync)
  }
}
```

Why `didSet` over a `setState(_:)` helper: the five writers already assign to `state` directly, so a `didSet` captures **all** of them — including any *unknown* writer, which is the whole point of H1 — with zero call-site edits. `Thread.callStackSymbols` supplies the caller frame that `#function` cannot see from inside a property. `main=` and `seq=` are the H4 discriminators (see Section 4).

### Probe D-construct: instance identity at birth (requirement d)

- [ ] In `ProfileSyncManager.swift`, immediately after the `engineController = controller` assignment (`~:190`):

```swift
Log.debug("[#307 tag=\(controller.instanceTag)] controller CONSTRUCTED (attachEngine)", category: .sync)
```

A **second** `CONSTRUCTED` line in one capture is direct, dispositive H2 proof (attach is idempotency-gated at `:166`).

### Probe D-req: instance identity in the `state=` read log (requirement d, load-bearing)

- [ ] Replace the `Log.debug` at `SyncEngineController+Cutover.swift:10`:

```swift
Log.debug(
  "[#307 tag=\(instanceTag) lastSeq=\(stateWriteSeq) main=\(Thread.isMainThread)] " +
  "Sync requested: state=\(state), driverNil=\(driver == nil), resetIntentActive=\(store.resetIntent != nil)",
  category: .sync)
```

`driverNil` distinguishes *disabled-but-live-driver* (accidental work) from *disabled-and-dead-driver* (true no-op / never-started). `lastSeq`/`main` let the timeline test whether a read disagrees with the last logged write (H4).

### Probe B: every `stop()` with its CALLER (requirement b)

- [ ] As the **first** line inside `stop()` (`SyncEngineController.swift:~205`):

```swift
Log.debug(
  "[#307 tag=\(instanceTag)] stop() ENTER caller=" +
  Thread.callStackSymbols.dropFirst().prefix(4).joined(separator: " | "),
  category: .sync)
```

The only known production caller is the `$isEnabled` disable branch (`ProfileSyncManager.swift:86`). A `stop()` whose caller frame is **not** that sink is the H1 (unknown-path) signature. A `Thread.callStackSymbols` capture (not a `caller:` default-arg) is required precisely because the hypothesis is an *unknown* path — a default arg is only filled by known call sites.

### Probe A: every `isEnabled` transition (requirement a)

- [ ] As the **first** line inside the `$isEnabled` sink (`ProfileSyncManager.swift`, after `~:79`):

```swift
Log.debug("[#307] isEnabled TRANSITION -> \(enabled) (observer fired)", category: .sync)
```

- [ ] Cover the cold-load seed that `dropFirst()` hides — after `ProfileSyncManager.swift:72` (`isEnabled = SharedData.deviceSyncEnabled`):

```swift
Log.debug("[#307] isEnabled COLD-LOAD = \(isEnabled) (observer NOT fired — dropFirst)", category: .sync)
```

Together these prove whether `isEnabled` ever flipped `false` during the window — kills or confirms the "normal enabled operation" premise.

### Probe C: purge / `deviceSyncEnabled` writes (requirement c)

- [ ] In the `.purged` branch, after `SyncEngineController.swift:308` (`SharedData.deviceSyncEnabled = false`):

```swift
Log.debug("[#307 tag=\(instanceTag)] PURGE T6: state=.purged, deviceSyncEnabled=false (caller=handleZoneDeletions)", category: .sync)
```

- [ ] Catch-all at the setter — first line inside `set` of `SharedData.deviceSyncEnabled` (`SharedData.swift:~681`, before `withLock`):

```swift
Log.debug(
  "[#307] deviceSyncEnabled WRITE = \(newValue) caller=" +
  Thread.callStackSymbols.dropFirst().prefix(3).joined(separator: " | "),
  category: .sync)
```

> **H3 disambiguation (skeptic fix):** a bare `deviceSyncEnabled WRITE = false` is **non-unique** — the `$isEnabled` disable observer (`ProfileSyncManager.swift:80`) emits the identical write on a normal user-disable. The clean H3 tell is the **`PURGE T6` line + a `state -> purged` transition (value = purged, not disabled) + caller frame `handleZoneDeletions`** — *not* the bare `WRITE=false`.

### Probe E: the account-change event itself (H1 favourite — surface the trigger)

- [ ] In `handle(_:)`, at the `.accountChange` case (`SyncEngineController.swift:~275`), before `handleAccountChange(kind)`:

```swift
Log.debug("[#307 tag=\(instanceTag)] EVENT .accountChange kind=\(kind) -> handleAccountChange (no restart implemented)", category: .sync)
```

This records the `kind` (`SyncEngineAccountChangeKind`) and answers grounding's open question: does `.accountChange` fire spuriously (launch/token-refresh) vs on a real sign-in? Probe D's `didSet` already proves `handleAccountChange` *ran*; Probe E says *why*.

> **GROUNDING GAP:** the "#303 pre-check" named as an H1 candidate in the issue is not present in any grounding map. Probes B/D `callStackSymbols` will surface it if it calls `stop()` or writes `state`; no dedicated probe can be anchored without its file:line.

- [ ] **Commit** the probes as one throwaway commit: `git commit -m "[#307 PROBE] instrument state transitions, stop callers, purge writes, account-change event (REVERT before fix)"`

---

## Section 2 — Two-device repro protocol

**Roles.** Device **A** and Device **B**, same iCloud account, sync enabled on both, both running the **Debug** probe build. Device A stays signed in and untouched (it provides the other end of sync); Device B performs the sync toggles and the iCloud sign-out — pick as B the device with less personal iCloud state riding on it (Step 4 signs it out temporarily). *(Rev 2, 2026-07-13: roles renamed from P/C — the parent/child labels wrongly suggested family-mode/two-account testing, but this protocol is same-account; Step 3's ~2s race replaced with an offline-restart hold; Step 0 prep added.)*

- [ ] **Step 0 — Prep.** Tidy test data but **keep two simple profiles** (name + a few apps, **no schedules** — Steps 3–4 need one profile to rename on A and a different one to edit on B, and schedules add warning-banner noise). Confirm both devices show the same two profiles, synced and stable. Clear the in-app logs on both devices. THEN install the probe build on both (no debugger attached) — data prep before install keeps install-time sync churn out of the capture.

- [ ] **Step 1 — Verify probes live.** On each device: manual "Sync Now" → confirm `[#307 … Sync requested: state=…]` appears in logs.
- [ ] **Step 2 — Offline restart (exercises H1-stop / start / H4).** Put **both** devices in airplane mode. Device B: Settings → toggle sync **off**, then **on** (`SettingsView.swift:126`). Expect an `isEnabled TRANSITION -> false` then `-> true` pair, a `stop() ENTER` (caller = the sink), then a `state -> bootstrapping`. Offline, the startup sequence cannot complete, so the engine **holds** mid-restart — replacing the original ~2s race with a window as long as airplane mode stays on. (Extra retry/failure transitions during this window are expected capture signal, not noise.)
- [ ] **Step 3 — Save mid-restart, then reconnect (A3′ window).** Still in airplane mode: Device A renames one profile; Device B edits a *different* profile and hits **Save**. B's Save forces `requestSync` while `state` is mid-restart — the moment this step exists to capture. Then turn airplane mode **off** on both and let them settle ~30s.
- [ ] **Step 4 — Account-change path (H1 FAVOURITE — the step the naïve protocol omits).** On Device B: Settings → iCloud → **sign out**, then **sign back in** to the same account (or switch account and back). This is the **only** trigger of `handleAccountChange` (`handle(_:)` `.accountChange` at `:275`). Expect `EVENT .accountChange kind=…` then a `state -> disabled caller=…handleAccountChange…` with **no** preceding `isEnabled TRANSITION -> false`.
- [ ] **Step 5 — Post-account-change sync.** After Step 4, foreground Device B twice — swipe the app to the home screen, wait a few seconds, reopen; repeat once more (each reopen fires `FoqosApp.swift:150-156` → `syncNow` → `requestSync`). Expect `Sync requested: state=disabled, driverNil=false` while `isEnabled==true` — the reproduced symptom.
- [ ] **Step 6 — Steady baseline (+ #335 passenger).** Idle both 60s, foreground B once more to capture a steady-state read. Then: make one change on Device A, do **not** tap Sync Now on B, wait 60–90s, and note whether B receives it unprompted (`Received remote notification` → `requestSync()` → `fetched_batch`) — the #335 push-delivery question rides this capture.
- [ ] **Step 7 — Export.** On each device: Home → tap version footer → **Debug mode** → **Export Logs** (or Settings → Diagnostics → Debug Mode → Export Logs). Export from **both** devices — the confirming signature may live on either.

### Per-hypothesis expected signatures

| Hyp | Confirming signature | Unique distinguisher |
|---|---|---|
| **H1** (unlogged writer; favourite = `handleAccountChange`) | `state -> disabled caller=…` (Probe D) whose caller is **not** `stop`←sink, with **no** preceding `isEnabled TRANSITION -> false`; for the favourite, preceded by `EVENT .accountChange` (Probe E). Or a `stop() ENTER` whose top frame is not the `$isEnabled` sink. | The **caller frame** on a silent `.disabled` write. Same `tag` throughout. |
| **H2** (stale instance) | **Two distinct `CONSTRUCTED` tags** in one device's capture, OR `Sync requested … tag=A` interleaved with `state -> disabled … tag=B` (same device). | **Tag mismatch across lines** — impossible for a single instance. Expected result: **absent** (H2 disproven). Compare tags only within one device. |
| **H3** (purge/deviceSyncEnabled) | `PURGE T6` line **+** `state -> purged` (value = purged) **+** setter caller frame `handleZoneDeletions`. | The **`purged` value + `handleZoneDeletions` frame** — NOT a bare `WRITE=false` (the disable observer emits that too). Expected result: **absent**. |
| **H4** (actor/timing skew) | Same `tag`; a `Sync requested … state=disabled lastSeq=N` whose `seq`/timestamp is **after** a `state -> bootstrapping/steady` (also `tag`) with **no** intervening `-> disabled`, **or** a `state -> …` transition logged with `main=false`. | A **write logged off-MainActor** (`main=false`), or a **read whose `lastSeq` precedes a write it should have seen**. See Section 4 caveat. |

**Disambiguation.** H1's account-change sub-case and H3 are mutually exclusive by state value (`disabled` vs `purged`). H2 is dispositive on its own (a second `CONSTRUCTED` line). H1 vs H4: if Probe D logged a `-> disabled` transition (main-thread) immediately before the stale read, the read is *honest* ⇒ H1; only a missing transition or `main=false` write is H4 (see Section 4 — expected to be empty).

---

## Section 3 — Decision table

| Hypothesis | If confirmed: root mechanism | Proportionate fix SHAPE | Tier |
|---|---|---|---|
| **H1** (favourite: `handleAccountChange`) | `handleAccountChange` (`:321-326`) sets `state=.disabled`, cancels `startupTask`, but **never re-runs `start()`** and never logs; `isEnabled` stays true, `driver` stays live ⇒ permanent `state=disabled` while sync limps on the live driver. The deferred "Phase F N11" reconstruction is unimplemented. | Implement the deferred restart on account change: either call `start()` (guard at `:109` already permits `.disabled`) or have the facade reconstruct the controller/store for the new namespace. Add the transition log permanently. | **Design-tier** — restart-vs-reconstruct touches namespace/N11 semantics; needs maintainer decision. |
| **H2** (stale instance) | `attachEngine` ran twice (idempotency guard `:166` bypassed — e.g. a test-only reset leaking to prod); a captured `[weak self]` callback (`+Cutover.swift:39`) or startup Task on the superseded instance logs its stuck `.disabled`. | Harden single-construction (assert at `:166`); ensure superseded instances are torn down (nil `driver`, cancel tasks) so they cannot self-`requestSync`. | **Implementation-tier** — mechanical guard/teardown (unless a legitimate re-attach need surfaces ⇒ design-tier). |
| **H3** (purge/deviceSyncEnabled) | *Disconfirmed by code* (purge writes `.purged`+`deviceSyncEnabled=false`, not `.disabled`). Confirmable only if the setter catch-all shows an unexpected `false` writer with a non-observer, non-purge frame. | If an unexpected writer appears: gate/audit it. Otherwise: no fix; formally close H3. | **Implementation-tier** (audit only). |
| **H4** (actor/timing) | `state` read on a different actor/time than written. Class is `@MainActor` (`:22`); all writes fire the `didSet` on MainActor and reads are MainActor, so serialization makes this *a priori* unlikely — the `main=`/`seq=` probes confirm or kill it. | If a real race: make read/write ordering explicit (single MainActor hop). Most likely folds into H1 (an honest read of a genuinely-stuck state). | **Implementation-tier** if a true race; expected to reduce to H1. |

### Ties to the issue's open design questions (answer *after* the capture)

- **Should `requestSync` fail-loud / no-op in `.disabled`?** The `driverNil` field tells whether `.disabled` reads have a live driver (accidental work) or not. A blanket "no-op / auto-recover when `.disabled`" is **dangerous**: `.disabled` is deliberately set on user-disable (`stop()`), and `.purged` is consent-scoped. Any recovery must distinguish `.disabled` (transient/erroneous) from `.purged` (consent-scoped), not treat "not steady" uniformly. **Design-tier.**
- **Should `stop()` nil the `driver`?** `stop()` leaves `driver` alive — the entire "works accidentally" mechanism. Nilling it makes `.disabled` a true no-op and converts silent-accidental-sync into honest failure, but changes best-effort-final-send / restart semantics. **Design-tier**, and the natural companion to whichever of H1/H2 wins. **If H1 (account-change) is confirmed, the correct pairing is *restart the engine*, not *nil the driver* — resolve H1 before deciding this.**

### Fix ships with (per issue "Fix protocol" step 3)

- A facade-boundary lifecycle invariant test: `isEnabled == true` ⇒ the controller the facade routes to is operational (not `.disabled` with a live-but-orphaned driver).

---

## Section 4 — Skeptic reconciliation

An adversarial pass tried to prove the probes do **not** discriminate. Confirmed discrimination for **H1 / H2 / H3**; found **two real holes**, both fixed above, plus one honest caveat retained:

1. **Repro omitted the favourite's trigger (fixed).** Toggle-off/on exercises `stop()`/`start()` but **never** fires a CKSyncEngine `.accountChange`, the *only* trigger of `handleAccountChange`. Without the account sign-out/in step the protocol could confirm nothing about the leading hypothesis. → **Step 4 (iCloud sign-out/in) added; Probe E logs the event `kind`.**
2. **H3 confirmer was non-unique (fixed).** A bare `deviceSyncEnabled WRITE = false` is emitted by *both* the disable observer and purge. → H3 is now keyed on `PURGE T6` + `state -> purged` + `handleZoneDeletions` frame.
3. **H4 is not distinctly detectable *by state-value alone* (caveat retained).** With an `@MainActor` `didSet` catching every write and MainActor reads, a read can never disagree with the last logged write — so H4 as originally framed collapses into H1. Two responses, both applied: (a) Probes D/D-req now record `main=` (thread) and `seq=` (monotonic write counter), so a genuine actor/ordering violation *does* leave a fingerprint (`main=false`, or a read `lastSeq` preceding a write it should have seen); (b) if those never appear, that is itself the finding — `@MainActor` serialization *excludes* H4, and every stuck `.disabled` read is an honest read owned by H1/H2/H3. **The four-way split holds only with the `main`/`seq` probes; without them H4 is not falsifiable-as-distinct.**

Other skeptic notes folded in: pin the probe build to Debug/`-Onone` (release inlining collapses the caller frames Probes B/D rely on); `instanceTag` is per-process seeded (not cross-device comparable); `disabled + driverNil=true + no transition line` == a fresh/never-started instance (true no-op), **not** a stuck writer. No hard citation hallucinations were found; all anchors match the tree.

---

## Follow-through

- **Scope/tier:** Epic #263 follow-up tail. Diagnosis-only pass; ships as a **plan-only PR** (this document). The probe commits and capture run are a *separate* implementation session; the fix is a *third* session gated on the named mechanism.
- **Escalation:** if the capture shows user-visible sync loss (not merely accidental-but-working sync), escalate ahead of the current follow-up queue (issue tracking note).
- **Expected headline result:** a single `state -> disabled caller=…handleAccountChange…` (preceded by `EVENT .accountChange`, no `isEnabled TRANSITION -> false`, same `tag`, `main=true`) — confirming **H1 / account-change / stale-state-field**, pointing the fix at *implement the deferred N11 restart*, design-tier.
