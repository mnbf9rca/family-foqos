# #294 — "Tap to stop" Validation Regression: Empirical Probe + Gated Fix Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove — on a clean, known-commit device build — whether creating a new profile with "Tap to stop" actually fails validation, and if so capture the exact write that sets `stopConditions.manual = false`; only then apply a minimal fix targeted at the proven mechanism. Do **not** ship a "seed defaults" band-aid.

**Architecture:** This plan is empirical-probe-first, in the style of `docs/superpowers/plans/2026-07-07-285-rev2-empirical-two-phase-delete.md`. A pre-flight code investigation (below, and independently verified by a 3-lens adversarial panel) found that **the mechanism #294 describes cannot exist in the current committed codebase**: the symbols it cites do not exist, no new-profile manual-seeding has ever existed, and no code path clears `stopConditions.manual` true→false on the create flow. The device log therefore does not prove what the issue claims. Phase 0 instruments every write to `stopConditions.manual` (UI-state logging, not sync-chain) and reproduces on a physical device from a named commit. A decision gate with four outcomes then routes to either a targeted fix (Phase 1, TDD) or a maintainer decision (likely: #294 is a stale artifact of a lost WIP build → close/downgrade and unblock #286).

**Tech Stack:** Swift 6, SwiftUI (`Form`/`Section`, `@Published`, custom `Binding`), SwiftData, XCTest, physical-device verification (iOS 27 device that produced the report), custom durable `Log` (category `.ui`).

---

## Binding Context

### The report and its artifact

