# Issue #248 Device Activity Classifier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the on-screen device-activity card and copied Markdown one tested classifier that
recognizes all seven runtime-dispatched device activity kinds consistently.

**Architecture:** Add an app-level diagnostics utility that parses one `DeviceActivityName` into a
display label and optional profile UUID. It aligns with `TimerActivityUtil`, the runtime source of
truth, by referencing all seven public activity ID constants without widening `FoqosShared`'s API.
Both debug consumers use the same classification object; runtime dispatch remains unchanged.

**Tech Stack:** Swift, DeviceActivity, Foundation UUID parsing, SwiftUI, XCTest.

## Global Constraints

- One PR closes only #248.
- Branch from merged `main` at version `2.0.9 (28)` and strictly bump above the live main version.
- Recognize the actual registered formats for every ID in `TimerActivityUtil`'s seven-kind switch.
- Reference the public activity ID constants; do not duplicate their raw string values.
- Treat a bare UUID as the current `Schedule Timer` format.
- Treat a known prefix with an invalid UUID as the known type with no profile match.
- Keep a source-of-truth comment naming `TimerActivityUtil`; do not widen `FoqosShared`'s API.
- Do not change timer scheduling, dispatch, sync, or session lifecycle.
- Run all Xcode commands through `scripts/xcode-stream.sh --agent build1 --session collab --` with
  caller `set -o pipefail` and `bundle exec xcpretty`.
- Never amend or force-push; request independent code review before merge; planner owns merge.

---

### Task 1: Specify the classifier contract with failing tests

**Files:**

- Create: `FoqosTests/DeviceActivityClassifierTests.swift`

**Interfaces:**

- Consumes: the wished-for `DeviceActivityClassifier.classify(_:)` API.
- Produces: executable expectations for all approved formats and profile matching.

- [ ] **Step 1: Create the focused test file**

```swift
import DeviceActivity
import Foundation
import XCTest

@testable import FamilyFoqos

@MainActor
final class DeviceActivityClassifierTests: XCTestCase {
  private let profileId = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!

  func testGivenEveryRuntimeActivityKind_WhenClassifying_ThenReturnsTypeAndProfile() {
    // Keep this table aligned with TimerActivityUtil's exhaustive runtime dispatch switch.
    let cases = [
      (
        BreakDeadlineBackstopActivity.id,
        DeviceActivityName(
          rawValue: "\(BreakDeadlineBackstopActivity.id):\(profileId.uuidString)"),
        "Break Deadline Backstop"
      ),
      (
        BreakTimerActivity.id,
        DeviceActivityName(rawValue: "\(BreakTimerActivity.id):\(profileId.uuidString)"),
        "Break Timer"
      ),
      (
        OneMoreMinuteDeadlineBackstopActivity.id,
        DeviceActivityName(
          rawValue: "\(OneMoreMinuteDeadlineBackstopActivity.id):\(profileId.uuidString)"),
        "One More Minute Deadline Backstop"
      ),
      (
        OneMoreMinuteTimerActivity.id,
        DeviceActivityName(
          rawValue: "\(OneMoreMinuteTimerActivity.id):\(profileId.uuidString)"),
        "One More Minute Timer"
      ),
      (
        ScheduleTimerActivity.id,
        DeviceActivityName(rawValue: profileId.uuidString),
        "Schedule Timer"
      ),
      (
        StopScheduleTimerActivity.id,
        DeviceActivityName(
          rawValue: "\(StopScheduleTimerActivity.id):\(profileId.uuidString)"),
        "Stop Schedule Timer"
      ),
      (
        StrategyTimerActivity.id,
        DeviceActivityName(rawValue: "\(StrategyTimerActivity.id):\(profileId.uuidString)"),
        "Strategy Timer"
      ),
    ]

    XCTAssertEqual(Set(cases.map(\.0)).count, 7)
    for (_, activity, expectedType) in cases {
      let classification = DeviceActivityClassifier.classify(activity)

      XCTAssertNotEqual(classification.type, "Unknown")
      XCTAssertEqual(classification.type, expectedType)
      XCTAssertEqual(classification.profileId, profileId)
      XCTAssertTrue(classification.matches(profileId: profileId))
    }
  }

  func testGivenUnknownName_WhenClassifying_ThenReturnsUnknownWithoutProfile() {
    let activity = DeviceActivityName(rawValue: "OtherActivity:\(profileId.uuidString)")

    let classification = DeviceActivityClassifier.classify(activity)

    XCTAssertEqual(classification.type, "Unknown")
    XCTAssertNil(classification.profileId)
    XCTAssertFalse(classification.matches(profileId: profileId))
  }

  func testGivenKnownPrefixWithInvalidUUID_WhenClassifying_ThenKeepsTypeWithoutProfile() {
    let activity = DeviceActivityName(rawValue: "\(BreakTimerActivity.id):not-a-uuid")

    let classification = DeviceActivityClassifier.classify(activity)

    XCTAssertEqual(classification.type, "Break Timer")
    XCTAssertNil(classification.profileId)
    XCTAssertFalse(classification.matches(profileId: profileId))
  }

  func testGivenDifferentProfile_WhenMatching_ThenReturnsFalse() {
    let activity = DeviceActivityName(
      rawValue: "\(StrategyTimerActivity.id):\(profileId.uuidString)")
    let otherProfileId = UUID(uuidString: "8b688f50-28c9-49ae-938f-e54c43f74471")!

    let classification = DeviceActivityClassifier.classify(activity)

    XCTAssertFalse(classification.matches(profileId: otherProfileId))
  }
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

```bash
set -o pipefail
scripts/xcode-stream.sh --agent build1 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/DeviceActivityClassifierTests 2>&1 | bundle exec xcpretty
```

Expected on initial implementation: missing classifier compile failure. Expected during review
delta: three production kinds return `Unknown` and bare UUID returns `Schedule Timer (Legacy)`.

- [ ] **Step 3: Commit the proven RED test**

```bash
git add FoqosTests/DeviceActivityClassifierTests.swift
git commit -m "Add failing device activity classifier tests for #248"
```

### Task 2: Implement the minimal shared classifier

**Files:**

- Create: `Foqos/Utils/DeviceActivityClassifier.swift`
- Test: `FoqosTests/DeviceActivityClassifierTests.swift`

**Interfaces:**

- Consumes: canonical activity IDs exported by `FoqosShared`.
- Produces: `DeviceActivityClassifier.classify(_:) -> Classification`, with `type`, `profileId`,
  and `matches(profileId:)`.

- [ ] **Step 1: Add the classifier implementation**

```swift
import DeviceActivity
import Foundation

