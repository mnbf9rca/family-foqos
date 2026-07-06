# Bundle F — Zombie-Model Safety in Secondary Views Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop two `EXC_BREAKPOINT` zombie-model crashes: `ProfileInsightsUtil`/`ProfileInsightsView` dereferencing a `BlockedProfiles` that was deleted (e.g. via CloudKit sync) while the Insights sheet is open (#213), and `BlockedSessionsHabitTracker` dereferencing `BlockedProfileSession` objects it cached in `@State` after they were cascade-deleted (#235).

**Architecture:** Reuse the codebase's existing three-layer zombie defense — the `.valid` array filter (`Foqos/Utils/Extensions.swift`) and `SafeModelView` render guard (`Foqos/Utils/SafeModelView.swift`). #213: harden the data path in `ProfileInsightsUtil` with a profile-aliveness guard (unit-testable) and wrap the view body in `SafeModelView` for the render path. #235: stop caching model objects in `@State`; derive the day's sessions fresh from the parent's `@SafeQuery`-backed array through a pure, `.valid`-filtering, `now`-injectable static function (unit-testable). No new machinery is invented.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, XCTest. iOS app target module name is `FamilyFoqos`.

**Source commit (current `main` at authoring):** `6ffb8c22b52c4b47da610b978783ccc69774f712`

**Epic:** #263 (defect-audit follow-ups). Bundle F. Issues: #213 (high), #235 (medium).

## Implementation Sequencing (read first)