- Symptom (issue #294): clean install → enable sync → create profile → choose "Tap to stop" → validation fails ("At least one stop condition is required"); no profile is created, nothing syncs.
- Device log (present only in the original checkout, `docs/plans/` is gitignored):
  - `docs/plans/FamilyFoqos-Logs-2026-07-08-230111.log:38`
  - ```
    [22:00:50] [DEBUG] [UI] TriggerConfigurationModel.swift:86 validate() - Trigger validation errors:
    At least one stop condition is required. Start: manual=true, NFC=false, QR=false, schedule=false,
    deepLink=false. Stop: manual=false, timer=false, NFC=false, QR=false, schedule=false, deepLink=false
    ```
  - Sibling log `docs/plans/FamilyFoqos-Logs-2026-07-08-230144.log` (36 lines) shows the same launch/enable-sync sequence with no validate() line (no create attempt).

### Pre-flight investigation findings (all independently verified — treat as established, but re-confirm citations in Task 0.0)

1. **The issue's cited code does not exist.** `applyNewProfileDefaults()` and `didLoadTriggerConfig` appear in **no commit** (`git log --all -S` for each = 0 results), **no stash**, **no reflog**, **no working tree**, and **no untracked file**. `BlockedProfileView.swift:596` (per the issue) is a toolbar dismiss `Button`, not an `.onAppear`.
2. **New-profile manual seeding never existed.** `TriggerConfigurationModel` has an empty `init() {}` and bare defaults: `@Published var startTriggers = ProfileStartTriggers()` and `@Published var stopConditions = ProfileStopConditions()` (`Foqos/Models/TriggerConfigurationModel.swift:10-11,24`). `ProfileStartTriggers.manual` defaults `false` (`Foqos/Models/ProfileStartTriggers.swift:7`); `ProfileStopConditions.init` defaults `manual: false` (`Packages/FoqosShared/Sources/FoqosShared/ProfileStopConditions.swift:20`). `.onAppear` seeds **only when editing** an existing profile (`Foqos/Views/BlockedProfileView.swift:588-592`, guarded by `if let existingProfile = profile`). The introduction commit `41ff702` already had bare defaults. The **only** source line that sets `stop.manual = true` is `Foqos/Utils/TriggerMigration.swift:52` (V1→V2 migration), which is never invoked on the interactive create flow.
3. **No code path clears `stopConditions.manual` true→false on the new-profile flow.** Traced and verified: the `binding(\.manual)` set writes only the `manual` keyPath (`StopConditionSelector.swift:148-156`); `NFCStopOption`/`QRStopOption.apply(to:)` touch only NFC/QR fields, never `manual` (`TriggerPickerOptions.swift:59-63,128-132`); `.onChange(of: nfcOption/qrOption)` and `.onChange(of: startTriggers.hasNFC/hasQR)` only re-apply NFC/QR options (`StopConditionSelector.swift:37-47,63-73`); `.onChange(of: conditions)` reassigns only the local `@State nfcOption/qrOption`, not `conditions` (`StopConditionSelector.swift:125-128`); `startTriggersDidChange()` → `validator.autoFix` only clears `sameNFC`/`sameQR` (`TriggerConfigurationModel.swift:27-30`, `TriggerValidator.swift:32-34,41-43,98-102`); `validate()` is read-only. There is **no wholesale reassignment** of `stopConditions` on the create path (only `init` and `loadFromProfile`, the latter editing-only).
4. **The "Tap to stop" toggle is functional for new profiles.** `disabled: editingDisabled` (`BlockedProfileView.swift:382`); for `profile == nil`: `isManagedProfile = false`, `isUnlockedForEditing = true`, so `ProfileEditGate.editingDisabled(isBlocking:false, isManaged:false, …) = false` (`Foqos/Utils/ProfileEditGate.swift:15`).
5. **`validate()` reads live state, not a stale copy** (`TriggerConfigurationModel.swift:38-39,88-89`). The log line is emitted only when `validationErrors` is non-empty, and mirrors current state. `Start: manual=true` therefore means only that the user toggled "Tap to start"; it does **not** prove seeding ran or that a stop condition was cleared.

### Where the defect lives (answers to two maintainer questions)

- **Does the defect live on `fix/286-reset-sync-poison`?** Not in its committed code. `fix/286`'s versions of `BlockedProfileView.swift`, `TriggerConfigurationModel.swift`, `StopConditionSelector.swift`, `TriggerPickerOptions.swift`, and `TriggerValidator.swift` are **byte-identical to `origin/main`** (empty diff). The device build was `fix/286` **plus then-present uncommitted working-tree edits** to `BlockedProfileView.swift` and `TriggerConfigurationModel.swift` (both showed `M` at the start of the investigation session). Those edits were **since reverted**, were **never committed or stashed** (the two stashes touch only CloudKit sync files), and are **unrecoverable** (no dangling git blob holds them). If the defect was ever real, it lived transiently in those lost WIP edits — not in any branch's committed code.
- **Is `main == origin/main`?** No. Local `main` (`4307654`, #289) is a strict ancestor of `origin/main` (`dff1333`, #292); they differ by three **plan-only** PRs (#290, #291, #292) that touch no code. For the trigger code they are identical. This plan's known-good build commit is `origin/main` HEAD.

### Working conclusion this plan must test

The most probable outcome is that **#294 does not reproduce on a clean current-`main` build**, because the described mechanism is absent from committed code and the reporting build's exact source is lost. Phase 0 exists to confirm or overturn that on device before any code is written. If it *does* reproduce, the probe will name the exact write, and Phase 1 applies a minimal fix to that write.

---

## Global Constraints

- **Phase 0 is required. No fix before device evidence.** The stated mechanism is falsified by code reading; do not re-implement it.
- **No "seed defaults" band-aid.** Seeding `manual: true` for new profiles duplicates behavior that never existed and targets a non-existent cause. It is explicitly prohibited as a fix. (A regression **test** encoding the correct contract is allowed — see Phase 1 baseline.)
- **Physical-device verification is authoritative.** The report is device-only; in-memory unit tests cannot reproduce SwiftUI `Form` render/commit timing. The device that produced `FamilyFoqos-Logs-2026-07-08-230111.log` (iOS 27) is the reference.
- **Build from a named commit.** Base every build on `origin/main` HEAD (currently `dff1333`); record the exact SHA in the evidence note. Do **not** build from `fix/286` or any working tree with uncommitted edits — the whole point is a clean, reconstructable source.
- **UI-state logging only.** Probe logs use category `.ui` and cover the trigger UI state machine. Do **not** add sync-chain (`.sync`/`.cloudKit`) logging in this plan.
- **Temporary probe code must not ship.** Commit probes normally, then remove them with a normal revert/commit before any production fix. Never amend, never force-push (AGENTS.md).
- **TDD for any Phase 1 code.** Write the failing test first; test names follow `testGivenX_WhenY_ThenZ`.
- **Single build/test stream.** Simulator UUID `B9E4A679-BDF3-4541-A59F-DA4BE21F80ED` (iPhone 17, already booted). Never use a device **name** in `-destination` (clones a 16 GB sim each run — AGENTS.md). Use `-parallel-testing-enabled NO` if test launch hangs.
- **Branching.** The implementing session branches `fix/294-tap-to-stop-validation` off `origin/main`. `#294` must **not** be folded into `#286`.
- **PR wording.** The plan PR (this document) is titled **"plans the fix for #294"** — never "fixes #294". The eventual fix PR wording is a separate decision at that time.
- **#294 blocks #286** and is top of the queue: `#286`'s exit criterion is the two-device sync checklist, which cannot run until profiles can be created. `#286`'s code is complete/reviewed and paused at its verification gate.

---

## File Structure

### Phase 0 — temporary probe files (all reverted before Phase 1)

- Modify temporarily: `Foqos/Models/TriggerConfigurationModel.swift`
  - Add `didSet` observers on `startTriggers` and `stopConditions` that log every change to `.manual` with a call-stack marker. Add a state log to `loadFromProfile`.
- Modify temporarily: `Foqos/Components/BlockedProfileView/StopConditionSelector.swift`
  - Log the "Tap to stop" binding set; log `.manual` before/after each `apply(to:)` in the NFC/QR `onChange` handlers (to prove they never touch `manual`).
- Modify temporarily: `Foqos/Views/BlockedProfileView.swift`
  - Log `.onAppear` (proves no seeding for new profiles) and `saveProfile()` entry state (the value `validate()` will read).

### Phase 1 — candidate production files (only if the decision gate routes to a code fix)

- Modify: `Foqos/Models/TriggerConfigurationModel.swift` **and/or** `Foqos/Components/BlockedProfileView/StopConditionSelector.swift` — exact file depends on the proven mechanism (see Decision Gate).
- Test (always shipped): `FoqosTests/TriggerConfigurationModelTests.swift` — regression tests encoding the create-flow invariants.
- Test (conditional): `FoqosTests/StopConditionSelectorBindingTests.swift` — only if the device proves a binding/`onChange` mechanism reproducible at the model layer.

---

## Phase 0: Empirical Device Probe

### Task 0.0: Refresh citations against the build commit

**Files:** none (verification only).

- [ ] **Step 1: Record the build commit and confirm the cited code still matches**

Run from the repo root:

```bash
git rev-parse HEAD
git grep -n "applyNewProfileDefaults\|didLoadTriggerConfig" -- '*.swift' ; echo "grep-exit=$?"
grep -n "Log.debug" Foqos/Models/TriggerConfigurationModel.swift | head -1
sed -n '10,11p;24p' Foqos/Models/TriggerConfigurationModel.swift
sed -n '588,592p' Foqos/Views/BlockedProfileView.swift
sed -n '148,156p' Foqos/Components/BlockedProfileView/StopConditionSelector.swift
sed -n '15p' Foqos/Utils/ProfileEditGate.swift
```

Expected:
- `grep-exit=1` (no matches — the issue's symbols do not exist). **If this prints matches, STOP** — the code has diverged from this plan's premise; re-investigate before probing.
- `TriggerConfigurationModel.swift` `Log.debug` inside `validate()` is at **line 86** (matches the device log `TriggerConfigurationModel.swift:86`).
- Lines 10–11 are the bare `@Published var startTriggers = ProfileStartTriggers()` / `= ProfileStopConditions()`; line 24 is `init() {}`.
- `BlockedProfileView.swift:588-592` is the `.onAppear` whose body is only `if let existingProfile = profile { triggerConfig.loadFromProfile(existingProfile) }`.
- `ProfileEditGate.swift:15` is `isBlocking || (isManaged && !isUnlocked && mode == .child && lockActive)`.

If any line number drifted (edits landed since this plan), update the Task 0.1–0.3 anchors accordingly before editing. The probe content does not change — only the insertion points.

### Task 0.1: Instrument every write to `stopConditions.manual`

**Files:**
- Modify temporarily: `Foqos/Models/TriggerConfigurationModel.swift`

- [ ] **Step 1: Add `didSet` manual-change logging to both published trigger structs**

Replace lines 10–11:

```swift
  @Published var startTriggers = ProfileStartTriggers()
  @Published var stopConditions = ProfileStopConditions()
```

with:

```swift
  @Published var startTriggers = ProfileStartTriggers() {
    didSet {
      guard oldValue.manual != startTriggers.manual else { return }
      Log.debug(
        "[#294 PROBE] startTriggers.manual \(oldValue.manual)->\(startTriggers.manual)\n"
          + Thread.callStackSymbols.dropFirst().prefix(10).joined(separator: "\n"),
        category: .ui
      )
    }
  }
  @Published var stopConditions = ProfileStopConditions() {
    didSet {
      guard oldValue.manual != stopConditions.manual else { return }
      Log.debug(
        "[#294 PROBE] stopConditions.manual \(oldValue.manual)->\(stopConditions.manual)\n"
          + Thread.callStackSymbols.dropFirst().prefix(10).joined(separator: "\n"),
        category: .ui
      )
    }
  }
```

`stopConditions` is a value-type struct; any field mutation through the `$triggerConfig.stopConditions` binding reassigns the whole struct and fires `didSet`. The `guard` filters to `.manual` transitions only, so this logs **exactly** the writes we care about, with the call stack that caused each one. `startTriggers` is instrumented symmetrically as a control (the log shows `start.manual=true` surviving — we want to confirm the start toggle persists identically to the stop toggle).

- [ ] **Step 2: Log the load path (must NOT run for a new profile)**

In `loadFromProfile(_:)`, immediately after the opening brace (before `startTriggers = profile.startTriggers`), add:

```swift
    Log.debug(
      "[#294 PROBE] loadFromProfile called (EDITING existing profile) id=\(profile.id)",
      category: .ui)
```

For the #294 create flow this line must **never** appear. If it does, the view is being handed a non-nil `profile` when the user thinks they are creating one — a different bug.

- [ ] **Step 3: Verify the probe compiles**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO \
  -only-testing:FoqosTests/TriggerConfigurationModelTests | xcpretty
```

Expected: `TriggerConfigurationModelTests` pass (existing suite, unchanged behavior — the `didSet` only logs). If it fails to compile because `@Published` + `didSet` is rejected by the toolchain, fall back to a manual observer: rename the stored properties to `startTriggers`/`stopConditions` computed wrappers over `_startTriggersStorage` is over-engineering — instead move the log into the two call sites in Task 0.2 and skip the `didSet`. Note which path you took in the evidence note.

### Task 0.2: Instrument the selector's write sites

**Files:**
- Modify temporarily: `Foqos/Components/BlockedProfileView/StopConditionSelector.swift`

- [ ] **Step 1: Log the "Tap to stop" binding set**

In `binding(_:)` (lines 148–156), replace the `set:` closure:

```swift
      set: { newValue in
        conditions[keyPath: keyPath] = newValue
        onConditionChange()
      }
```

with:

```swift
      set: { newValue in
        if keyPath == \ProfileStopConditions.manual {
          Log.debug(
            "[#294 PROBE] StopConditionSelector Tap-to-stop toggle set newValue=\(newValue)",
            category: .ui)
        }
        conditions[keyPath: keyPath] = newValue
        onConditionChange()
      }
```

This proves whether the user's tap on "Tap to stop" reaches the binding at all.

- [ ] **Step 2: Prove the NFC/QR `apply` paths never touch `manual`**

Replace the NFC picker `onChange` (lines 37–40):

```swift
      .onChange(of: nfcOption) { _, newValue in
        newValue.apply(to: &conditions)
        onConditionChange()
      }
```

with:

```swift
      .onChange(of: nfcOption) { _, newValue in
        let before = conditions.manual
        newValue.apply(to: &conditions)
        Log.debug(
          "[#294 PROBE] nfcOption.apply(\(newValue.rawValue)) manual \(before)->\(conditions.manual)",
          category: .ui)
        onConditionChange()
      }
```

Replace the QR picker `onChange` (lines 63–66) with the analogous block, substituting `qrOption` for `nfcOption`:

```swift
      .onChange(of: qrOption) { _, newValue in
        let before = conditions.manual
        newValue.apply(to: &conditions)
        Log.debug(
          "[#294 PROBE] qrOption.apply(\(newValue.rawValue)) manual \(before)->\(conditions.manual)",
          category: .ui)
        onConditionChange()
      }
```

Expected on device: every such line shows `manual X->X` (unchanged). If any shows `true->false`, that `apply` is the culprit (would contradict the code reading — capture it).

- [ ] **Step 3: Verify compile**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO \
  -only-testing:FoqosTests/TriggerConfigurationModelTests | xcpretty
```

Expected: pass.

### Task 0.3: Instrument the create-flow boundaries

**Files:**
- Modify temporarily: `Foqos/Views/BlockedProfileView.swift`

- [ ] **Step 1: Log `.onAppear` state (proves no seeding)**

Replace the `.onAppear` block (lines 588–592):

```swift
        .onAppear {
          if let existingProfile = profile {
            triggerConfig.loadFromProfile(existingProfile)
          }
        }
```

with:

```swift
        .onAppear {
          Log.debug(
            "[#294 PROBE] BlockedProfileView.onAppear isNewProfile=\(profile == nil) "
              + "start.manual=\(triggerConfig.startTriggers.manual) "
              + "stop.manual=\(triggerConfig.stopConditions.manual)",
            category: .ui)
          if let existingProfile = profile {
            triggerConfig.loadFromProfile(existingProfile)
          }
        }
```

Expected for the create flow: `isNewProfile=true start.manual=false stop.manual=false` — i.e. no seeding, both start all-false. (This directly falsifies the issue's "seeding ran" premise, or overturns the code reading if it prints `true`.)

- [ ] **Step 2: Log `saveProfile()` entry state (what `validate()` will read)**

In `saveProfile()`, immediately before `triggerConfig.validate()` (line 941), add:

```swift
    Log.debug(
      "[#294 PROBE] saveProfile begin isEditing=\(isEditing) "
        + "start.manual=\(triggerConfig.startTriggers.manual) "
        + "stop.manual=\(triggerConfig.stopConditions.manual)",
      category: .ui)
```

- [ ] **Step 3: Verify compile**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO \
  -only-testing:FoqosTests/TriggerConfigurationModelTests | xcpretty
```

Expected: pass.

- [ ] **Step 4: Commit the probe**

```bash
git add Foqos/Models/TriggerConfigurationModel.swift \
  Foqos/Components/BlockedProfileView/StopConditionSelector.swift \
  Foqos/Views/BlockedProfileView.swift
git commit -m "refs #294: add temporary Tap-to-stop UI-state probe"
```

### Task 0.4: Physical-device reproduction

**Files:** none.

- [ ] **Step 1: Build, install, launch on the reference device**

Discover the paired device UUID:

```bash
xcrun devicectl list devices
```

Build and install (substitute the discovered device id for `<DEVICE_ID>`):

```bash
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS,id=<DEVICE_ID>' -configuration Debug build | xcpretty

xcrun devicectl device install app --device <DEVICE_ID> \
  "$(xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
      -destination 'platform=iOS,id=<DEVICE_ID>' -configuration Debug -showBuildSettings \
      | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/{d=$2} / FULL_PRODUCT_NAME =/{n=$2} END{print d"/"n}')"

xcrun devicectl device process launch --device <DEVICE_ID> com.cynexia.family-foqos
```

- [ ] **Step 2: Run the exact repro and watch the log**

Reproduce the issue's steps precisely, observing the live device console (Xcode → Window → Devices and Simulators → Open Console, or `Log` export via Settings → Diagnostics → Debug Mode → Export Logs afterward):

1. Delete the app (clean install).
2. Launch; complete onboarding as **Individual**; grant Family Controls.
3. Enable Profile Sync (wait for `Profile Sync toggle changed: enabled=true engineAttached=true`).
4. Tap **+** to create a new profile. → capture the `BlockedProfileView.onAppear` probe line.
5. Enter a name.
6. Toggle **"Tap to start"** ON. → capture `startTriggers.manual false->true`.
7. Toggle **"Tap to stop"** ON. → **capture whether `StopConditionSelector Tap-to-stop toggle set newValue=true` AND `stopConditions.manual false->true` appear.**
8. Do **not** touch any other trigger control.
9. Tap the **checkmark** (Create). → capture `saveProfile begin … stop.manual=?` and, if it fails, the `validate()` line.
10. Repeat steps 4–9 a second time, this time toggling "Tap to stop" **before** "Tap to start", to test ordering.

- [ ] **Step 3: Export and save the device log next to the original evidence**

Save the exported log to `docs/plans/FamilyFoqos-Logs-294-probe-<HHMMSS>.log` (gitignored; lives only in the original checkout). Keep it for the evidence note.

### Task 0.5: Decision gate

**Files:** none (write the evidence note into the plan thread, not a repo doc).

- [ ] **Step 1: Fill in the evidence note**

```markdown
## #294 Phase 0 Evidence
- Build commit (git rev-parse HEAD):
- onAppear line (isNewProfile / start.manual / stop.manual):
- After "Tap to start": startTriggers.manual line seen? (yes/no, values)
- After "Tap to stop": "toggle set newValue=true" seen? (yes/no)
- After "Tap to stop": "stopConditions.manual false->true" seen? (yes/no)
- Any "stopConditions.manual true->false" line? (yes/no) — if yes, paste its call stack
- Any "*.apply(...) manual true->false" line? (yes/no)
- saveProfile begin stop.manual value:
- validate() outcome (pass / which errors):
- loadFromProfile called on create? (must be no):
- Reproduced? (yes/no)
- Conclusion:
```

- [ ] **Step 2: Route by outcome**

**Gate A — Reproduced, and a `stopConditions.manual true->false` line was logged.** The call stack on that line names the exact mutation site (the analysis says this cannot happen from committed code, so this site is the real, previously-unseen cause). → Proceed to **Phase 1**, Task 1.2, using the logged site as the fix target. Also keep Task 1.1 (regression tests).

**Gate B — Reproduced, but no `manual false->true` line ever appeared after tapping "Tap to stop"** (the toggle set line is absent or `stopConditions.manual` never went true). The user's tap is not reaching/persisting through the binding — a SwiftUI `Form`/`Binding` commit-timing bug. → Proceed to **Phase 1**, Task 1.3, plus Task 1.1.

**Gate C — Not reproduced** (`stop.manual` goes `false->true` on the toggle, stays true through `saveProfile begin`, and `validate()` passes / the profile is created). This is the outcome the code reading predicts. → **STOP for maintainer decision.** #294 is a stale artifact of the lost WIP device build. Ship **only** Task 1.1 (regression tests locking in the correct contract), then recommend closing #294 and unblocking #286. See "Maintainer Decision" below.

**Gate D — Reproduced, `stop.manual` is true at `saveProfile begin`, but `validate()` still reports "At least one stop condition is required."** `validate()`/`isValid` is misreading state. → Proceed to **Phase 1**, Task 1.4, plus Task 1.1.

---

## Phase 1: Gated Fix

Task 1.1 ships in **every** non-STOP outcome (and is the sole code change under Gate C). Tasks 1.2–1.4 are mutually exclusive and selected by the gate.

### Task 1.1: Regression tests for the create-flow invariants (always)

**Files:**
- Test: `FoqosTests/TriggerConfigurationModelTests.swift`

These encode the behavior the code reading proved and that any fix must preserve. They pass on current `main` (they are guardrails), and would fail if a future change reintroduces new-profile all-false-then-cleared behavior. They are **not** a "seed defaults" change — they assert the model contract only.

- [ ] **Step 1: Write the failing/guard tests**

Add to `TriggerConfigurationModelTests` (match the file's existing `@MainActor` / setup conventions; `TriggerConfigurationModel` is `@MainActor`):

```swift
func testGivenNewModel_WhenInitialized_ThenStartAndStopAreAllFalse() {
  let model = TriggerConfigurationModel()
  XCTAssertFalse(model.startTriggers.manual)
  XCTAssertFalse(model.stopConditions.manual)
  XCTAssertFalse(model.stopConditions.isValid)
}

func testGivenTapToStopSelected_WhenStartTriggersChange_ThenStopManualIsPreserved() {
  let model = TriggerConfigurationModel()
  // User picks "Tap to stop".
  model.stopConditions.manual = true
  model.stopConditionsDidChange()
  XCTAssertTrue(model.stopConditions.manual)

  // User then picks "Tap to start"; start-change auto-fix must not clear manual stop.
  model.startTriggers.manual = true
  model.startTriggersDidChange()

  XCTAssertTrue(
    model.stopConditions.manual,
    "changing start triggers must not clear an already-selected manual stop condition")
  XCTAssertTrue(model.validationErrors.isEmpty, "manual start + manual stop is a valid config")
}

func testGivenManualStartAndStop_WhenValidated_ThenNoErrors() {
  let model = TriggerConfigurationModel()
  model.startTriggers.manual = true
  model.stopConditions.manual = true
  model.validate()
  XCTAssertTrue(model.validationErrors.isEmpty)
}

func testGivenManualStartOnly_WhenValidated_ThenRequiresStopCondition() {
  let model = TriggerConfigurationModel()
  model.startTriggers.manual = true
  model.validate()
  XCTAssertTrue(
    model.validationErrors.contains("At least one stop condition is required"),
    "this is the exact device-log error; it is correct when no stop condition is set")
}
```

- [ ] **Step 2: Run the tests**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO \
  -only-testing:FoqosTests/TriggerConfigurationModelTests | xcpretty
```

Expected: **all pass on current `main`** (they are regression guards, not red-first). If `testGivenTapToStopSelected_WhenStartTriggersChange_ThenStopManualIsPreserved` fails, the device mechanism reproduces at the model layer — record it and re-route to Task 1.2.

- [ ] **Step 3: Commit**

```bash
git add FoqosTests/TriggerConfigurationModelTests.swift
git commit -m "test(#294): lock in new-profile trigger invariants (manual stop preserved)"
```

### Task 1.2: Fix a proven mutation site (Gate A only)

**Files:**
- Modify: the file/line named by the `true->false` call stack from Task 0.5.
- Test: `FoqosTests/TriggerConfigurationModelTests.swift` (or `StopConditionSelectorBindingTests.swift` if the site is view-layer).

- [ ] **Step 1: Write a red test reproducing the proven site**

Translate the logged call stack into the smallest failing assertion. Example shape (fill the actual trigger action from the stack — e.g. if toggling "Timer" cleared `manual`):

```swift
func testGivenTapToStop_When<ProvenAction>_ThenStopManualIsPreserved() {
  let model = TriggerConfigurationModel()
  model.stopConditions.manual = true
  // <invoke exactly the mutation the call stack showed, e.g.:>
  // model.stopConditions.timer = true ; model.stopConditionsDidChange()
  XCTAssertTrue(model.stopConditions.manual)
}
```

- [ ] **Step 2: Run it red**

Run the focused command from Task 1.1 Step 2 with `/testGivenTapToStop_When<ProvenAction>_ThenStopManualIsPreserved`. Expected: FAIL (reproduces the site).

- [ ] **Step 3: Apply the minimal fix at the proven site**

Remove/guard the specific stray write the stack identified. Keep it surgical — a single guarded assignment or a removed wholesale reassignment. Do **not** broaden scope.

- [ ] **Step 4: Run green + regression suite**

Run the focused test (expect PASS), then the full `TriggerConfigurationModelTests` (expect PASS).

- [ ] **Step 5: Commit**

```bash
git commit -am "fix(#294): preserve manual stop condition across <proven action>"
```

### Task 1.3: Fix a lost toggle write (Gate B only)

**Files:**
- Modify: `Foqos/Components/BlockedProfileView/StopConditionSelector.swift`
- Test: `FoqosTests/StopConditionSelectorBindingTests.swift` (new)

The proven failure is that tapping "Tap to stop" does not persist into `stopConditions.manual`. The most common cause is a custom `Binding` whose `set` is dropped during a `Form` recompose. The minimal, idiomatic fix is to route the manual toggle through the model's published property directly rather than the per-render `binding(_:)` helper, matching how the value is read elsewhere.

- [ ] **Step 1: Write a red test at the binding layer**

Create `FoqosTests/StopConditionSelectorBindingTests.swift` — drive the same `Binding` construction the view uses and assert a set persists:

```swift
import XCTest
import FoqosShared
@testable import Foqos

@MainActor
final class StopConditionSelectorBindingTests: XCTestCase {
  func testGivenManualBinding_WhenSetTrue_ThenConditionsManualPersists() {
    var conditions = ProfileStopConditions()
    var changeCount = 0
    let binding = StopConditionSelector.manualBinding(
      conditions: Binding(get: { conditions }, set: { conditions = $0 }),
      onConditionChange: { changeCount += 1 }
    )
    binding.wrappedValue = true
    XCTAssertTrue(conditions.manual)
    XCTAssertEqual(changeCount, 1)
  }
}
```

- [ ] **Step 2: Run it red**

Focused run of `FoqosTests/StopConditionSelectorBindingTests`. Expected: compile failure — `manualBinding` does not exist yet.

- [ ] **Step 3: Extract a testable, stable binding factory**

In `StopConditionSelector`, replace the private `binding(_:)` usage for `\.manual` with a static factory the test can call, and use it for the "Tap to stop" `Toggle`:

```swift
  static func manualBinding(
    conditions: Binding<ProfileStopConditions>,
    onConditionChange: @escaping () -> Void
  ) -> Binding<Bool> {
    Binding(
      get: { conditions.wrappedValue.manual },
      set: { newValue in
        conditions.wrappedValue.manual = newValue
        onConditionChange()
      }
    )
  }
```

Change the "Tap to stop" toggle (line 23) to:

```swift
      Toggle("Tap to stop", isOn: Self.manualBinding(conditions: $conditions, onConditionChange: onConditionChange))
        .disabled(disabled)
```

Writing through `$conditions` (the outer `@Binding`) commits into `triggerConfig.stopConditions` in one hop, avoiding the per-render keyPath indirection.

- [ ] **Step 4: Run green, then device re-verify**

Focused test PASS; full `TriggerConfigurationModelTests` PASS. Then re-run Task 0.4 on device (with probes still present) and confirm `stopConditions.manual false->true` now appears and `validate()` passes.

- [ ] **Step 5: Commit**

```bash
git commit -am "fix(#294): persist Tap-to-stop toggle through a stable binding"
```

### Task 1.4: Fix a validate() misread (Gate D only)

**Files:**
- Modify: `Foqos/Models/TriggerConfigurationModel.swift` or `Packages/FoqosShared/Sources/FoqosShared/ProfileStopConditions.swift`
- Test: `FoqosTests/TriggerConfigurationModelTests.swift`

- [ ] **Step 1: Write a red test from the device state**

Reconstruct the exact `stopConditions` field values logged at `saveProfile begin` and assert `isValid`/`validate()`:

```swift
func testGivenDeviceStopConditions_WhenValidated_ThenIsValid() {
  var stop = ProfileStopConditions()
  stop.manual = true  // <plus any other true fields seen in the probe log>
  XCTAssertTrue(stop.isValid, "isValid must be true when manual (or any condition) is set")
}
```

- [ ] **Step 2: Run red, fix the predicate, run green.** Correct `ProfileStopConditions.isValid` (line 44-47) or the `requiresStopCondition` rule (`TriggerValidator.swift:54-58`) per the proven discrepancy. Full suite PASS.

- [ ] **Step 3: Commit**

```bash
git commit -am "fix(#294): correct stop-condition validity predicate"
```

### Task 1.5: Remove the probe and finalize (all non-STOP outcomes)

**Files:** the three Phase 0 probe files.

- [ ] **Step 1: Revert the probe commit**

```bash
git revert --no-edit "$(git log --format=%H --grep='refs #294: add temporary Tap-to-stop UI-state probe' -n 1)"
```

Never amend, never force-push.

- [ ] **Step 2: Confirm no probe strings remain**

```bash
rg -n "\[#294 PROBE\]" . ; echo "rg-exit=$?"
```

Expected: `rg-exit=1` (no matches).

- [ ] **Step 3: Full verification**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO | xcpretty
swift-format lint --recursive .
scripts/check-sync-guards.sh
```

Expected: full `FoqosTests` suite passes, 0 failures; lint clean; guards pass.

- [ ] **Step 4: Device acceptance**

Rebuild the production (non-probe) build, clean-install, and run the Task 0.4 repro. Expected: creating a profile with "Tap to stop" succeeds, the profile is created, and it syncs to the second device (this also unblocks the #286 two-device checklist).

---

## Maintainer Decision (Gate C — the predicted outcome)

If Phase 0 does not reproduce, the code reading is confirmed: #294's mechanism does not exist in committed code, and the reporting build's source (uncommitted, since-reverted WIP edits to the two trigger files on `fix/286`) is unrecoverable. Options:

1. **Close #294 as not-reproducible-on-`main`** (recommended). Ship Task 1.1 regression tests as the durable outcome. Unblock #286's verification gate immediately.
2. **Re-test on `fix/286` HEAD** to rule out an interaction with `#286`'s committed sync changes. (Its trigger files are byte-identical to `main`, so this is expected to also not reproduce — but it closes the loop for the reporter.)
3. **Keep #294 open pending a fresh device report** with an exportable log from a clean, committed build, if the maintainer recalls a concrete clearing behavior the probe missed.

Do not choose among these as an implementer; present the evidence note and let the maintainer decide.

---

## Self-Review

- **Spec coverage:** Phase 0 instruments every write to `stopConditions.manual` (UI-state only) and reproduces on the reference device from a named commit; the decision gate has four exhaustive outcomes; Phase 1 provides minimal, TDD, mechanism-targeted fixes plus an always-shipped regression suite; a maintainer-decision path covers the predicted not-reproducible outcome. The "seed defaults" band-aid is explicitly prohibited.
- **Placeholder scan:** No `TBD`/`TODO`/"handle edge cases". Gate-conditional tasks state exact route conditions; the one intentionally-parameterized spot (Task 1.2, the proven mutation site) is filled from device evidence by construction and is marked as such.
- **Type/citation consistency:** `stopConditions`/`startTriggers` (`@Published` on `TriggerConfigurationModel`), `stopConditionsDidChange()`, `startTriggersDidChange()`, `validate()`, `validationErrors`, `ProfileStopConditions.isValid`, `ProfileEditGate.editingDisabled`, `manualBinding(conditions:onConditionChange:)`, and the probe marker `[#294 PROBE]` are used consistently. All cited line numbers are re-verified in Task 0.0 before editing.
- **Device rigor:** Physical-device repro is the authoritative acceptance test; unit tests are regression guards, not proof of the device-only `Form` timing. Builds come from `origin/main` HEAD, never a working tree with uncommitted edits.
- **Process integrity:** Probes are reverted (never amended/force-pushed); PR titled "plans the fix for #294"; `#294` stays on its own branch, not folded into `#286`.