enum DeviceActivityClassifier {
  struct Classification {
    let type: String
    let profileId: UUID?

    func matches(profileId: UUID) -> Bool {
      self.profileId == profileId
    }
  }

  static func classify(_ activity: DeviceActivityName) -> Classification {
    let rawValue = activity.rawValue

    // Keep these cases aligned with TimerActivityUtil's runtime dispatch switch.
    if let result = classifyPrefixed(
      rawValue,
      activityId: BreakDeadlineBackstopActivity.id,
      type: "Break Deadline Backstop"
    ) {
      return result
    }
    if let result = classifyPrefixed(
      rawValue,
      activityId: BreakTimerActivity.id,
      type: "Break Timer"
    ) {
      return result
    }
    if let result = classifyPrefixed(
      rawValue,
      activityId: OneMoreMinuteDeadlineBackstopActivity.id,
      type: "One More Minute Deadline Backstop"
    ) {
      return result
    }
    if let result = classifyPrefixed(
      rawValue,
      activityId: OneMoreMinuteTimerActivity.id,
      type: "One More Minute Timer"
    ) {
      return result
    }
    if let result = classifyPrefixed(
      rawValue,
      activityId: StopScheduleTimerActivity.id,
      type: "Stop Schedule Timer"
    ) {
      return result
    }
    if let result = classifyPrefixed(
      rawValue,
      activityId: StrategyTimerActivity.id,
      type: "Strategy Timer"
    ) {
      return result
    }
    if let profileId = UUID(uuidString: rawValue) {
      return Classification(type: "Schedule Timer", profileId: profileId)
    }
    return Classification(type: "Unknown", profileId: nil)
  }

  private static func classifyPrefixed(
    _ rawValue: String,
    activityId: String,
    type: String
  ) -> Classification? {
    let prefix = "\(activityId):"
    guard rawValue.hasPrefix(prefix) else { return nil }
    let rawProfileId = String(rawValue.dropFirst(prefix.count))
    return Classification(type: type, profileId: UUID(uuidString: rawProfileId))
  }
}
```

- [ ] **Step 2: Format the new Swift files**

```bash
swift-format --in-place \
  Foqos/Utils/DeviceActivityClassifier.swift \
  FoqosTests/DeviceActivityClassifierTests.swift
```

- [ ] **Step 3: Re-run the focused tests and verify GREEN**

```bash
set -o pipefail
scripts/xcode-stream.sh --agent build1 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/DeviceActivityClassifierTests 2>&1 | bundle exec xcpretty
```

Expected: all focused tests pass with zero failures and no new compiler warnings from these files.

- [ ] **Step 4: Commit the classifier**

```bash
git add Foqos/Utils/DeviceActivityClassifier.swift
git commit -m "Add shared device activity classifier for #248"
```

### Task 3: Route both diagnostics through the classifier

**Files:**

- Modify: `Foqos/Views/DebugView.swift:271-343`
- Modify: `Foqos/Components/Debug/DeviceActivitiesDebugCard.swift:18-80`
- Test: `FoqosTests/DeviceActivityClassifierTests.swift`

**Interfaces:**

- Consumes: `DeviceActivityClassifier.classify(_:)` from Task 2.
- Produces: consistent type and profile-match output in both debug surfaces.

- [ ] **Step 1: Replace DebugView's private copy**

Inside the Markdown activity loop, classify once and use the returned values:

```swift
let classification = DeviceActivityClassifier.classify(activity)
markdown += "### Activity \(index + 1)\n"
markdown += "- **Name:** \(activity.rawValue)\n"
markdown += "- **Type:** \(classification.type)\n"
markdown +=
  "- **Matches Profile:** \(classification.matches(profileId: profile.id) ? "Yes" : "No")\n"