Bundle **F** and Bundle **I** (app-group UserDefaults migration ordering, #217) are implemented as **two separate, sequential PRs**. **F ships first.** Branch F from `main`; open its PR; after F merges, branch I from the new `main`. Do not develop them in parallel — this repo forbids concurrent build/test streams on one machine (see AGENTS.md "NO parallel development").

## Global Constraints

- Read `AGENTS.md` at the repo root before writing any code. It overrides everything else.
- Work on a feature branch off `main`. **NEVER** amend or force-push; new commits only. Request code review before merging.
- Views must use `@SafeQuery` (never raw `@Query`); non-query model arrays must be filtered with `.valid`.
- Use `Log.<level>(_, category:)` instead of `print()`. Never log lock codes or personal identifiers.
- swift-format is enforced by a pre-commit hook (2-space indent, ~100–120 col). Run `swift-format --in-place --recursive .` before committing if not relying on the hook.
- Tests: name `testGivenX_WhenY_ThenZ()`; pin time — capture **one** `let now = Date()` per test and derive all other dates from it; inject via `now:` parameters.
- Tests import the app module with `@testable import FamilyFoqos`. Use the existing `TestModelContainer.create()` (in-memory `ModelContainer` for `BlockedProfiles`, `BlockedProfileSession`, `SavedLocation`).
- Run tests against an **already-booted** simulator by **UUID** (never device name), reusing one boot:
  ```bash
  xcrun simctl list devices available | grep "iPhone 17"   # pick the UUID once
  xcrun simctl boot <UUID>                                  # once per session (~3-4 min)
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
    -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty
  # Single class:
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
    -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/ClassName | xcpretty
  ```

## Background: why `.valid` alone does not fix #213

`.valid` filters *zombie elements out of an array*. For #235 that is the whole fix (the deleted objects are the `BlockedProfileSession` elements). For #213 the deleted object is the **`BlockedProfiles` itself** — the very expression `profile.sessions` dereferences the deleted model and crashes **before** any `.valid` filter can run. So #213 needs a guard on the *profile's* liveness (`profile.modelContext != nil && !profile.isDeleted`) **before** touching `profile.sessions`, plus `.valid` on the resulting sessions for cascade-deleted children. This is exactly what `SafeModelView` checks at render time; Task F1 mirrors it in the data path so the crash is fixed *and* unit-testable.

## Existing infrastructure (verified on the source commit — do not re-create)

`Foqos/Utils/Extensions.swift:13`:
```swift
extension Array where Element: PersistentModel {
  var valid: [Element] {
    filter { $0.modelContext != nil && !$0.isDeleted }
  }
}
```

`Foqos/Utils/SafeModelView.swift`:
```swift
struct SafeModelView<Model: PersistentModel, Content: View>: View {
  let model: Model
  let content: (Model) -> Content
  init(_ model: Model, @ViewBuilder content: @escaping (Model) -> Content) {
    self.model = model
    self.content = content
  }
  var body: some View {
    if model.modelContext != nil && !model.isDeleted {
      content(model)
    }
  }
}
```

`BlockedProfileSession` (`Foqos/Models/BlockedProfileSessions.swift`) relevant surface:
```swift
init(tag: String, blockedProfile: BlockedProfiles, forceStarted: Bool = false, startTime: Date = Date())
func duration(now: Date = Date()) -> TimeInterval   // endTime ?? now, minus startTime
var startTime: Date; var endTime: Date?; var blockedProfile: BlockedProfiles
```
`BlockedProfiles` convenience init used in tests: `BlockedProfiles(name: "…")` and
`BlockedProfiles(id: UUID(), name: "…", selectedActivity: .init(), blockingStrategyId: "manual")`.

---

## File Structure

- **Modify** `Foqos/Utils/ProfileInsightsUtil.swift` — add profile-aliveness + `.valid` guard; route all 8 `profile.sessions` reads through it (Task F1).
- **Modify** `Foqos/Views/ProfileInsightsView.swift` — wrap the sheet body in `SafeModelView` (Task F2).
- **Modify** `Foqos/Components/Dashboard/BlockedSessionsHabitTracker.swift` — remove the `@State` session cache; add a pure static `sessionsForDate(_:in:now:)` and a `validSessions` computed (Task F3).
- **Create** `FoqosTests/ProfileInsightsUtilTests.swift` — unit tests for F1.
- **Create** `FoqosTests/BlockedSessionsHabitTrackerTests.swift` — unit tests for F3.

---

## Task F1: Harden `ProfileInsightsUtil` against a deleted profile (#213)

**Files:**
- Modify: `Foqos/Utils/ProfileInsightsUtil.swift`
- Test: `FoqosTests/ProfileInsightsUtilTests.swift` (create)

**Interfaces:**
- Consumes: `Array.valid` (`Foqos/Utils/Extensions.swift`), `BlockedProfiles`, `BlockedProfileSession`.
- Produces: unchanged public surface of `ProfileInsightsUtil` — `init(profile:)`, `metrics`, `refresh()`, `setDateRange(start:end:)`, `dailyAggregates(days:endingOn:)`, `hourlyAggregates(days:endingOn:)`, `breakDailyAggregates`, `breakHourlyAggregates`, `sessionEndHourlyAggregates`, `breakStartHourlyAggregates`, `breakEndHourlyAggregates`. Behavior change: every aggregation now returns empty/zero when the profile is a zombie, instead of crashing.

- [ ] **Step 1: Write the failing tests**

Create `FoqosTests/ProfileInsightsUtilTests.swift`:

```swift
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class ProfileInsightsUtilTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!

  override func setUp() async throws {
    try await super.setUp()
    container = try TestModelContainer.create()
    context = container.mainContext
  }

  override func tearDown() async throws {
    container = nil
    context = nil
    try await super.tearDown()
  }

  private func makeProfileWithCompletedSession(now: Date) throws -> BlockedProfiles {
    let profile = BlockedProfiles(
      id: UUID(), name: "Insights", selectedActivity: .init(), blockingStrategyId: "manual")
    context.insert(profile)
    let session = BlockedProfileSession(
      tag: "s", blockedProfile: profile, startTime: now.addingTimeInterval(-3600))
    session.endTime = now.addingTimeInterval(-1800)
    context.insert(session)
    try context.save()
    return profile
  }

  func testGivenLiveProfileWithSession_WhenInit_ThenCountsCompletedSession() throws {
    let now = Date()
    let profile = try makeProfileWithCompletedSession(now: now)

    let util = ProfileInsightsUtil(profile: profile)

    XCTAssertEqual(util.metrics.totalCompletedSessions, 1)
  }

  func testGivenProfileDeletedAfterInit_WhenRefreshAndAggregate_ThenReturnsEmptyWithoutCrashing()
    throws
  {
    let now = Date()
    let profile = try makeProfileWithCompletedSession(now: now)
    let util = ProfileInsightsUtil(profile: profile)
    XCTAssertEqual(util.metrics.totalCompletedSessions, 1, "precondition: alive")

    // Profile is deleted (e.g. a remote CloudKit deletion) while the sheet retains `util`.
    context.delete(profile)

    // None of these may crash; all must return empty/zero.
    util.refresh()
    XCTAssertEqual(util.metrics.totalCompletedSessions, 0)
    XCTAssertEqual(util.metrics.totalFocusTime, 0)
    XCTAssertTrue(util.dailyAggregates(days: 14, endingOn: now).allSatisfy { $0.sessionsCount == 0 })
    XCTAssertTrue(
      util.hourlyAggregates(days: 14, endingOn: now).allSatisfy { $0.sessionsStarted == 0 })
    XCTAssertTrue(
      util.breakDailyAggregates(days: 14, endingOn: now).allSatisfy { $0.breaksCount == 0 })
    XCTAssertTrue(
      util.sessionEndHourlyAggregates(days: 14, endingOn: now).allSatisfy { $0.sessionsEnded == 0 })
  }

  func testGivenOneCascadeDeletedSession_WhenInit_ThenExcludesZombieSession() throws {
    let now = Date()
    let profile = BlockedProfiles(
      id: UUID(), name: "Insights", selectedActivity: .init(), blockingStrategyId: "manual")
    context.insert(profile)
    let live = BlockedProfileSession(
      tag: "live", blockedProfile: profile, startTime: now.addingTimeInterval(-3600))
    live.endTime = now.addingTimeInterval(-1800)
    let zombie = BlockedProfileSession(
      tag: "zombie", blockedProfile: profile, startTime: now.addingTimeInterval(-3600))
    zombie.endTime = now.addingTimeInterval(-1800)
    context.insert(live)
    context.insert(zombie)
    try context.save()

    context.delete(zombie)

    let util = ProfileInsightsUtil(profile: profile)
    XCTAssertEqual(util.metrics.totalCompletedSessions, 1)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' \
  -only-testing:FoqosTests/ProfileInsightsUtilTests | xcpretty
```
Expected: `testGivenProfileDeletedAfterInit_…` **crashes / fails** (an `EXC_BREAKPOINT` or a non-zero count) because `refresh()` → `computeMetrics` dereferences `profile.sessions` on the deleted model. `testGivenOneCascadeDeletedSession_…` fails with count `2` (zombie not filtered). The live-profile test passes.

- [ ] **Step 3: Add the aliveness + `.valid` guard**

In `Foqos/Utils/ProfileInsightsUtil.swift`, insert these two members immediately after the `refresh()` method (after the closing brace of `refresh()`, before `private static func computeMetrics`):

```swift
  /// Zombie-safe access to the profile's sessions. Returns `[]` when the profile has been
  /// deleted (e.g. via CloudKit sync) while this util is retained by an open sheet — accessing
  /// `profile.sessions` on a deleted model raises EXC_BREAKPOINT (#213). Also `.valid`-filters
  /// any individually cascade-deleted sessions. Mirrors the SafeModelView render guard in the
  /// data path so the fix is unit-testable. See AGENTS.md (@SafeQuery / `.valid`).
  private static func validSessions(of profile: BlockedProfiles) -> [BlockedProfileSession] {
    guard profile.modelContext != nil && !profile.isDeleted else { return [] }
    return profile.sessions.valid
  }

  private var validSessions: [BlockedProfileSession] {
    Self.validSessions(of: profile)
  }
```

- [ ] **Step 4: Route all 8 `profile.sessions` reads through the guard**

Make these exact replacements in `Foqos/Utils/ProfileInsightsUtil.swift`. Each currently reads `profile.sessions.filter { … }`; there are 8 occurrences.

In `computeMetrics` (a `static` method — call the static helper):
```swift
    let completed = validSessions(of: profile).filter { session in
```

In each of the seven **instance** methods, replace `profile.sessions.filter` with `validSessions.filter`. The binding names are unchanged:

- `dailyAggregates` → `let completed = validSessions.filter { session in`
- `hourlyAggregates` → `let completed = validSessions.filter { session in`
- `breakDailyAggregates` → `let sessionsWithBreaks = validSessions.filter { session in`
- `breakHourlyAggregates` → `let sessionsWithBreaks = validSessions.filter { session in`
- `sessionEndHourlyAggregates` → `let completedSessions = validSessions.filter { session in`
- `breakStartHourlyAggregates` → `let sessionsWithBreaks = validSessions.filter { session in`
- `breakEndHourlyAggregates` → `let sessionsWithCompletedBreaks = validSessions.filter { session in`

After this step there must be **zero** remaining `profile.sessions` occurrences in this file. Verify:
```bash
grep -n "profile.sessions" Foqos/Utils/ProfileInsightsUtil.swift   # expect: no output
```

- [ ] **Step 5: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' \
  -only-testing:FoqosTests/ProfileInsightsUtilTests | xcpretty
```
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Foqos/Utils/ProfileInsightsUtil.swift FoqosTests/ProfileInsightsUtilTests.swift
git commit -m "fix(#213): guard ProfileInsightsUtil against deleted profile"
```

---

## Task F2: Guard `ProfileInsightsView` render path with `SafeModelView` (#213)

**Files:**
- Modify: `Foqos/Views/ProfileInsightsView.swift`

**Interfaces:**
- Consumes: `SafeModelView` (`Foqos/Utils/SafeModelView.swift`), `viewModel.profile`.
- Produces: no API change. When the profile is deleted while the sheet is open, the body renders nothing (the close button stays available) instead of crashing.

**Why (not covered by F1):** `ProfileInsightsView.nerdStatsItems` reads `viewModel.profile` properties **directly** (`profile.createdAt`, `profile.updatedAt`, `profile.id`, `profile.selectedActivity`, `profile.sessions.count`, `profile.activeScheduleTimerActivity`) — these bypass `ProfileInsightsUtil`, so F1 does not cover them. Wrapping the body in `SafeModelView` is the codebase's documented render-time guard (layer 3). This view is presented as a `.sheet` from `HomeView.swift:319` and `BlockedProfileView.swift:703` with no `SafeModelView`, unlike sibling session views.

> **No unit test for this task.** A SwiftUI sheet body is not unit-testable here; `SafeModelView`'s guard is already covered by `FoqosTests/SafeModelViewTests.swift` (`testSafeModelViewWithDeletedModel`). F1's tests cover the data-path regression. F2 is a mechanical, inspection-verified application of the existing guard. Verification is a clean build (Step 3).

- [ ] **Step 1: Wrap the body content in `SafeModelView`**

In `Foqos/Views/ProfileInsightsView.swift`, the `body` currently is `NavigationStack { ScrollView { … } .background(…) .navigationTitle("Stats for Nerds") .toolbar { … } }`.

Change **only** the opening: replace
```swift
  var body: some View {
    NavigationStack {
      ScrollView {
```
with
```swift
  var body: some View {
    NavigationStack {
      SafeModelView(viewModel.profile) { _ in
        ScrollView {
```

Then close the new `SafeModelView` closure by moving the brace: the block currently ends as
```swift
      }
      .background(Color(.systemGroupedBackground).ignoresSafeArea())
      .navigationTitle("Stats for Nerds")
      .toolbar {
```
Replace that with
```swift
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
      }
      .navigationTitle("Stats for Nerds")
      .toolbar {
```

Net effect: `SafeModelView(viewModel.profile) { _ in ScrollView { … }.background(…) }` becomes the `NavigationStack`'s content, and `.navigationTitle`/`.toolbar` (with the Close button) stay on the `SafeModelView` so the user can always dismiss even when the profile is gone. Leave the entire inner `VStack` (all chart cards, lines ~15–452 of the original body) **exactly as-is** — only the two brace/indent boundaries above change. Re-run swift-format to normalize the added indentation level:
```bash
swift-format --in-place Foqos/Views/ProfileInsightsView.swift
```

- [ ] **Step 2: Verify it builds**

Run:
```bash
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug build 2>&1 | xcpretty
```
Expected: BUILD SUCCEEDED. (Optionally re-run the F1 test class to confirm nothing regressed.)

- [ ] **Step 3: Commit**

```bash
git add Foqos/Views/ProfileInsightsView.swift
git commit -m "fix(#213): guard ProfileInsightsView render with SafeModelView"
```

---

## Task F3: Stop `BlockedSessionsHabitTracker` caching sessions in `@State` (#235)

**Files:**
- Modify: `Foqos/Components/Dashboard/BlockedSessionsHabitTracker.swift`
- Test: `FoqosTests/BlockedSessionsHabitTrackerTests.swift` (create)

**Interfaces:**
- Consumes: `Array.valid`, `BlockedProfileSession.duration(now:)`, the `sessions: [BlockedProfileSession]` input (passed by `HomeView.swift:164` from a `@SafeQuery`-backed `recentCompletedSessions`).
- Produces: new **internal static** `BlockedSessionsHabitTracker.sessionsForDate(_ date: Date, in sessions: [BlockedProfileSession], now: Date) -> [BlockedProfileSession]` (pure, `.valid`-filtering, `now`-injectable — the unit-testable seam). Removes the `@State selectedSessions` cache; `selectedDate` + `showingSessionDetails` remain.

**Root cause:** `handleDateTap` stored `selectedSessions = sessionsForDate(date)` in `@State`. Because `@State` persists across re-renders (stable view identity), that snapshot outlives deletion of the underlying `BlockedProfileSession` objects (profile deletion cascades to its sessions — `BlockedProfiles.deleteProfile` deletes every session). The next render then reads `session.blockedProfile.name` on a zombie → `EXC_BREAKPOINT`. Fix: never cache; derive the day's sessions fresh from the always-current `sessions` input each render, `.valid`-filtered.

- [ ] **Step 1: Write the failing tests**

Create `FoqosTests/BlockedSessionsHabitTrackerTests.swift`:

```swift
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class BlockedSessionsHabitTrackerTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!

  override func setUp() async throws {
    try await super.setUp()
    container = try TestModelContainer.create()
    context = container.mainContext
  }

  override func tearDown() async throws {
    container = nil
    context = nil
    try await super.tearDown()
  }

  func testGivenDeletedSession_WhenSessionsForDate_ThenExcludesZombieWithoutCrashing() throws {
    let now = Date()
    let calendar = Calendar.current
    let dayStart = calendar.startOfDay(for: now)
    let profile = BlockedProfiles(
      id: UUID(), name: "P", selectedActivity: .init(), blockingStrategyId: "manual")
    context.insert(profile)
    // Anchor to startOfDay(now) with a fixed endTime so overlap is time-of-day-independent
    // (a `now - 3600` completed session would not overlap today between 00:00 and 01:00).
    let live = BlockedProfileSession(
      tag: "live", blockedProfile: profile, startTime: dayStart.addingTimeInterval(3600))
    live.endTime = dayStart.addingTimeInterval(3600 + 1800)
    let zombie = BlockedProfileSession(
      tag: "zombie", blockedProfile: profile, startTime: dayStart.addingTimeInterval(3600))
    zombie.endTime = dayStart.addingTimeInterval(3600 + 1800)
    context.insert(live)
    context.insert(zombie)
    try context.save()

    context.delete(zombie)

    // Derived from the (now partly-zombie) array — must filter the zombie and not crash on it.
    let result = BlockedSessionsHabitTracker.sessionsForDate(now, in: [live, zombie], now: now)

    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result.first?.tag, "live")
  }

  func testGivenSessionsOverlappingDate_WhenSessionsForDate_ThenReturnsSortedByDurationDescending()
    throws
  {
    let now = Date()
    let calendar = Calendar.current
    let dayStart = calendar.startOfDay(for: now)
    let profile = BlockedProfiles(
      id: UUID(), name: "P", selectedActivity: .init(), blockingStrategyId: "manual")
    context.insert(profile)

    // Short session: 30 min, inside the day.
    let short = BlockedProfileSession(
      tag: "short", blockedProfile: profile, startTime: dayStart.addingTimeInterval(3600))
    short.endTime = dayStart.addingTimeInterval(3600 + 1800)
    // Long session: 2 h, inside the day.
    let long = BlockedProfileSession(
      tag: "long", blockedProfile: profile, startTime: dayStart.addingTimeInterval(7200))
    long.endTime = dayStart.addingTimeInterval(7200 + 7200)
    // Other-day session: excluded.
    let other = BlockedProfileSession(
      tag: "other", blockedProfile: profile,
      startTime: dayStart.addingTimeInterval(-2 * 86400))
    other.endTime = dayStart.addingTimeInterval(-2 * 86400 + 1800)
    context.insert(short)
    context.insert(long)
    context.insert(other)
    try context.save()

    let result = BlockedSessionsHabitTracker.sessionsForDate(
      now, in: [short, long, other], now: now)

    XCTAssertEqual(result.map { $0.tag }, ["long", "short"])
  }

  func testGivenActiveSessionStartedToday_WhenSessionsForDate_ThenIncludedUsingInjectedNow() throws {
    let now = Date()
    let profile = BlockedProfiles(
      id: UUID(), name: "P", selectedActivity: .init(), blockingStrategyId: "manual")
    context.insert(profile)
    // Active session (endTime nil) started one hour ago — overlaps today only via injected `now`.
    let active = BlockedProfileSession(
      tag: "active", blockedProfile: profile, startTime: now.addingTimeInterval(-3600))
    context.insert(active)
    try context.save()

    let result = BlockedSessionsHabitTracker.sessionsForDate(now, in: [active], now: now)

    XCTAssertEqual(result.map { $0.tag }, ["active"])
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' \
  -only-testing:FoqosTests/BlockedSessionsHabitTrackerTests | xcpretty
```
Expected: **compile failure** — `BlockedSessionsHabitTracker.sessionsForDate(_:in:now:)` does not exist yet (the current method is a `private` instance method with a different signature).

- [ ] **Step 3: Remove the `@State` cache**

In `Foqos/Components/Dashboard/BlockedSessionsHabitTracker.swift`, replace:
```swift
  @State private var selectedDate: Date?
  @State private var selectedSessions: [BlockedProfileSession] = []
  @State private var showingSessionDetails = false
```
with:
```swift
  @State private var selectedDate: Date?
  @State private var showingSessionDetails = false
```

- [ ] **Step 4: Replace the instance `sessionsForDate` with a pure static + add `validSessions`**

Replace the whole method (the `/// Gets sessions that have any overlap with the specified date` block):
```swift
  /// Gets sessions that have any overlap with the specified date
  private func sessionsForDate(_ date: Date) -> [BlockedProfileSession] {
    let calendar = Calendar.current
    let dayStart = calendar.startOfDay(for: date)
    guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

    let now = Date()
    return sessions.filter { session in
      let sessionStart = session.startTime
      let sessionEnd = session.endTime ?? now

      // Check if session overlaps with this day
      return sessionStart < dayEnd && sessionEnd > dayStart
    }.sorted { $0.duration(now: now) > $1.duration(now: now) }
  }
```
with:
```swift
  /// The input sessions, defensively `.valid`-filtered to drop any SwiftData zombie models
  /// per AGENTS.md (components receiving model arrays must filter with `.valid`). #235.
  private var validSessions: [BlockedProfileSession] {
    sessions.valid
  }

  /// Sessions that have any overlap with the specified date.
  /// Pure and `now`-injectable so it is unit-testable, and `.valid`-filters zombies *before*
  /// any property access. Derived fresh from `sessions` on every render — never cached in
  /// `@State`, which is the #235 crash (a cached array outlives the models' deletion).
  static func sessionsForDate(
    _ date: Date,
    in sessions: [BlockedProfileSession],
    now: Date
  ) -> [BlockedProfileSession] {
    let calendar = Calendar.current
    let dayStart = calendar.startOfDay(for: date)
    guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

    return sessions.valid.filter { session in
      let sessionStart = session.startTime
      let sessionEnd = session.endTime ?? now

      // Check if session overlaps with this day
      return sessionStart < dayEnd && sessionEnd > dayStart
    }.sorted { $0.duration(now: now) > $1.duration(now: now) }
  }
```

- [ ] **Step 5: Use `validSessions` in the day-square hours calc**

In `sessionHoursForDate(_:)`, replace:
```swift
    let totalSeconds = sessions.reduce(0.0) { total, session in
```
with:
```swift
    let totalSeconds = validSessions.reduce(0.0) { total, session in
```

- [ ] **Step 6: Drop the cache write in `handleDateTap`**

Replace:
```swift
  private func handleDateTap(_ date: Date) {
    let isCurrentlySelected = selectedDate == date

    if isCurrentlySelected {
      // Deselect if already selected
      selectedDate = nil
      selectedSessions = []
      showingSessionDetails = false
    } else {
      // Select a new date
      selectedDate = date
      selectedSessions = sessionsForDate(date)
      showingSessionDetails = true
    }
  }
```
with:
```swift
  private func handleDateTap(_ date: Date) {
    let isCurrentlySelected = selectedDate == date

    if isCurrentlySelected {
      // Deselect if already selected
      selectedDate = nil
      showingSessionDetails = false
    } else {
      // Select a new date — the day's sessions are derived fresh from `sessions` at render
      // time (see sessionDetailsView), never cached in @State (#235).
      selectedDate = date
      showingSessionDetails = true
    }
  }
```

- [ ] **Step 7: Derive the day's sessions at render time**

Replace `sessionDetailsView(for:)`:
```swift
  private func sessionDetailsView(for date: Date) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(formatDate(date))
        .font(.subheadline)
        .fontWeight(.medium)

      if selectedSessions.isEmpty {
        Text("No sessions on this day")
          .font(.caption)
          .foregroundColor(.secondary)
      } else {
        sessionListView(for: date)
      }
    }
    .padding(.top, 8)
    .transition(.move(edge: .bottom).combined(with: .opacity))
    .animation(.easeInOut, value: showingSessionDetails)
  }
```
with:
```swift
  private func sessionDetailsView(for date: Date) -> some View {
    let daySessions = Self.sessionsForDate(date, in: sessions, now: Date())
    return VStack(alignment: .leading, spacing: 10) {
      Text(formatDate(date))
        .font(.subheadline)
        .fontWeight(.medium)

      if daySessions.isEmpty {
        Text("No sessions on this day")
          .font(.caption)
          .foregroundColor(.secondary)
      } else {
        sessionListView(daySessions, for: date)
      }
    }
    .padding(.top, 8)
    .transition(.move(edge: .bottom).combined(with: .opacity))
    .animation(.easeInOut, value: showingSessionDetails)
  }
```

And replace `sessionListView(for:)` so it takes the derived array:
```swift
  private func sessionListView(for date: Date) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      let displayedSessions = Array(selectedSessions.prefix(3))

      ForEach(displayedSessions, id: \.id) { session in
        sessionRowView(for: session, on: date)

        if session != displayedSessions.last {
          Divider()
        }
      }

      if selectedSessions.count > 3 {
        Text("+ \(selectedSessions.count - 3) more sessions")
          .font(.caption)
          .foregroundColor(.secondary)
          .padding(.top, 4)
      }
    }
  }
```
with:
```swift
  private func sessionListView(_ daySessions: [BlockedProfileSession], for date: Date) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      let displayedSessions = Array(daySessions.prefix(3))

      ForEach(displayedSessions, id: \.id) { session in
        sessionRowView(for: session, on: date)

        if session != displayedSessions.last {
          Divider()
        }
      }

      if daySessions.count > 3 {
        Text("+ \(daySessions.count - 3) more sessions")
          .font(.caption)
          .foregroundColor(.secondary)
          .padding(.top, 4)
      }
    }
  }
```

`sessionRowView(for:on:)` is unchanged: it accesses `session.blockedProfile.name`, but `daySessions` is `.valid`-filtered, so every element is a live model (a deleted profile cascade-deletes its sessions, which `.valid` then drops). After this step there must be **no** remaining `selectedSessions` reference. Verify:
```bash
grep -n "selectedSessions" Foqos/Components/Dashboard/BlockedSessionsHabitTracker.swift   # expect: no output
```

- [ ] **Step 8: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' \
  -only-testing:FoqosTests/BlockedSessionsHabitTrackerTests | xcpretty
```
Expected: PASS (3 tests).

- [ ] **Step 9: Commit**

```bash
git add Foqos/Components/Dashboard/BlockedSessionsHabitTracker.swift \
        FoqosTests/BlockedSessionsHabitTrackerTests.swift
git commit -m "fix(#235): derive habit-tracker sessions fresh instead of caching in @State"
```

---

## Final verification (before requesting review)

- [ ] **Full suite green.** Run the whole `FoqosTests` target once (reusing the booted simulator):
  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
    -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty
  ```
  Expected: all existing tests plus the 6 new tests pass; no behavior change outside the two defect sites.
- [ ] **swift-format clean:** `swift-format lint --recursive .` reports no violations for the four changed files.
- [ ] **No stragglers:** `grep -rn "profile.sessions" Foqos/Utils/ProfileInsightsUtil.swift` and `grep -rn "selectedSessions" Foqos/Components/Dashboard/BlockedSessionsHabitTracker.swift` both return nothing.
- [ ] **Request code review** before merging (AGENTS.md requirement). Reference #213 and #235.

## Acceptance criteria (from the handovers)

- #213: The Insights sheet no longer crashes when its profile is deleted (via sync or locally) while open — covered by `ProfileInsightsUtilTests` (data path) + `SafeModelView` wrap (render path).
- #235: The 4-Week Activity day-details panel no longer crashes when the shown sessions/profile are deleted while expanded — covered by `BlockedSessionsHabitTrackerTests` and the removal of `@State` caching.
- Regression tests exist in `FoqosTests` (naming `testGivenX_WhenY_ThenZ`, injected `now:`).
- No behavior change outside the defects' scope; all existing tests pass; swift-format clean; review requested.
