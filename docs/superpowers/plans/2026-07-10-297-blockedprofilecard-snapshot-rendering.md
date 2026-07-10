# #297 — BlockedProfileCard snapshot rendering (zombie-model crash) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. This plan is **self-contained** — it assumes no prior Claude session/project memory (the implementer may be Codex). Read `AGENTS.md` at the repo root first; it overrides everything here.

**Goal:** Stop `BlockedProfileCard` from crashing (`EXC_BREAKPOINT`) when a profile is deleted, by having the card family render from an immutable **value snapshot** instead of the live SwiftData `@Model`, so an `@Observable`-driven re-render of an already-mounted card can never read a vacated store row.

**Architecture:** The crash (#297, device-proven in Phase 0) is a re-render of an already-mounted `BlockedProfileCard` on a just-deleted model: the card reads *tracked* attributes so SwiftUI re-runs its body after the delete, while the parent guards (`.valid`, `SafeModelView`) only gate *creation*. Fix: `BlockedProfileCard` and its one live-model sub-view `ProfileScheduleRow` take a `BlockedProfileCardData` **struct** (built once, behind the existing validity gate, from the live model). No view in the card subtree holds a live `@Model` → re-render touches only value fields → structurally crash-proof. The **type change is the regression guard** (Task 5): the card can no longer be handed a live `@Model` — reintroducing the bug fails to compile.

**Tech Stack:** Swift 6, SwiftData (`cloudKitDatabase: .none`), SwiftUI, `FamilyControls` (`FamilyActivitySelection`), XCTest, Xcode 26. Test simulator: boot an iPhone 17 sim ONCE by UUID (see AGENTS.md) and reuse it.

**Base commit:** `1a711a7` (latest `main`, post-#296). The Phase 0 probe branch (`fc8f80d`/`4d59f2e`/`a26e4cb`, DO NOT MERGE) is **reference only** — do not build on it; this plan starts from clean `main`.

## Global Constraints

- **Use `@SafeQuery`, never raw `@Query`** (pre-commit hook rejects `@Query`). Not touched here, but do not regress.
- **`swift-format`** clean (pre-commit auto-formats staged Swift). 2-space indent, ~100–120 col.
- **`Log`** for any logging (never `print`). None required by this plan.
- **No new SwiftData schema** — `BlockedProfileCardData` is a plain in-memory struct, NOT a `@Model`, NOT persisted, NOT synced. Do not add `@Attribute`/`@Relationship`.
- **Do not create GitHub labels.** Not applicable to code, noted for parity with repo rules.
- **Scope = card family only** (`BlockedProfileCard`, `ProfileScheduleRow`, `BlockedProfileCarousel`, one `BlockedProfiles` extension). The other latent-shape views are **out of scope** — tracked in #298. Do not touch them.
- **Trap-safe rule:** reading a stored `@Attribute` on a post-save-deleted model traps; reading `modelContext`/`isDeleted`/`persistentModelID`/`registeredModel` is safe. `isPersistentModelValid` (`Foqos/Utils/Extensions.swift`) encodes this. The snapshot builder must run **only** on a model already confirmed valid (inside `SafeModelView`'s valid branch / on a `.valid`-filtered element).

---

## Task 0: Citation refresh (MANDATORY — do this first, no code)

Verify the current code matches this plan's assumptions before writing anything. If any diverge, STOP and reconcile.

- [ ] **Step 1: Confirm the card's model reads.** `Foqos/Components/BlockedProfileCards/BlockedProfileCard.swift` — the body reads: `profile.name`, `profile.enableLiveActivity`, `profile.reminderTimeInSeconds`, `profile.enableBreaks`, `profile.enableStrictMode`, `profile.isNewerSchemaVersion`, `profile.blockingStrategyId`, `profile.selectedActivity`, `profile.sessions.count`, `profile.domains`, `profile.needsAppSelection`; and passes the live `profile` to `ProfileScheduleRow(profile:isActive:)`. Sub-views `ProfileStatsRow`, `ProfileIndicators`, `StrategyInfoView`, `ProfileTimerButton` already take **values** (confirm).
- [ ] **Step 2: Confirm `ProfileScheduleRow` reads** (`ProfileScheduleRow.swift`): `profile.schedule`, `profile.startTriggers`, `profile.stopConditions`, `profile.startSchedule`, `profile.stopSchedule`, `profile.blockingStrategyId`, `profile.profileSchemaVersion`, `profile.strategyData`, `profile.scheduleIsOutOfSync`.
- [ ] **Step 3: Confirm field types** on `BlockedProfiles` (`Foqos/Models/BlockedProfiles.swift`): `startTriggers: ProfileStartTriggers`, `stopConditions: ProfileStopConditions`, `startSchedule/stopSchedule: ProfileScheduleTime?`, `schedule: BlockedProfileSchedule?`, `scheduleIsOutOfSync: Bool` (computed), `profileSchemaVersion: Int`, `isNewerSchemaVersion: Bool` (computed, `profileSchemaVersion > currentSchemaVersion`), `selectedActivity: FamilyActivitySelection`, `sessions` (relationship), `domains: [String]?`.
- [ ] **Step 4: Confirm the carousel** (`BlockedProfileCarousel.swift`): `ForEach(validProfiles)` where `validProfiles = profiles.valid`, each wrapped in `SafeModelView(profile) { profile in BlockedProfileCard(profile: profile, isActive: profile.id == activeSessionProfileId, … onStartTapped: { onStartTapped(profile) } …) }`. The `on*Tapped` closures are defined **here** (carousel scope, live profiles) — the card only stores `() -> Void`. This is why converting the card needs **no** `HomeView`/closure-signature changes.
- [ ] **Step 5: Confirm `SafeModelView`** (`Foqos/Utils/SafeModelView.swift`) is `if model.isPersistentModelValid { content(model) }` with no else branch, and list its other call sites (`grep -rn "SafeModelView(" Foqos`) so the Task 4 placeholder change stays backward-compatible.

---

## Task 1: `BlockedProfileCardData` value struct + builder

**Files:**
- Create: `Foqos/Components/BlockedProfileCards/BlockedProfileCardData.swift`
- Test: `FoqosTests/BlockedProfileCardDataTests.swift`

**Interfaces:**
- Produces: `struct BlockedProfileCardData` (fields below) and `extension BlockedProfiles { var cardData: BlockedProfileCardData }`. Tasks 2–4 consume these.

- [ ] **Step 1: Write the failing test** (`FoqosTests/BlockedProfileCardDataTests.swift`)

```swift
import FamilyControls
import SwiftData
import XCTest

@testable import FamilyFoqos

final class BlockedProfileCardDataTests: XCTestCase {
  @MainActor
  private func makeContext() throws -> ModelContext {
    let container = try ModelContainer(
      for: BlockedProfiles.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return container.mainContext
  }

  @MainActor
  func testGivenProfile_WhenCardData_ThenMapsScalarAndDerivedFields() throws {
    let context = try makeContext()
    let profile = BlockedProfiles(
      id: UUID(), name: "Work", selectedActivity: FamilyActivitySelection(),
      blockingStrategyId: NFCBlockingStrategy.id, enableLiveActivity: true,
      reminderTimeInSeconds: 3600
    )
    context.insert(profile)

    let data = profile.cardData

    XCTAssertEqual(data.id, profile.id)
    XCTAssertEqual(data.name, "Work")
    XCTAssertTrue(data.enableLiveActivity)
    XCTAssertTrue(data.hasReminders)                 // reminderTimeInSeconds != nil
    XCTAssertEqual(data.blockingStrategyId, NFCBlockingStrategy.id)
    XCTAssertEqual(data.sessionCount, 0)             // relationship read at build time
    XCTAssertEqual(data.domainsCount, 0)
    XCTAssertFalse(data.isNewerSchemaVersion)        // seeded at currentSchemaVersion
    XCTAssertEqual(data.profileSchemaVersion, BlockedProfiles.currentSchemaVersion)
  }

  // The load-bearing regression assertion: a snapshot taken while the model was VALID
  // must remain readable AFTER the model is deleted + saved (the post-save zombie window
  // that trapped in Phase 0). Values are copies, so no store row is touched.
  @MainActor
  func testGivenCardDataThenModelDeletedAndSaved_ThenValuesStillReadableNoTrap() throws {
    let context = try makeContext()
    let profile = BlockedProfiles(
      id: UUID(), name: "Gaming", selectedActivity: FamilyActivitySelection(),
      blockingStrategyId: QRCodeBlockingStrategy.id
    )
    context.insert(profile)
    try context.save()

    let data = profile.cardData                      // snapshot while valid

    context.delete(profile)
    try context.save()                               // vacate the row (post-save zombie)

    XCTAssertFalse(profile.isPersistentModelValid)   // confirm it IS a zombie now
    XCTAssertEqual(data.name, "Gaming")              // snapshot survives — would trap on `profile.name`
    XCTAssertEqual(data.blockingStrategyId, QRCodeBlockingStrategy.id)
  }
}
```

- [ ] **Step 2: Run to verify it fails**

Boot the sim once: `xcrun simctl list devices available | grep "iPhone 17"` → `xcrun simctl boot <UUID>`.
Run: `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/BlockedProfileCardDataTests | xcpretty`
Expected: FAIL — `value of type 'BlockedProfiles' has no member 'cardData'`.

- [ ] **Step 3: Create the struct + builder** (`Foqos/Components/BlockedProfileCards/BlockedProfileCardData.swift`)

```swift
import FamilyControls
import Foundation

/// Immutable value snapshot of everything the BlockedProfileCard family renders.
/// NOT a SwiftData model — holding a value (never the live `@Model`) is what makes the
/// card crash-proof against a re-render on a deleted profile (see #297). The compiler now
/// forbids handing the card a live model, which is the regression guard.
struct BlockedProfileCardData {
  let id: UUID
  let name: String
  let isNewerSchemaVersion: Bool
  let enableLiveActivity: Bool
  let hasReminders: Bool
  let enableBreaks: Bool
  let enableStrictMode: Bool
  let blockingStrategyId: String?
  let selectedActivity: FamilyActivitySelection
  let sessionCount: Int
  let domainsCount: Int
  let needsAppSelection: Bool

  // ProfileScheduleRow inputs (raw values; the row keeps its own display logic):
  let schedule: BlockedProfileSchedule?
  let startTriggers: ProfileStartTriggers
  let stopConditions: ProfileStopConditions
  let startSchedule: ProfileScheduleTime?
  let stopSchedule: ProfileScheduleTime?
  let strategyData: Data?
  let profileSchemaVersion: Int
  let scheduleIsOutOfSync: Bool
}

extension BlockedProfiles {
  /// Build the card snapshot. MUST be called only on a valid (non-zombie) model — callers
  /// gate via `.valid` / `SafeModelView` before invoking. Reads live attributes/relationships.
  var cardData: BlockedProfileCardData {
    BlockedProfileCardData(
      id: id,
      name: name,
      isNewerSchemaVersion: isNewerSchemaVersion,
      enableLiveActivity: enableLiveActivity,
      hasReminders: reminderTimeInSeconds != nil,
      enableBreaks: enableBreaks,
      enableStrictMode: enableStrictMode,
      blockingStrategyId: blockingStrategyId,
      selectedActivity: selectedActivity,
      sessionCount: sessions.count,
      domainsCount: domains?.count ?? 0,
      needsAppSelection: needsAppSelection,
      schedule: schedule,
      startTriggers: startTriggers,
      stopConditions: stopConditions,
      startSchedule: startSchedule,
      stopSchedule: stopSchedule,
      strategyData: strategyData,
      profileSchemaVersion: profileSchemaVersion,
      scheduleIsOutOfSync: scheduleIsOutOfSync
    )
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run the same `-only-testing:FoqosTests/BlockedProfileCardDataTests` command. Expected: PASS (both tests).
If Step 3 fails to compile because a field type (e.g. `ProfileScheduleTime`, `BlockedProfileSchedule`) differs from Task 0, fix the field type to match the source of truth in `BlockedProfiles.swift` and re-run.

- [ ] **Step 5: Commit**

```bash
git add Foqos/Components/BlockedProfileCards/BlockedProfileCardData.swift FoqosTests/BlockedProfileCardDataTests.swift
git commit -m "feat(#297): BlockedProfileCardData value snapshot + builder"
```

---

## Task 2: Convert `ProfileScheduleRow` to the value snapshot

**Files:**
- Modify: `Foqos/Components/BlockedProfileCards/ProfileScheduleRow.swift`
- Test: `FoqosTests/ProfileScheduleRowDataTests.swift`

**Interfaces:**
- Consumes: `BlockedProfileCardData` (Task 1).
- Produces: `ProfileScheduleRow(data: BlockedProfileCardData, isActive: Bool)` — Task 3 calls this.

- [ ] **Step 1: Write the failing test** — assert the schedule display logic is unchanged when sourced from `cardData` instead of the live model.

```swift
import SwiftData
import XCTest

@testable import FamilyFoqos

final class ProfileScheduleRowDataTests: XCTestCase {
  @MainActor
  func testGivenLegacyScheduleProfile_WhenCardData_ThenScheduleFlagsMatchModel() throws {
    let container = try ModelContainer(
      for: BlockedProfiles.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = container.mainContext
    let profile = BlockedProfiles(
      name: "Sched", blockingStrategyId: NFCBlockingStrategy.id,
      schedule: .init(days: [.monday, .friday], startHour: 9, startMinute: 0,
        endHour: 17, endMinute: 0, updatedAt: Date()))
    context.insert(profile)

    let data = profile.cardData
    // The row's inputs must equal the model's — proves the snapshot carries schedule state.
    XCTAssertEqual(data.schedule?.isActive, profile.schedule?.isActive)
    XCTAssertEqual(data.scheduleIsOutOfSync, profile.scheduleIsOutOfSync)
    XCTAssertEqual(data.profileSchemaVersion, profile.profileSchemaVersion)
    XCTAssertEqual(data.blockingStrategyId, profile.blockingStrategyId)
  }
}
```

- [ ] **Step 2: Run to verify it fails** (`-only-testing:FoqosTests/ProfileScheduleRowDataTests`). Expected: PASS-compile only after Task 1; if `cardData` missing it FAILs to build — that means Task 1 wasn't merged; stop and fix. Otherwise it should PASS immediately (it only exercises the builder). This test guards the field wiring for the row; the behavior change is in Step 3.

- [ ] **Step 3: Convert the view.** In `ProfileScheduleRow.swift`, replace `let profile: BlockedProfiles` with `let data: BlockedProfileCardData`, and repoint every `profile.X` read to `data.X`. Exact replacements (all other lines unchanged):

```swift
struct ProfileScheduleRow: View {
  let data: BlockedProfileCardData
  let isActive: Bool

  private var hasLegacySchedule: Bool { data.schedule?.isActive == true }

  private var hasV2Schedule: Bool {
    let hasStart = data.startTriggers.schedule && data.startSchedule?.isActive == true
    let hasStop = data.stopConditions.schedule && data.stopSchedule?.isActive == true
    return hasStart || hasStop
  }

  private var hasSchedule: Bool { hasLegacySchedule || hasV2Schedule }

  private var isTimerStrategy: Bool {
    if data.stopConditions.timer { return true }
    if data.profileSchemaVersion < 2 {
      let id = data.blockingStrategyId
      return id == NFCTimerBlockingStrategy.id
        || id == QRTimerBlockingStrategy.id
        || id == ShortcutTimerBlockingStrategy.id
    }
    return false
  }

  private var timerDuration: Int? {
    guard let strategyData = data.strategyData else { return nil }
    let timerData = StrategyTimerData.toStrategyTimerData(from: strategyData)
    return timerData.durationInMinutes
  }
  // daysLine / timeLine / body: replace `profile.` with `data.` everywhere; `profile.scheduleIsOutOfSync`
  // becomes `data.scheduleIsOutOfSync`. formattedTimeString and the body layout are unchanged.
}
```

Also update the file's `#Preview` to build via a profile's `cardData` (e.g. `ProfileScheduleRow(data: BlockedProfiles(name: "Test", …).cardData, isActive: false)`).

- [ ] **Step 4: Run to verify it passes** — `-only-testing:FoqosTests/ProfileScheduleRowDataTests` PASS, and the target still builds (the row no longer references `profile`).

- [ ] **Step 5: Commit**

```bash
git add Foqos/Components/BlockedProfileCards/ProfileScheduleRow.swift FoqosTests/ProfileScheduleRowDataTests.swift
git commit -m "refactor(#297): ProfileScheduleRow renders from BlockedProfileCardData"
```

---

## Task 3: Convert `BlockedProfileCard` to the value snapshot

**Files:**
- Modify: `Foqos/Components/BlockedProfileCards/BlockedProfileCard.swift`

**Interfaces:**
- Consumes: `BlockedProfileCardData` (Task 1), `ProfileScheduleRow(data:isActive:)` (Task 2).
- Produces: `BlockedProfileCard(data: BlockedProfileCardData, isActive: … , onStartTapped: …, …)` — the `on*Tapped` closures and other scalar params are **unchanged**. Task 4 calls this.

- [ ] **Step 1: Change the stored property.** Replace `let profile: BlockedProfiles` with `let data: BlockedProfileCardData`. Leave all other stored properties (`isActive`, `elapsedTime`, the `on*Tapped` closures, break/one-more-minute flags) exactly as they are.

- [ ] **Step 2: Repoint every body read** `profile.X → data.X`:
  - `Text(data.name)`
  - `ProfileIndicators(enableLiveActivity: data.enableLiveActivity, hasReminders: data.hasReminders, enableBreaks: data.enableBreaks, enableStrictMode: data.enableStrictMode)` (note: `hasReminders` is now a precomputed field, replacing `profile.reminderTimeInSeconds != nil`)
  - every `data.isNewerSchemaVersion` (Menu, the if/else branch selector, the app-selection banner, the timer-button guard)
  - `StrategyInfoView(strategyId: data.blockingStrategyId)`
  - `ProfileScheduleRow(data: data, isActive: isActive)`
  - `ProfileStatsRow(selectedActivity: data.selectedActivity, sessionCount: data.sessionCount, domainsCount: data.domainsCount)`
  - `if data.needsAppSelection && !data.isNewerSchemaVersion { … }`

- [ ] **Step 3: Update the `#Preview`** to construct cards via `.cardData` (build in-memory `BlockedProfiles` then pass `.cardData`), since the initializer no longer takes a live model.

- [ ] **Step 4: Verify it builds** (no card-family unit test — a `View` body isn't unit-testable here; the compile is the check and the runtime safety is proven by Task 1's zombie test + Task 5 + the device gate).

Run: `xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug -destination 'generic/platform=iOS Simulator' build | xcpretty`
Expected: `BUILD SUCCEEDED` (this fails until Task 4 updates the carousel call site — that is expected; do Task 4 before committing, or comment the carousel temporarily. Recommended: proceed to Task 4 and commit Tasks 3+4 together.)

- [ ] **Step 5: (deferred to Task 4 for a compiling commit).**

---

## Task 4: Build the snapshot in `BlockedProfileCarousel` (behind the validity gate) + frame-preserving placeholder

**Files:**
- Modify: `Foqos/Components/BlockedProfileCards/BlockedProfileCarousel.swift`
- Modify: `Foqos/Utils/SafeModelView.swift` (add optional frame-preserving placeholder; backward-compatible)

**Interfaces:**
- Consumes: `BlockedProfileCard(data:…)` (Task 3), `BlockedProfiles.cardData` (Task 1).

- [ ] **Step 1: Add an optional placeholder to `SafeModelView`** (default keeps every existing call site identical):

```swift
struct SafeModelView<Model: PersistentModel, Content: View, Placeholder: View>: View {
  let model: Model
  let content: (Model) -> Content
  let placeholder: () -> Placeholder

  init(_ model: Model, @ViewBuilder content: @escaping (Model) -> Content,
       @ViewBuilder placeholder: @escaping () -> Placeholder = { EmptyView() }) {
    self.model = model
    self.content = content
    self.placeholder = placeholder
  }

  var body: some View {
    if model.isPersistentModelValid { content(model) } else { placeholder() }
  }
}
```

(The default `Placeholder = EmptyView` type parameter must be inferable; if the generic default causes call-site inference errors at other `SafeModelView` sites found in Task 0 Step 5, add an explicit convenience overload rather than changing those sites.)

- [ ] **Step 2: Build the snapshot inside the valid branch and pass a frame-preserving placeholder** (`BlockedProfileCarousel.swift`, the `ForEach(validProfiles)`):

```swift
ForEach(validProfiles) { profile in
  SafeModelView(profile) { profile in
    BlockedProfileCard(
      data: profile.cardData,                       // built ONLY on a valid model
      isActive: profile.id == activeSessionProfileId,
      isBreakAvailable: isBreakAvailable,
      isBreakActive: isBreakActive,
      isBreakOpenRawFields: isBreakOpenRawFields,
      elapsedTime: elapsedTime,
      onStartTapped: { onStartTapped(profile) },     // closures unchanged (carousel scope)
      onStopTapped: { onStopTapped(profile) },
      onEditTapped: { onEditTapped(profile) },
      onStatsTapped: { onStatsTapped(profile) },
      onBreakTapped: { onBreakTapped(profile) },
      onAppSelectionTapped: { onAppSelectionTapped(profile) },
      isOneMoreMinuteActive: isOneMoreMinuteActive,
      isOneMoreMinuteAvailable: isOneMoreMinuteAvailable,
      oneMoreMinuteStartTime: oneMoreMinuteStartTime,
      onOneMoreMinuteTapped: { onOneMoreMinuteTapped(profile) }
    )
  } placeholder: {
    // Frame-preserving: keep the carousel from collapsing during the brief teardown window.
    Color.clear
  }
  .containerRelativeFrame(.horizontal)
}
```

(The `.containerRelativeFrame(.horizontal)` + the ScrollView's `.frame(height: cardHeight)` size the placeholder, satisfying the frame-preserving ruling.)

- [ ] **Step 3: Build the whole app**

Run: `xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug -destination 'generic/platform=iOS Simulator' build | xcpretty`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run the full card-family test set + the suite**

Run: `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty`
Expected: all green, including `BlockedProfileCardDataTests` and `ProfileScheduleRowDataTests`.

- [ ] **Step 5: Commit Tasks 3 + 4 together**

```bash
git add Foqos/Components/BlockedProfileCards/BlockedProfileCard.swift \
        Foqos/Components/BlockedProfileCards/BlockedProfileCarousel.swift \
        Foqos/Utils/SafeModelView.swift
git commit -m "refactor(#297): BlockedProfileCard renders from value snapshot; carousel builds it behind the validity gate"
```

---

## Task 5: Regression guard — type-signature-as-test (explicit) + doc

**Files:**
- Modify: `Foqos/Components/BlockedProfileCards/BlockedProfileCardData.swift` (doc comment already added in Task 1; extend it)
- Test: `FoqosTests/BlockedProfileCardDataTests.swift` (add the explicit regression assertion)

**The regression test IS the type signature.** After this PR, `BlockedProfileCard.init` and `ProfileScheduleRow.init` accept only `BlockedProfileCardData` (a value type) — there is no parameter through which a live `BlockedProfiles` `@Model` can be passed to the card family, so the #297 crash class cannot be reintroduced without a compile error. This is the primary guard; make it explicit in the plan and code.

- [ ] **Step 1: Add an explicit note** at the top of `BlockedProfileCardData.swift`:

```swift
// REGRESSION GUARD (#297): BlockedProfileCard / ProfileScheduleRow accept ONLY this value type.
// They can no longer hold a live BlockedProfiles @Model, so a re-render can never read a
// vacated store row. Reintroducing `let profile: BlockedProfiles` on those views is a
// compile-time-visible regression. The runtime proof is
// BlockedProfileCardDataTests.testGivenCardDataThenModelDeletedAndSaved_ThenValuesStillReadableNoTrap.
```

- [ ] **Step 2: Confirm the runtime regression test exists** (added in Task 1, Step 1: `testGivenCardDataThenModelDeletedAndSaved_ThenValuesStillReadableNoTrap`). It reproduces the exact Phase 0 window — snapshot taken while valid, then model deleted+saved (post-save zombie) — and asserts the snapshot's values are still readable (a live-model read would trap here). Verify it is present and passing.

> **Why the prior tests missed this:** #285's central-predicate and parent-guard tests asserted the *predicate/filter* behavior, never the **post-commit re-render of an already-mounted child** on a vacated row. This task's runtime test exercises exactly that window (delete + save, then read the snapshot that a live model would have trapped on), and the type change makes the whole class unrepresentable.

- [ ] **Step 3: Run the full suite once more** (same command as Task 4 Step 4). Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add Foqos/Components/BlockedProfileCards/BlockedProfileCardData.swift FoqosTests/BlockedProfileCardDataTests.swift
git commit -m "test(#297): document type-signature regression guard + zombie-snapshot runtime test"
```

---

## Final verification (whole PR)

- [ ] Full suite green on the booted sim (UUID destination).
- [ ] `swift-format lint --recursive .` clean.
- [ ] `grep -rn "let profile: BlockedProfiles" Foqos/Components/BlockedProfileCards` returns **nothing** (card family holds no live model).
- [ ] **DEVICE GATE (required before merge, per decision):** on a physical device, **no debugger** (Scheme → Run → Debugger: None; lldb masks the `EXC_BREAKPOINT`), run the exact repro from #297 — with the Home carousel visible, delete a profile via Manage → Edit/Move minus-delete AND swipe-delete, both when it is the last profile (reorder count 0) and one of several (count > 0), ≥10 cycles. Expected: **zero crashes.** Capture an exported log (Settings footer must show a real commit SHA, no `+wip`) attached to the PR.
- [ ] Request code review (AGENTS.md: review before merge). Reference #297; note #298 is the out-of-scope follow-up.

## Out of scope (do NOT do here)
- The other latent live-`@Model` child views (`LockedProfileCard`, `ProfileRow`, `SessionRow`, `SavedLocationCard`, `LocationReferenceRow`) — tracked in **#298**.
- The Phase 0 probe branch instrumentation — reference only; not part of this PR.
- Any `#289`/`#296` sync-layer change — the timeline showed a latent #289 race; the snapshot fix is UI-layer and trigger-agnostic, so no sync change is needed (attribution probe skipped by decision).

## Self-review checklist (planner ran this)
- **Spec coverage:** Option C (snapshot) ✓ (Tasks 1–4); frame-preserving placeholder ✓ (Task 4 Step 2); twins → follow-up ✓ (#298, Out of scope); skip attribution probe ✓ (Out of scope); type-signature-as-regression-test explicit ✓ (Task 5); device gate before merge ✓ (Final verification).
- **Placeholder scan:** every code step shows real code; field types copied from `BlockedProfiles.swift`.
- **Type consistency:** `cardData` / `BlockedProfileCardData` / `ProfileScheduleRow(data:isActive:)` / `BlockedProfileCard(data:…)` used consistently across Tasks 1–5.
- **Known soft spot to verify during Task 0/1:** `FamilyActivitySelection` and the schedule/trigger types are used by value; if any is not `Sendable`/usable in a struct field as written, keep the field (structs can hold non-Sendable values) and only adjust if the compiler objects. `BlockedProfileCardData` is intentionally **not** `Equatable` to avoid forcing conformance on `FamilyActivitySelection`/trigger types.