```

Delete `DebugView.activityType(for:)` and `DebugView.isActivityForProfile(_:profileId:)`.

- [ ] **Step 2: Replace DeviceActivitiesDebugCard's private copy**

At the beginning of each `ForEach` row, classify once:

```swift
let classification = DeviceActivityClassifier.classify(activity)

DebugRow(label: "Name", value: activity.rawValue)
DebugRow(label: "Type", value: classification.type)

if let profileId {
  DebugRow(
    label: "Matches Profile",
    value: "\(classification.matches(profileId: profileId))"
  )
}
```

Use `classification.type` for the Type row and
`classification.matches(profileId: profileId)` for Matches Profile. Delete the card's two private
classification methods.

- [ ] **Step 3: Format both consumers**

```bash
swift-format --in-place \
  Foqos/Views/DebugView.swift \
  Foqos/Components/Debug/DeviceActivitiesDebugCard.swift
```

- [ ] **Step 4: Re-run the focused tests**

```bash
set -o pipefail
scripts/xcode-stream.sh --agent build1 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/DeviceActivityClassifierTests 2>&1 | bundle exec xcpretty
```

Expected: all focused tests pass.

- [ ] **Step 5: Commit the consumer integration**

```bash
git add Foqos/Views/DebugView.swift Foqos/Components/Debug/DeviceActivitiesDebugCard.swift
git commit -m "Use shared activity classification in diagnostics for #248"
```

### Task 4: Apply the strict version bump

**Files:**

- Modify: `FamilyFoqos.xcodeproj/project.pbxproj`

**Interfaces:**

- Consumes: live `origin/main` version values.
- Produces: one consistent marketing/build version across every target configuration.

- [ ] **Step 1: Refresh main and confirm the version floor**

```bash
git fetch origin main
git show origin/main:FamilyFoqos.xcodeproj/project.pbxproj \
  | rg "MARKETING_VERSION =|CURRENT_PROJECT_VERSION =" \
  | sort -u
```

If main remains `2.0.9 (28)`, change every configuration to `2.0.10 (29)`. If main advanced,
rebase the branch and choose both values strictly above the new floor before editing.

- [ ] **Step 2: Update all target configurations**

Replace every `CURRENT_PROJECT_VERSION = 28;` with `CURRENT_PROJECT_VERSION = 29;` and every
`MARKETING_VERSION = 2.0.9;` with `MARKETING_VERSION = 2.0.10;`.

```bash
ruby -pi -e \
  'gsub(%q{CURRENT_PROJECT_VERSION = 28;}, %q{CURRENT_PROJECT_VERSION = 29;});
   gsub(%q{MARKETING_VERSION = 2.0.9;}, %q{MARKETING_VERSION = 2.0.10;})' \
  FamilyFoqos.xcodeproj/project.pbxproj
```

- [ ] **Step 3: Commit and run the ref-based gate**

```bash
git add FamilyFoqos.xcodeproj/project.pbxproj
git commit -m "Bump version for #248 classifier fix"
scripts/check-version-increment.sh origin/main HEAD
```

Expected: both version values increase.

### Task 5: Verify, review, and publish

**Files:** none

**Interfaces:**

- Consumes: the complete #248 branch.
- Produces: an independently reviewed, undrafted, green PR handed to the planner.

- [ ] **Step 1: Run static repository checks**

```bash
swift-format lint --recursive .
git diff --check origin/main...HEAD
scripts/check-version-increment.sh origin/main HEAD
scripts/check-c2-guards.sh
scripts/check-sync-guards.sh
ruby scripts/check-log-privacy.rb --root .
```

- [ ] **Step 2: Run the full test suite**

```bash
set -o pipefail
scripts/xcode-stream.sh --agent build1 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  2>&1 | bundle exec xcpretty
```

Expected: all tests pass with zero failures.

- [ ] **Step 3: Run the Debug build**

```bash
set -o pipefail
scripts/xcode-stream.sh --agent build1 --session collab -- \
  xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -configuration Debug build 2>&1 | bundle exec xcpretty
```

Expected: `Build Succeeded` with exit code zero.

- [ ] **Step 4: Inspect scope and request independent review**

Review `git diff origin/main...HEAD` and send the base SHA, updated head SHA, revised design, plan,
and verification evidence to the read-only reviewer. The delta review must confirm all seven
runtime kinds, the current schedule label, malformed known-prefix semantics, and the source-of-truth
comment. Resolve every Critical or Important finding in new commits and rerun affected checks.

- [ ] **Step 5: Publish and hand off**

Push `fix/248-shared-device-activity-classifier`, open an undrafted PR that closes #248, and state
that this intentionally changes both consumers: Markdown gains strategy classification and the
card gains stop-schedule classification. Also document seven-kind coverage, the current bare-UUID
schedule label, and malformed known-prefix semantics. Wait for all CI checks to pass and send the
reviewed green PR to the planner. Do not merge it and do not begin #255 until the planner confirms
this PR is merged and `main` is updated.
