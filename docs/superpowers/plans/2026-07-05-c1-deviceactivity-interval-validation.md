# C1 — DeviceActivity Interval Validation Implementation Plan (#212, #228)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the DeviceActivity intervals that timers and schedules produce *honorable by construction, or visibly rejected at configuration time* — so a session/schedule can never silently fail to fire because the underlying interval was zero-length (24h timer) or shorter than DeviceActivity's 15-minute minimum.

**Architecture:** Three defect surfaces, all rooted in `Foqos/Utils/DeviceActivityCenterUtil.swift`:
1. **#212** — a 24h (1440-minute) timer duration collapses `intervalStart == intervalEnd` (a zero-length window DeviceActivity defers ~24h). Fixed by an upper-bound clamp at the shared interval chokepoint plus tightening the two entry points that can emit 1440 (the duration slider and the Shortcuts intent).
2. **#228 part A** — a combined start+stop schedule whose window is under 15 minutes (same-day *or* the mirror-image cross-midnight near-boundary) throws from `startMonitoring`, is swallowed to a log line, and never registers. Fixed by a **modular** window-length validation surfaced as a save-blocking error.
3. **#228 part B** — a stop-only schedule anchors its interval at 00:00, so any stop time before 00:15 yields a sub-15-minute window that silently fails. Fixed by reshaping the (internally-arbitrary) interval anchor so the window is always honorable while still firing `intervalDidEnd` at the stop time.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, DeviceActivity / FamilyControls / ManagedSettings, XCTest. App target module is `FamilyFoqos`; shared types live in the `FoqosShared` local Swift package.

## Scope

**In scope (C1 = validation & surfacing only):** reject / clamp / reshape intervals DeviceActivity cannot honor, and surface the rejection to the user at configuration time. Covers issues **#212** and **#228** only.

**Explicitly OUT of scope:** building any *enforcement / fallback* mechanism for short intervals (in-app timers that force a session to end when DeviceActivity can't) — that is bundle **C2**, planned separately. No task here may add an alternative stop path or change *when* a stop fires.

**A third, related defect was found during verification and is deliberately deferred — see [Out of Scope: Break-Timer Sub-15 Bug](#out-of-scope-break-timer-sub-15-bug-deferred-tracked-as-214) and [MAINTAINER DECISION 3]. Do not silently "fix" it by clamping the shared chokepoint's lower bound.**

---

## Global Constraints

Copied verbatim from `AGENTS.md`; every task's requirements implicitly include these.

- **Never force-commit, amend, or force-push.** New commits only; use `git revert` to undo. Work on the feature branch `docs/263-c1-interval-validation-plan` is the *plan* branch; **implementation goes on a NEW branch off `main`** (e.g. `fix/263-c1-interval-validation`).
- **Request code review before merging.** Never merge unreviewed.
- **Never use worktrees.** Feature branches only.
- Views must use `@SafeQuery` (never raw `@Query`); non-query `PersistentModel` arrays filtered with `.valid`. *(No view queries are added in this plan.)*
- Lock-code restriction checks must use `appModeManager.currentMode == .child`; the pattern `!= .parent` is forbidden. *(No lock/mode logic is touched in this plan.)*
- Use `Log.<level>(_, category:)` — never `print()`. Never log lock codes or personal identifiers. Timer/schedule logs use `category: .timer`.
- **swift-format** is enforced by a pre-commit hook (2-space indent, ~100–120 col). Run `swift-format --in-place --recursive .` before each commit; `swift-format lint --recursive .` must be clean.
- **Tests:** name `testGivenX_WhenY_ThenZ()`. Pin time — capture one `let now = Date()` per test and inject via `now:` parameters; never call `Date()` more than once per test. Prefer a hardcoded reference date (see existing `TimerIntervalTests.referenceDateAt` / `ProfileScheduleTimeTests`).
- **Numeric limits are single-sourced** in the new `DeviceActivityLimits` enum (Task 1). Never hardcode `15`/`1439`/`1440` in later tasks. In logic, reference the constants directly. In user-facing copy: interpolate the constant in plain-`String` contexts (e.g. the minimum as `\(DeviceActivityLimits.minimumIntervalMinutes)`), and use `DeviceActivityLimits.maximumTimerDescription` for the maximum so it reads as "23 hours 59 minutes" rather than a bare `1439` (humans need meaningful time periods). The one exception is the two `LocalizedStringResource`-backed Intent strings (`IntentError`, `StartProfileIntent`), which must stay string literals so Xcode's string-catalog extraction works — keep those human-readable and manually in sync (the values are framework-fixed).

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

## File Structure

| File | Responsibility | Tasks |
|------|----------------|-------|
| `Foqos/Utils/DeviceActivityLimits.swift` | **NEW.** Single source of truth for DeviceActivity's honorable interval limits (`minimumIntervalMinutes = 15`, `maximumTimerMinutes = 1439`). | 1 |
| `Foqos/Utils/DeviceActivityCenterUtil.swift` | Upper-clamp at `getTimeIntervalStartAndEnd` (#212); new `stopScheduleInterval` helper + rewire `scheduleStopActivity` (#228B). | 1, 5 |
| `Foqos/Components/Strategy/TimerDurationView.swift` | Extract pure `snappedDuration` helper; drop the stray `1440` snap point (#212). | 2 |
| `Foqos/Utils/StrategyManager.swift` | Tighten the Shortcuts-intent duration guard to reject `1440` (#212). | 3 |
| `Foqos/Intents/IntentError.swift`, `Foqos/Intents/StartProfileIntent.swift` | Correct the "15–1440" user-facing copy to "15–1439". | 3 |
| `Foqos/Models/TriggerValidator.swift` | New pure `scheduleWindowMinutes` helper (modular window math). | 4 |
| `Foqos/Models/TriggerConfigurationModel.swift` | Append the sub-15-window validation error in `validate()` (#228A). | 4 |
| `FoqosTests/TimerIntervalTests.swift` | Regression tests for the #212 upper clamp. | 1 |
| `FoqosTests/TimerDurationSnapTests.swift` | **NEW.** Tests for the pure snap helper. | 2 |
| `FoqosTests/StrategyManagerBackgroundTests.swift` | Add the exactly-1440 rejection test. | 3 |
| `FoqosTests/ScheduleWindowValidationTests.swift` | **NEW.** Pure window-math tests + `validate()` integration tests. | 4 |
| `FoqosTests/StopScheduleIntervalTests.swift` | **NEW.** Tests for the reshaped stop-only interval. | 5 |

---

## MAINTAINER DECISIONS (RESOLVED 2026-07-05)

**Resolved by the maintainer (PR #272 review):** 1 → **A**, 2 → **A**, 3 → **defer, tracked as #214**. Each decision below is marked ✅ DECIDED — the recommended option is now the chosen one, and every task is already written against it. The alternatives are retained only as rationale/record; the implementing session should not re-open them.

### MAINTAINER DECISION 1 — #228A: how to surface a sub-15 combined-schedule window (Task 4)
- **(A) Reject at save via `validate()` error — ✅ DECIDED (Task 4 implements this).** Mirrors the existing "Start and stop times can't be the same" rule exactly: the error appears in `triggerConfig.validationErrors`, and `BlockedProfileView.saveProfile()` already blocks the save and shows it in an alert. Least code, consistent, no silent mutation of user intent.
- **(B) Cap the picker inline.** Also add a red footnote + disabled Save in `ScheduleTimePicker` (it already receives `otherScheduleTime`), like the existing `timesMatch` message. Better immediate feedback, but duplicates the 15-minute math in the view and only guards the *second* time edited.
- **(C) Both A and B.** Fullest UX; most code.
- *Rationale for A:* the save-time validation is the authoritative gate (it protects every entry path incl. clone/load), and it is where the "same time" sibling rule already lives. B can be added later as a pure enhancement without reworking A.

### MAINTAINER DECISION 2 — #228B: how to fix the stop-only sub-15 window (Task 5)
- **(A) Reshape the internal interval anchor — ✅ DECIDED (Task 5 implements this).** The user only ever configured a *stop* time; `intervalStart` is an arbitrary internal artifact and `StopScheduleTimerActivity.start(for:)` is a verified no-op, so moving the anchor cannot change what/when anything is enforced. The user's "stop at 00:10" simply *works* instead of failing — nothing to surface. Verified in-scope (validation/reshape, not enforcement).
- **(B) Reject at save.** Add a `validate()` error forbidding a stop-only stop time before 00:15 (and ==00:00). Downsides: exposes an implementation detail ("why can't I stop at 12:10 AM?"), and does not repair already-persisted profiles.
- *Rationale for A:* it eliminates the failure rather than pushing an unintuitive restriction onto the user, and it is the root-cause fix. (No live users exist per project memory, so persisted-data repair is not a concern for either option.)

### MAINTAINER DECISION 3 — Break-timer sub-15 durations (scope)
- **(A) Defer — ✅ DECIDED. Tracked as [#214](https://github.com/mnbf9rca/family-foqos/issues/214) (bundle C2); do NOT file a new issue.** The break-duration picker offers **5 and 10 minutes** (`BlockedProfileView.swift:412-419`), both under DeviceActivity's 15-min floor. A 5/10-min break builds a sub-15 interval through the *same* chokepoint as the strategy timer; its `intervalDidEnd` (which re-applies restrictions) never fires, so the break never ends. This is the same defect class as C1 but is **not** part of issue #212 or #228. It is already tracked by **#214**; the break-*end* re-apply mechanism is separately captured by **#260**. The sub-15 mechanism from this plan has been posted onto #214 for the C2 session — do not expand C1.
- **(B) Pull into C1 now.** Would require deciding break's sub-15 behavior (cap the picker at ≥15, or clamp, or surface) — a UX change to a feature neither issue covers.
- *Rationale for A:* keeping C1 strictly to #212/#228 preserves reviewability; **critically, Task 1's chokepoint clamp is UPPER-BOUND ONLY precisely so it does not silently rewrite a user's 5-min break to 15 min.** See [Out of Scope](#out-of-scope-break-timer-sub-15-bug-deferred-tracked-as-214).

---

## Task 1: Shared limits + #212 upper-clamp at the interval chokepoint

**Files:**
- Create: `Foqos/Utils/DeviceActivityLimits.swift`
- Modify: `Foqos/Utils/DeviceActivityCenterUtil.swift:414-426` (`getTimeIntervalStartAndEnd`)
- Test: `FoqosTests/TimerIntervalTests.swift` (extend existing class)

**Interfaces:**
- Produces: `enum DeviceActivityLimits { static let minimumIntervalMinutes = 15; static let maximumTimerMinutes = 1439 }` — consumed by Tasks 3, 4, 5.
- Produces: `DeviceActivityCenterUtil.getTimeIntervalStartAndEnd(from:now:)` unchanged signature `(from minutes: Int, now: Date = Date()) -> (intervalStart: DateComponents, intervalEnd: DateComponents)`, now internally clamping `minutes` to at most `maximumTimerMinutes`.

**Context / current offending code** (`getTimeIntervalStartAndEnd`, lines 414-426): it derives `intervalEnd = now + minutes` reduced to `hour:minute`. At `minutes == 1440` the end lands on the same wall-clock minute as the start → `intervalStart == intervalEnd`, which DeviceActivity defers ~24h (session ends a day late). Any larger multiple/near-multiple of 1440 collapses similarly. This is the **shared chokepoint** for both `startStrategyTimerActivity` (line 262) and `startBreakTimerActivity` (line 230). Clamp only the **upper** bound (a lower clamp would silently alter break durations — see MAINTAINER DECISION 3).

- [ ] **Step 1: Write the failing tests** — append to `final class TimerIntervalTests` in `FoqosTests/TimerIntervalTests.swift` (uses the existing `referenceDateAt(hour:minute:)` helper):

```swift
  // MARK: - #212 upper-bound clamp (24h zero-length collapse guard)

  func testGiven1440Minutes_WhenComputingInterval_ThenClampedToNonZeroWindow() {
    let now = referenceDateAt(hour: 8, minute: 0)
    let (start, end) = DeviceActivityCenterUtil.getTimeIntervalStartAndEnd(from: 1440, now: now)
    // 24h would collapse to 08:00–08:00; clamp to 1439 → ends 07:59.
    XCTAssertEqual(start.hour, 8)
    XCTAssertEqual(start.minute, 0)
    XCTAssertEqual(end.hour, 7)
    XCTAssertEqual(end.minute, 59)
    XCTAssertFalse(
      start.hour == end.hour && start.minute == end.minute,
      "Interval must never be zero-length"
    )
  }

  func testGiven1439Minutes_WhenComputingInterval_ThenEndIsOneMinuteBeforeStart() {
    let now = referenceDateAt(hour: 8, minute: 0)
    let (start, end) = DeviceActivityCenterUtil.getTimeIntervalStartAndEnd(from: 1439, now: now)
    XCTAssertEqual(start.hour, 8)
    XCTAssertEqual(start.minute, 0)
    XCTAssertEqual(end.hour, 7)
    XCTAssertEqual(end.minute, 59)
  }

  func testGivenMultipleOfDay_WhenComputingInterval_ThenClampedNonZero() {
    let now = referenceDateAt(hour: 8, minute: 0)
    let (start, end) = DeviceActivityCenterUtil.getTimeIntervalStartAndEnd(from: 2880, now: now)
    XCTAssertFalse(start.hour == end.hour && start.minute == end.minute)
    XCTAssertEqual(end.hour, 7)
    XCTAssertEqual(end.minute, 59)
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/TimerIntervalTests | xcpretty`
Expected: `testGiven1440Minutes…` and `testGivenMultipleOfDay…` FAIL (before the clamp, 1440 and 2880 both give end == 08:00). `testGiven1439Minutes…` PASSES.

- [ ] **Step 3: Create `Foqos/Utils/DeviceActivityLimits.swift`**

```swift
import Foundation

/// Hard limits imposed by Apple's DeviceActivity framework on the repeating
/// intervals we register via `DeviceActivityCenter.startMonitoring`.
///
/// DeviceActivity silently rejects (throws from `startMonitoring`, which this
/// codebase currently only logs) any monitored interval shorter than 15
/// minutes, and a 24-hour (1440-minute) now-relative timer collapses to a
/// zero-length interval because its end wraps to the same wall-clock minute as
/// its start. These constants are the single source of truth for the C1
/// interval-validation guards (#212, #228).
enum DeviceActivityLimits {
  /// DeviceActivity's minimum honorable monitored interval length, in minutes.
  static let minimumIntervalMinutes = 15

  /// Maximum now-relative timer duration, in minutes (23h59m). Exactly 1440
  /// (24h), or any larger multiple, makes `intervalStart == intervalEnd`.
  static let maximumTimerMinutes = 1439

  /// Human-readable form of `maximumTimerMinutes` for user-facing copy, derived
  /// from the constant so it can never drift out of sync (e.g. "23 hours 59
  /// minutes").
  static var maximumTimerDescription: String {
    let hours = maximumTimerMinutes / 60
    let minutes = maximumTimerMinutes % 60
    return "\(hours) hours \(minutes) minutes"
  }
}
```

- [ ] **Step 4: Add the upper clamp** — replace the body of `getTimeIntervalStartAndEnd` (lines 414-426) with:

```swift
  static func getTimeIntervalStartAndEnd(from minutes: Int, now: Date = Date()) -> (
    intervalStart: DateComponents, intervalEnd: DateComponents
  ) {
    // Clamp the upper bound so the computed interval can never collapse to a
    // zero-length window: exactly 1440 minutes (24h), or any larger multiple,
    // lands intervalEnd on the same wall-clock minute as intervalStart, which
    // DeviceActivity silently refuses to monitor and defers ~24h (#212).
    // NOTE: the lower bound is intentionally NOT clamped here — that would
    // silently rewrite user-chosen break durations (see MAINTAINER DECISION 3).
    let clampedMinutes = min(minutes, DeviceActivityLimits.maximumTimerMinutes)
    if clampedMinutes != minutes {
      Log.warning(
        "Timer duration \(minutes)m exceeds DeviceActivity's honorable maximum; "
          + "clamped to \(clampedMinutes)m",
        category: .timer
      )
    }

    let calendar = Calendar.current
    let startComponents = calendar.dateComponents([.hour, .minute], from: now)
    let intervalStart = DateComponents(hour: startComponents.hour, minute: startComponents.minute)

    let endDate = now.addingTimeInterval(Double(clampedMinutes) * 60)
    let endComponents = calendar.dateComponents([.hour, .minute], from: endDate)
    let intervalEnd = DateComponents(hour: endComponents.hour, minute: endComponents.minute)

    return (intervalStart: intervalStart, intervalEnd: intervalEnd)
  }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild test … -only-testing:FoqosTests/TimerIntervalTests | xcpretty`
Expected: all `TimerIntervalTests` PASS (existing 4 + new 3).

- [ ] **Step 6: swift-format + commit**

```bash
swift-format --in-place --recursive .
swift-format lint --recursive .
git add Foqos/Utils/DeviceActivityLimits.swift Foqos/Utils/DeviceActivityCenterUtil.swift FoqosTests/TimerIntervalTests.swift
git commit -m "fix(#212): clamp 24h timer to a non-zero DeviceActivity interval at the chokepoint"
```

---

## Task 2: #212 — drop the stray 1440 snap point in the duration slider

**Files:**
- Modify: `Foqos/Components/Strategy/TimerDurationView.swift:21` (snapPoints) and `:174-184` (`snapToNearestPreset`)
- Test: `FoqosTests/TimerDurationSnapTests.swift` (NEW)

**Interfaces:**
- Produces: `static func TimerDurationView.snappedDuration(for:snapPoints:threshold:maxMinutes:) -> Double` — pure, testable. (No consumer outside this file/test.)

**Context / current offending code:** `snapPoints` (line 21) contains `1440` while `maxMinutes` is `1439` (line 16) and `snapThreshold` is `10` (line 22). `snapToNearestPreset()` (lines 174-184) sets `durationMinutes = 1440` whenever the slider is released within 10 of 1440 (value ≥ 1430), pushing the value one minute past the deliberate cap; `handleConfirm` (line 187) then feeds it into `StrategyTimerData`. Task 1 already neutralizes the *behavioral* impact at the chokepoint; this task removes the stray snap point and makes the snap logic guarantee-by-construction that it never exceeds `maxMinutes`.

- [ ] **Step 1: Write the failing tests** — create `FoqosTests/TimerDurationSnapTests.swift`:

```swift
import XCTest

@testable import FamilyFoqos

final class TimerDurationSnapTests: XCTestCase {

  // Mirrors the production snapPoints after the 1440 entry is removed.
  private let snapPoints: [Double] = [15, 30, 45, 60, 90, 120, 180, 240, 360, 480, 720]
  private let maxMinutes: Double = 1439
  private let threshold: Double = 10

  func testGivenValueNearSnapPoint_WhenSnapping_ThenSnapsToIt() {
    let result = TimerDurationView.snappedDuration(
      for: 62, snapPoints: snapPoints, threshold: threshold, maxMinutes: maxMinutes)
    XCTAssertEqual(result, 60)
  }

  func testGivenValueFarFromAnySnapPoint_WhenSnapping_ThenReturnsValue() {
    let result = TimerDurationView.snappedDuration(
      for: 1000, snapPoints: snapPoints, threshold: threshold, maxMinutes: maxMinutes)
    XCTAssertEqual(result, 1000)
  }

  func testGivenValueAtMax_WhenSnapping_ThenNeverExceedsMax() {
    let result = TimerDurationView.snappedDuration(
      for: 1439, snapPoints: snapPoints, threshold: threshold, maxMinutes: maxMinutes)
    XCTAssertEqual(result, 1439)
  }

  func testGivenStraySnapPointAboveMax_WhenSnapping_ThenClampedToMax() {
    // Defense in depth: even with a bad snap point present, the result is capped.
    let result = TimerDurationView.snappedDuration(
      for: 1435, snapPoints: [720, 1440], threshold: threshold, maxMinutes: maxMinutes)
    XCTAssertEqual(result, 1439)
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test … -only-testing:FoqosTests/TimerDurationSnapTests | xcpretty`
Expected: compile failure — `snappedDuration` does not exist yet.

- [ ] **Step 3: Extract the pure helper and remove the 1440 snap point** — in `TimerDurationView.swift`:

Change line 21 (drop `1440`):
```swift
  private let snapPoints: [Double] = [15, 30, 45, 60, 90, 120, 180, 240, 360, 480, 720]
```

Replace `snapToNearestPreset()` (lines 174-184) with a thin wrapper over a pure static helper:
```swift
  /// Returns the snap target for a slider value: the nearest snap point if one is
  /// within `threshold`, otherwise the value itself — always clamped to
  /// `maxMinutes` so the result can never exceed the slider's honorable range (#212).
  static func snappedDuration(
    for value: Double,
    snapPoints: [Double],
    threshold: Double,
    maxMinutes: Double
  ) -> Double {
    guard let closest = snapPoints.min(by: { abs($0 - value) < abs($1 - value) }) else {
      return min(value, maxMinutes)
    }
    let snapped = abs(closest - value) <= threshold ? closest : value
    return min(snapped, maxMinutes)
  }

  private func snapToNearestPreset() {
    let target = Self.snappedDuration(
      for: durationMinutes,
      snapPoints: snapPoints,
      threshold: snapThreshold,
      maxMinutes: maxMinutes
    )
    guard target != durationMinutes else { return }
    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
      durationMinutes = target
    }
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test … -only-testing:FoqosTests/TimerDurationSnapTests | xcpretty`
Expected: all 4 PASS.

- [ ] **Step 5: swift-format + commit**

```bash
swift-format --in-place --recursive .
swift-format lint --recursive .
git add Foqos/Components/Strategy/TimerDurationView.swift FoqosTests/TimerDurationSnapTests.swift
git commit -m "fix(#212): remove stray 1440 slider snap point; clamp snap result to max"
```

---

## Task 3: #212 — reject exactly 1440 at the Shortcuts intent and correct the copy

**Files:**
- Modify: `Foqos/Utils/StrategyManager.swift:359-360` (guard + message)
- Modify: `Foqos/Intents/IntentError.swift:19` (durationOutOfRange string)
- Modify: `Foqos/Intents/StartProfileIntent.swift:20` (description string)
- Test: `FoqosTests/StrategyManagerBackgroundTests.swift` (add one test)

**Interfaces:**
- Consumes: `DeviceActivityLimits` (Task 1).
- No signature changes.

**Context / current offending code:** `startSessionFromBackground` (StrategyManager.swift:358-362) guards `if duration < 15 || duration > 1440` — so `duration == 1440` **passes**, persists to `strategyData`, and starts a timer that (absent Task 1) would defer ~24h. The user-facing copy in three places says "15–1440", advertising the broken value. Change the guard to reject anything above `maximumTimerMinutes` and fix the copy to 1439. (This is redundant with Task 1's clamp behaviorally, but is required for *honest surfacing*: the intent should return a clear error rather than silently run 1439 while reporting "started for 1440 minutes".)

- [ ] **Step 1: Write the failing test** — append to `final class StrategyManagerBackgroundTests` in `FoqosTests/StrategyManagerBackgroundTests.swift` (mirrors the existing `testGivenDurationTooLong…` which uses 1441):

```swift
  func testGivenDurationExactly1440_WhenStartingFromBackground_ThenThrowsDurationOutOfRange() throws {
    let profile = BlockedProfiles(name: "Test")
    context.insert(profile)
    try context.save()

    XCTAssertThrowsError(
      try manager.startSessionFromBackground(
        profile.id, context: context, durationInMinutes: 1440
      )
    ) { error in
      if case IntentError.durationOutOfRange = error {
      } else {
        XCTFail("Expected durationOutOfRange, got \(error)")
      }
    }
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test … -only-testing:FoqosTests/StrategyManagerBackgroundTests | xcpretty`
Expected: `testGivenDurationExactly1440…` FAILS — no error thrown (1440 currently passes the guard and proceeds into `startBlocking`).

- [ ] **Step 3: Tighten the guard and correct the message** — in `StrategyManager.swift` change lines 359-360:

```swift
        if duration < DeviceActivityLimits.minimumIntervalMinutes
          || duration > DeviceActivityLimits.maximumTimerMinutes
        {
          // Plain String → interpolate the min constant and the derived
          // human-readable max (single-sourced; no bare literals).
          self.errorMessage =
            "Duration must be between \(DeviceActivityLimits.minimumIntervalMinutes) minutes "
            + "and \(DeviceActivityLimits.maximumTimerDescription)."
          throw IntentError.durationOutOfRange
        }
```

- [ ] **Step 4: Correct the two remaining copy strings**

These two are `LocalizedStringResource`-backed and must stay string *literals* (so Xcode's string-catalog extraction works) — keep them human-readable rather than interpolating the constants:

`Foqos/Intents/IntentError.swift:19`:
```swift
    case .durationOutOfRange:
      "Duration must be between 15 minutes and 23 hours 59 minutes."
```

`Foqos/Intents/StartProfileIntent.swift:20`:
```swift
    "Start a Family Foqos blocking profile. Optionally specify a timer duration between 15 minutes and 23 hours 59 minutes."
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild test … -only-testing:FoqosTests/StrategyManagerBackgroundTests | xcpretty`
Expected: all PASS — the new 1440 test throws `durationOutOfRange`; the existing 14 / 1441 tests still throw.

- [ ] **Step 6: swift-format + commit**

```bash
swift-format --in-place --recursive .
swift-format lint --recursive .
git add Foqos/Utils/StrategyManager.swift Foqos/Intents/IntentError.swift Foqos/Intents/StartProfileIntent.swift FoqosTests/StrategyManagerBackgroundTests.swift
git commit -m "fix(#212): reject 1440-minute duration at the Shortcuts intent; correct copy to 1439"
```

---

## Task 4: #228A — modular sub-15 window validation for combined start+stop schedules

> **MAINTAINER DECISION 1** governs this task. Steps below implement **Option A (reject-at-save)**, the recommended default. If **Option B/C** is chosen, *also* add a `timesMatch`-style disabled-Save + red footnote in `ScheduleTimePicker.swift` (it already receives `otherScheduleTime`) using the same `scheduleWindowMinutes` helper from Step 3; Option A remains regardless.

**Files:**
- Modify: `Foqos/Models/TriggerValidator.swift` (add a static helper, end of file)
- Modify: `Foqos/Models/TriggerConfigurationModel.swift:60-65` region (append error inside `validate()`)
- Test: `FoqosTests/ScheduleWindowValidationTests.swift` (NEW)

**Interfaces:**
- Consumes: `DeviceActivityLimits` (Task 1).
- Produces: `static func TriggerValidator.scheduleWindowMinutes(startHour:startMinute:stopHour:stopMinute:) -> Int` — modular window length in minutes (0 when identical). Consumed by `TriggerConfigurationModel.validate()` and (if Option B) by `ScheduleTimePicker`.

**Context / current offending code:** `TriggerConfigurationModel.validate()` (lines 60-65) only rejects *identical* start/stop times; `TriggerValidator` has no time-length rule at all. `scheduleTimerActivity` (DeviceActivityCenterUtil.swift:37-70) builds `intervalStart = start`, `intervalEnd = stop`, `repeats: true`, and swallows the `startMonitoring` throw at line 80 (`Log.info`) — so a 09:00→09:10 window (or the mirror-image cross-midnight 23:59→00:00) silently never registers. **The window length is modular**: `((stopMin - startMin) + 1440) % 1440`. This is 10 for 09:00→09:10, **1** for 23:59→00:00 (a near-boundary cross-midnight case that a naive "same-day only" check would miss), and 480 for a legitimate 22:00→06:00 overnight window. Flag `0 < window < 15`; leave `window == 0` to the existing same-time rule.

- [ ] **Step 1: Write the failing tests** — create `FoqosTests/ScheduleWindowValidationTests.swift`:

```swift
import XCTest

@testable import FamilyFoqos

final class ScheduleWindowValidationTests: XCTestCase {

  // MARK: - Pure modular window math

  func testGivenSameDayTenMinuteWindow_WhenComputingWindow_ThenReturnsTen() {
    XCTAssertEqual(
      TriggerValidator.scheduleWindowMinutes(
        startHour: 9, startMinute: 0, stopHour: 9, stopMinute: 10), 10)
  }

  func testGivenSameDayFifteenMinuteWindow_WhenComputingWindow_ThenReturnsFifteen() {
    XCTAssertEqual(
      TriggerValidator.scheduleWindowMinutes(
        startHour: 9, startMinute: 0, stopHour: 9, stopMinute: 15), 15)
  }

  func testGivenCrossMidnightNearBoundary_WhenComputingWindow_ThenReturnsSubFifteen() {
    // 23:59 -> 00:00 is a 1-minute window, NOT ~24h.
    XCTAssertEqual(
      TriggerValidator.scheduleWindowMinutes(
        startHour: 23, startMinute: 59, stopHour: 0, stopMinute: 0), 1)
  }

  func testGivenLegitimateOvernightWindow_WhenComputingWindow_ThenReturns480() {
    XCTAssertEqual(
      TriggerValidator.scheduleWindowMinutes(
        startHour: 22, startMinute: 0, stopHour: 6, stopMinute: 0), 480)
  }

  func testGivenIdenticalTimes_WhenComputingWindow_ThenReturnsZero() {
    XCTAssertEqual(
      TriggerValidator.scheduleWindowMinutes(
        startHour: 9, startMinute: 0, stopHour: 9, stopMinute: 0), 0)
  }
}

@MainActor
final class ScheduleWindowValidationIntegrationTests: XCTestCase {

  private func makeModel(
    startHour: Int, startMinute: Int, stopHour: Int, stopMinute: Int
  ) -> TriggerConfigurationModel {
    let model = TriggerConfigurationModel()
    model.startTriggers.schedule = true
    model.stopConditions.schedule = true
    model.startSchedule = ProfileScheduleTime(
      days: [.monday], hour: startHour, minute: startMinute, updatedAt: .distantPast)
    model.stopSchedule = ProfileScheduleTime(
      days: [.monday], hour: stopHour, minute: stopMinute, updatedAt: .distantPast)
    return model
  }

  func testGivenSubFifteenSameDayWindow_WhenValidating_ThenAppendsWindowError() {
    let model = makeModel(startHour: 9, startMinute: 0, stopHour: 9, stopMinute: 10)
    model.validate()
    XCTAssertTrue(model.validationErrors.contains { $0.contains("at least 15 minutes") })
  }

  func testGivenCrossMidnightSubFifteenWindow_WhenValidating_ThenAppendsWindowError() {
    let model = makeModel(startHour: 23, startMinute: 55, stopHour: 0, stopMinute: 5)
    model.validate()
    XCTAssertTrue(model.validationErrors.contains { $0.contains("at least 15 minutes") })
  }

  func testGivenFifteenMinuteWindow_WhenValidating_ThenNoWindowError() {
    let model = makeModel(startHour: 9, startMinute: 0, stopHour: 9, stopMinute: 15)
    model.validate()
    XCTAssertFalse(model.validationErrors.contains { $0.contains("at least 15 minutes") })
  }

  func testGivenLegitimateOvernightWindow_WhenValidating_ThenNoWindowError() {
    let model = makeModel(startHour: 22, startMinute: 0, stopHour: 6, stopMinute: 0)
    model.validate()
    XCTAssertFalse(model.validationErrors.contains { $0.contains("at least 15 minutes") })
  }
}
```

> If either test class fails to resolve `ProfileScheduleTime` / `Weekday`, add `import FoqosShared` at the top (as `StrategyManagerBackgroundTests.swift` does). `ProfileScheduleTimeTests.swift` currently resolves them with only `@testable import FamilyFoqos`, so the extra import may be unnecessary — but it is harmless if added.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test … -only-testing:FoqosTests/ScheduleWindowValidationTests | xcpretty`
Expected: pure-math tests fail to compile (`scheduleWindowMinutes` missing); once that's added they pass, and the integration tests for sub-15 windows FAIL (no window error appended yet).

- [ ] **Step 3: Add the pure helper** — append to `Foqos/Models/TriggerValidator.swift`:

```swift
extension TriggerValidator {
  /// Length, in minutes, of the repeating DeviceActivity window a start/stop
  /// time pair produces. Computed modulo a 24h day so it is correct for both
  /// same-day windows (stop after start) and cross-midnight windows (stop before
  /// start). Returns 0 when the two times are identical.
  static func scheduleWindowMinutes(
    startHour: Int, startMinute: Int, stopHour: Int, stopMinute: Int
  ) -> Int {
    let startMin = startHour * 60 + startMinute
    let stopMin = stopHour * 60 + stopMinute
    return ((stopMin - startMin) % 1440 + 1440) % 1440
  }
}
```

- [ ] **Step 4: Append the validation error** — in `TriggerConfigurationModel.validate()`, immediately **after** the existing same-time block (the one ending at line 65 that appends "Start and stop times can't be the same"), add:

```swift
    if startTriggers.schedule && stopConditions.schedule,
      let start = startSchedule, let stop = stopSchedule,
      start.isActive, stop.isActive
    {
      let window = TriggerValidator.scheduleWindowMinutes(
        startHour: start.hour, startMinute: start.minute,
        stopHour: stop.hour, stopMinute: stop.minute
      )
      // window == 0 is already reported by the same-time rule above.
      if window > 0 && window < DeviceActivityLimits.minimumIntervalMinutes {
        errors.append(
          "A scheduled window must be at least "
            + "\(DeviceActivityLimits.minimumIntervalMinutes) minutes long"
        )
      }
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild test … -only-testing:FoqosTests/ScheduleWindowValidationTests | xcpretty`
Expected: all pure-math and integration tests PASS.

- [ ] **Step 6: swift-format + commit**

```bash
swift-format --in-place --recursive .
swift-format lint --recursive .
git add Foqos/Models/TriggerValidator.swift Foqos/Models/TriggerConfigurationModel.swift FoqosTests/ScheduleWindowValidationTests.swift
git commit -m "fix(#228): reject sub-15-minute combined schedule windows (modular, incl. cross-midnight)"
```

---

## Task 5: #228B — reshape the stop-only interval anchor so short stop times stay honorable

> **MAINTAINER DECISION 2** governs this task. Steps below implement **Option A (reshape anchor)**, the recommended default. If **Option B (reject-at-save)** is chosen instead, skip this task's production change and instead add — in `TriggerConfigurationModel.validate()` — an error when `stopConditions.schedule && stopSchedule active && !(startTriggers.schedule && startSchedule active)` and `stopSchedule.hour*60+stopSchedule.minute < DeviceActivityLimits.minimumIntervalMinutes` (which also covers stop == 00:00); write the analogous validate() tests instead of the interval tests below.

**Files:**
- Modify: `Foqos/Utils/DeviceActivityCenterUtil.swift:122-124` (inside `scheduleStopActivity`) + add a static helper
- Test: `FoqosTests/StopScheduleIntervalTests.swift` (NEW)

**Interfaces:**
- Consumes: `DeviceActivityLimits` (Task 1).
- Produces: `static func DeviceActivityCenterUtil.stopScheduleInterval(stopHour:stopMinute:) -> (intervalStart: DateComponents, intervalEnd: DateComponents)`.

**Context / current offending code:** `scheduleStopActivity` (lines 101-145) is registered only when a stop schedule is active and start is **not** scheduled (guard line 117). It hardcodes `intervalStart = DateComponents(hour: 0, minute: 0)` (line 123) and `intervalEnd = stop` (line 124), so the window length is `stopHour*60 + stopMinute` minutes — under DeviceActivity's 15-minute floor (or zero-length at stop == 00:00) for any stop before 00:15, and the `startMonitoring` throw is swallowed at lines 139-144 (`Log.error`). **Verified safe to reshape:** `StopScheduleTimerActivity.start(for:)` is an explicit no-op (`Packages/FoqosShared/…/StopScheduleTimerActivity.swift:16-20`) — only `stop(for:)` via `intervalDidEnd` ends the session, and its day-check uses `stopSchedule.isTodayScheduled()` evaluated at fire time (independent of the anchor). So moving `intervalStart` changes nothing observable except making the window honorable. Preserve the 00:00 anchor for stop ≥ 00:15 (no behavior change); for stop < 00:15, anchor one minute *after* the stop so the repeating window wraps ~24h and still fires `intervalDidEnd` at the stop time.

- [ ] **Step 1: Write the failing tests** — create `FoqosTests/StopScheduleIntervalTests.swift`:

```swift
import XCTest

@testable import FamilyFoqos

final class StopScheduleIntervalTests: XCTestCase {

  func testGivenStopBeforeMidnightPlus15_WhenComputingInterval_ThenWindowIsHonorable() {
    let (start, end) = DeviceActivityCenterUtil.stopScheduleInterval(stopHour: 0, stopMinute: 10)
    // Anchor moves to 00:11 so the wrap window is ~1439 min, still ending at 00:10.
    XCTAssertEqual(end.hour, 0)
    XCTAssertEqual(end.minute, 10)
    XCTAssertEqual(start.hour, 0)
    XCTAssertEqual(start.minute, 11)
    XCTAssertFalse(start.hour == end.hour && start.minute == end.minute)
  }

  func testGivenStopAtExactlyMidnight_WhenComputingInterval_ThenNotZeroLength() {
    let (start, end) = DeviceActivityCenterUtil.stopScheduleInterval(stopHour: 0, stopMinute: 0)
    XCTAssertEqual(end.hour, 0)
    XCTAssertEqual(end.minute, 0)
    XCTAssertEqual(start.hour, 0)
    XCTAssertEqual(start.minute, 1)
    XCTAssertFalse(start.hour == end.hour && start.minute == end.minute)
  }

  func testGivenStopAt0015_WhenComputingInterval_ThenKeepsMidnightAnchor() {
    let (start, end) = DeviceActivityCenterUtil.stopScheduleInterval(stopHour: 0, stopMinute: 15)
    XCTAssertEqual(start.hour, 0)
    XCTAssertEqual(start.minute, 0)
    XCTAssertEqual(end.hour, 0)
    XCTAssertEqual(end.minute, 15)
  }

  func testGivenStopMidMorning_WhenComputingInterval_ThenKeepsMidnightAnchor() {
    let (start, end) = DeviceActivityCenterUtil.stopScheduleInterval(stopHour: 9, stopMinute: 0)
    XCTAssertEqual(start.hour, 0)
    XCTAssertEqual(start.minute, 0)
    XCTAssertEqual(end.hour, 9)
    XCTAssertEqual(end.minute, 0)
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test … -only-testing:FoqosTests/StopScheduleIntervalTests | xcpretty`
Expected: compile failure — `stopScheduleInterval` does not exist.

- [ ] **Step 3: Add the helper** — insert this static method in `DeviceActivityCenterUtil` (e.g. directly below `getTimeIntervalStartAndEnd`):

```swift
  /// Computes the DeviceActivity interval for a stop-only schedule.
  ///
  /// The stop-only activity only cares about `intervalDidEnd` firing at the stop
  /// time (`StopScheduleTimerActivity.start(for:)` is a no-op), so `intervalStart`
  /// is a free internal artifact. Anchoring it at 00:00 (the historical default)
  /// yields a window of `stopHour*60 + stopMinute` minutes — under DeviceActivity's
  /// 15-minute minimum, or zero-length when stop == 00:00, whenever the stop time
  /// is before 00:15. In that case we anchor `intervalStart` one minute AFTER the
  /// stop so the repeating window wraps ~24h and still delivers `intervalDidEnd`
  /// at the stop time (#228). For stop times at or after 00:15 the historical
  /// 00:00 anchor is preserved (no behavior change).
  static func stopScheduleInterval(stopHour: Int, stopMinute: Int) -> (
    intervalStart: DateComponents, intervalEnd: DateComponents
  ) {
    let intervalEnd = DateComponents(hour: stopHour, minute: stopMinute)
    let stopMinuteOfDay = stopHour * 60 + stopMinute

    let intervalStart: DateComponents
    if stopMinuteOfDay < DeviceActivityLimits.minimumIntervalMinutes {
      let anchor = (stopMinuteOfDay + 1) % 1440
      intervalStart = DateComponents(hour: anchor / 60, minute: anchor % 60)
    } else {
      intervalStart = DateComponents(hour: 0, minute: 0)
    }
    return (intervalStart: intervalStart, intervalEnd: intervalEnd)
  }
```

- [ ] **Step 4: Rewire `scheduleStopActivity`** — replace lines 122-124 (the `let stopSchedule = …` / `let intervalStart = …` / `let intervalEnd = …` trio) with:

```swift
    let stopSchedule = profile.stopSchedule!
    let (intervalStart, intervalEnd) = stopScheduleInterval(
      stopHour: stopSchedule.hour, stopMinute: stopSchedule.minute
    )
```

(The `DeviceActivitySchedule(intervalStart:intervalEnd:repeats:true)` construction and the surrounding `do/catch` at lines 126-144 are unchanged.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild test … -only-testing:FoqosTests/StopScheduleIntervalTests | xcpretty`
Expected: all 4 PASS.

- [ ] **Step 6: swift-format + commit**

```bash
swift-format --in-place --recursive .
swift-format lint --recursive .
git add Foqos/Utils/DeviceActivityCenterUtil.swift FoqosTests/StopScheduleIntervalTests.swift
git commit -m "fix(#228): reshape stop-only interval anchor so pre-00:15 stop times stay honorable"
```

---

## Final Verification (before opening the PR)

- [ ] **Run the full test suite** (single boot, by UUID):

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty
```
Expected: green, including the pre-existing `TimerIntervalTests`, `ScheduleDurationTests`, `ProfileScheduleTimeTests`, `StrategyManagerBackgroundTests` (the existing 14 / 1441 duration tests must still pass — they are unaffected).

- [ ] **swift-format lint clean:** `swift-format lint --recursive .` → no output.
- [ ] **Manual smoke (optional, on device/sim):** (1) NFC/QR-timer profile → drag duration slider to the far right → confirm it maxes at 23h59m and the session auto-ends. (2) Configure a child profile with schedule start 09:00 / stop 09:10 → Save is blocked with the ≥15-minute error. (3) Manual-start profile with scheduled stop 00:10 → schedule registers and the session stops at 00:10.
- [ ] **Request code review** (AGENTS.md requirement) before merge.
- [ ] Open the PR against `main`; reference issues **#212** and **#228** and epic **#263** (bundle **C1**). Note the three resolved MAINTAINER DECISIONS in the PR body.

---

## Out of Scope: Break-Timer Sub-15 Bug (deferred, tracked as #214)

**Do not fix this in C1.** Documented here so it is not mistaken for "covered."

The break-duration picker (`BlockedProfileView.swift:412-419`) offers **5 / 10 / 15 / 30** minutes. A 5- or 10-minute break flows through `startBreakTimerActivity` → the **same** `getTimeIntervalStartAndEnd` chokepoint (Task 1) → a sub-15-minute `DeviceActivitySchedule`, which `startMonitoring` rejects (swallowed at DeviceActivityCenterUtil.swift:245, `Log.info`). Break-end (re-applying restrictions) relies solely on that activity's `intervalDidEnd`; the in-app `timerTask` loop (`StrategyManager.swift:182-203`) only updates the countdown display. **Net effect: a 5/10-minute break can fail to auto-end, leaving restrictions off.**

This is the same *class* as C1 but belongs to neither #212 nor #228. Per **MAINTAINER DECISION 3 (defer)**, it is **tracked as [#214](https://github.com/mnbf9rca/family-foqos/issues/214) (bundle C2)** — the sub-15 break-start mechanism from this plan has already been posted there for the C2 session; the break-*end* re-apply failure is separately captured by **#260**. The likely C2 fix is "cap the break picker at ≥15 min" or folding break into the C2 fallback architecture. **Task 1 deliberately clamps only the upper bound** so it neither masks nor silently rewrites break durations; adding a lower clamp there would convert every 5-min break into a silent 15-min break and is explicitly rejected.

Also noted but out of scope (V2 combined schedule is #228A's remit): the **legacy** `BlockedProfileSchedule` path (`DeviceActivityCenterUtil.swift:54-59`) builds an interval from `profile.schedule` and is not routed through `TriggerConfigurationModel.validate()`, so a short legacy window would still fail silently. This is deliberately not covered by #228's closure here — that legacy path is slated for removal with **[#59](https://github.com/mnbf9rca/family-foqos/issues/59)** (V1 sunset), so it needs no separate guard.

---

## Self-Review

- **Spec coverage:** #212 → Tasks 1 (chokepoint clamp), 2 (slider snap point), 3 (intent guard + copy). #228A → Task 4 (modular validation, same-day *and* cross-midnight). #228B → Task 5 (stop-only anchor reshape). Scope boundary (no C2 enforcement) respected throughout; break-timer defect surfaced, not fixed.
- **Placeholder scan:** every code step shows complete code; every test step shows full test bodies; every run step gives an exact command and expected result. No TBD/TODO/"add validation".
- **Type consistency:** `DeviceActivityLimits.minimumIntervalMinutes` / `.maximumTimerMinutes` defined in Task 1 and referenced identically in Tasks 3, 4, 5. `scheduleWindowMinutes(startHour:startMinute:stopHour:stopMinute:)` and `stopScheduleInterval(stopHour:stopMinute:)` and `snappedDuration(for:snapPoints:threshold:maxMinutes:)` names are used consistently between their defining task and its tests.
- **Verification provenance:** all line numbers and behaviors were re-verified against `main` at commit `ef8a0a9` (post #264/#269/#271) on 2026-07-05, and the boundary math (modular cross-midnight guard; 1439 vs 1440; break-timer scope) was confirmed by a 4-agent adversarial pass. The one handover claim that was wrong — "cross-midnight windows are always valid" — is corrected here by the modular guard (Task 4).
