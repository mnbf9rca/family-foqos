# Logging Privacy and Child Diagnostics Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make unified logging private by default, remove the four known exportable credential/PII
call sites, and prevent Child-mode users from viewing or exporting diagnostics.

**Architecture:** Keep the existing file log for user-initiated support exports, but redact sensitive
values before they reach it and mark the flattened unified-log string private. Centralize the
Child-mode decision in a pure `DiagnosticsAccess` helper, then enforce it at entry points, inside the
views, and at the archive manager boundary. Existing Individual and Parent diagnostics remain
available.

**Tech Stack:** Swift 6, SwiftUI, CloudKit, CoreNFC, OSLog, XCTest, gated Xcode simulator tooling.

## Global Constraints

- Base every change on `main` at `90b4235`; refresh `origin/main` before publishing.
- Never amend, force-push, or create an unsigned production commit. Use new signed commits only.
- Run every simulator build or test through
  `scripts/xcode-stream.sh --agent build2 --session collab --`.
- Use `appModeManager.currentMode == .child` semantics. Never use `!= .parent` for restrictions.
- Redact exactly four #359 sites: participant display info, member display name, and the two NFC UID
  logs. Keep `member.role.displayName` because it is only the non-PII role label.
- Do not add the #360 lint in this PR; #360 is the next standalone build-phase PR.
- Bump all 12 target/configuration pairs from `2.0.5 (24)` to `2.0.6 (25)` before review.
- Request independent review before merge. The planner owns the merge.

---

### Task 1: Test and add the pure privacy decisions

**Files:**
- Create: `Foqos/Components/Debug/DiagnosticsAccess.swift`
- Modify: `Foqos/Components/Debug/DebugRedaction.swift`
- Create: `FoqosTests/DiagnosticsAccessTests.swift`
- Modify: `FoqosTests/DebugRedactionTests.swift`

**Interfaces:**
- Produces: `DiagnosticsAccess.isRestricted(mode: AppMode) -> Bool`.
- Produces: `DebugRedaction.physicalUnblockNFCTagIdForLog(_ raw: String) -> String`.
- Consumes: the existing private `DebugRedaction.maskCredential(_:)` implementation.

- [ ] **Step 1: Write the failing diagnostics-access tests**

```swift
import XCTest

@testable import FamilyFoqos

final class DiagnosticsAccessTests: XCTestCase {
  func testGivenChildMode_WhenCheckingDiagnosticsAccess_ThenRestricted() {
    XCTAssertTrue(DiagnosticsAccess.isRestricted(mode: .child))
  }

  func testGivenParentMode_WhenCheckingDiagnosticsAccess_ThenAllowed() {
    XCTAssertFalse(DiagnosticsAccess.isRestricted(mode: .parent))
  }

  func testGivenIndividualMode_WhenCheckingDiagnosticsAccess_ThenAllowed() {
    XCTAssertFalse(DiagnosticsAccess.isRestricted(mode: .individual))
  }
}
```

- [ ] **Step 2: Add failing log-mask tests to `DebugRedactionTests`**

```swift
func testGivenNFCId_WhenPreparingForLog_ThenMasksMiddle() {
  XCTAssertEqual(DebugRedaction.physicalUnblockNFCTagIdForLog("ABCDEF12"), "AB…12")
}

func testGivenShortNFCId_WhenPreparingForLog_ThenUsesConstantMask() {
  XCTAssertEqual(DebugRedaction.physicalUnblockNFCTagIdForLog("ABC"), "••••••")
}
```

- [ ] **Step 3: Run the two test classes and verify RED**

```bash
set -o pipefail
scripts/xcode-stream.sh --agent build2 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/DiagnosticsAccessTests \
  -only-testing:FoqosTests/DebugRedactionTests 2>&1 | bundle exec xcpretty
```

Expected: compile failure because `DiagnosticsAccess` and
`physicalUnblockNFCTagIdForLog` do not exist.

- [ ] **Step 4: Implement the minimal pure decisions**

`DiagnosticsAccess.swift`:

```swift
import Foundation

enum DiagnosticsAccess {
  static func isRestricted(mode: AppMode) -> Bool {
    mode == .child
  }
}
```

Add to `DebugRedaction`:

```swift
/// Log files can be exported later, so replayable NFC credentials are always masked.
static func physicalUnblockNFCTagIdForLog(_ raw: String) -> String {
  maskCredential(raw)
}
```

- [ ] **Step 5: Re-run the two test classes and verify GREEN**

Run the Step 3 command. Expected: both test classes pass.

- [ ] **Step 6: Commit the tested helpers**

```bash
git add Foqos/Components/Debug/DiagnosticsAccess.swift \
  Foqos/Components/Debug/DebugRedaction.swift \
  FoqosTests/DiagnosticsAccessTests.swift FoqosTests/DebugRedactionTests.swift
git commit -m "Add diagnostics privacy gates"
```

---

### Task 2: Redact the four sensitive call sites and private-mark unified logging

**Files:**
- Modify: `Packages/FoqosShared/Sources/FoqosShared/Log.swift`
- Modify: `Foqos/CloudKit/CloudKitNetworkService+Sharing.swift`
- Modify: `Foqos/Utils/NFCScannerUtil.swift`
- Test: `FoqosTests/DebugRedactionTests.swift`
- Test: `FoqosTests/FamilyMemberLogRedactionTests.swift`

**Interfaces:**
- Consumes: `DebugRedaction.physicalUnblockNFCTagIdForLog(_:)` from Task 1.
- Consumes: existing `FamilyMember.redactedLogLabel`.

- [ ] **Step 1: Change the unified-log sink to explicit private formatting**

```swift
os_log("%{private}@", log: osLog, type: entry.level.osLogType, entry.formattedString)
```

The separately persisted file line remains unchanged because support export is an explicit user
action and call-site redaction protects its sensitive values.

- [ ] **Step 2: Remove participant name/email construction from the status log**

Replace the participant loop body with a status-only message:

```swift
for participant in participants {
  Log.debug(
    "Participant status: \(participant.acceptanceStatus.rawValue)",
    category: .cloudKit)
}
```

- [ ] **Step 3: Replace the removed member's display name with its established opaque label**

```swift
Log.info(
  "Removed FamilyMember who left share: \(member.redactedLogLabel)", category: .cloudKit)
```

- [ ] **Step 4: Mask both NFC identifiers before interpolation**

In `readMiFareTag` and `readISO15693Tag`, derive:

```swift
let redactedTagIdentifier = DebugRedaction.physicalUnblockNFCTagIdForLog(tagIdentifier)
```

Use `redactedTagIdentifier` in each NDEF failure log while continuing to pass the untouched
`tagIdentifier` to `completeTagScan`.

- [ ] **Step 5: Run the focused behavior tests**

```bash
set -o pipefail
scripts/xcode-stream.sh --agent build2 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/DebugRedactionTests \
  -only-testing:FoqosTests/FamilyMemberLogRedactionTests 2>&1 | bundle exec xcpretty
```

Expected: all selected tests pass.

- [ ] **Step 6: Run source-level acceptance guards**

```bash
if rg -n 'displayInfo|member\.displayName' \
  Foqos/CloudKit/CloudKitNetworkService+Sharing.swift; then exit 1; fi
if rg -n 'using tag id: \\(tagIdentifier\\)' Foqos/Utils/NFCScannerUtil.swift; then exit 1; fi
if rg -n '%\{public\}@' Packages/FoqosShared/Sources/FoqosShared/Log.swift; then exit 1; fi
rg -n '%\{private\}@' Packages/FoqosShared/Sources/FoqosShared/Log.swift
rg -n 'member\.role\.displayName' Foqos/CloudKit/CloudKitNetworkService+FamilyMembers.swift
```

Expected: the first three commands find nothing; the two positive guards find their intended
private format and retained non-PII role label.

- [ ] **Step 7: Commit the sink and call-site fixes**

```bash
git add Packages/FoqosShared/Sources/FoqosShared/Log.swift \
  Foqos/CloudKit/CloudKitNetworkService+Sharing.swift Foqos/Utils/NFCScannerUtil.swift
git commit -m "Redact sensitive diagnostic logs"
```

---

### Task 3: Enforce Child-mode diagnostics denial at every boundary

**Files:**
- Modify: `Foqos/Components/Dashboard/VersionFooter.swift`
- Modify: `Foqos/Views/HomeView.swift`
- Modify: `Foqos/Views/SettingsView.swift`
- Modify: `Foqos/Views/DebugView.swift`
- Modify: `Foqos/Views/LogExportView.swift`
- Modify: `Foqos/Utils/LogExportManager.swift`
- Test: `FoqosTests/DiagnosticsAccessTests.swift`

**Interfaces:**
- Consumes: `DiagnosticsAccess.isRestricted(mode:)` from Task 1.
- Produces: `LogExportError.notAvailableInChildMode` for manager-boundary denial.

- [ ] **Step 1: Hide both Debug Mode entry points for Child mode**

Add `mode: AppMode` to `VersionFooter`; render its button only when the profile is active and
`DiagnosticsAccess.isRestricted(mode:)` is false. Pass `appModeManager.currentMode` from `HomeView`
and update both previews. Wrap Settings' Diagnostics section in the same allowed condition.

- [ ] **Step 2: Defend both sheet presentations against stale state**

In the Home and Settings `.sheet` closures, instantiate `DebugView()` only when diagnostics are not
restricted for `appModeManager.currentMode`.

- [ ] **Step 3: Deny direct construction of `DebugView` and `LogExportView`**

Observe `AppModeManager.shared` in each view. At the top of each `body`, branch on
`DiagnosticsAccess.isRestricted(mode:)`: show a locked `ContentUnavailableView` in Child mode and
the existing navigation content otherwise. This prevents previews, future routes, or stale sheet
state from exposing diagnostics.

- [ ] **Step 4: Deny file creation in `LogExportManager`**

At the start of both `createLogArchive()` and `getShareableLogFile()`, throw
`LogExportError.notAvailableInChildMode` when the current mode is Child. Add the enum case and this
localized description:

```swift
case .notAvailableInChildMode:
  return "Diagnostic log export is unavailable in Child mode"
```

`shareLogArchive` already flows through `createLogArchive`, so it inherits the same denial.

- [ ] **Step 5: Run the diagnostics decision tests**

```bash
set -o pipefail
scripts/xcode-stream.sh --agent build2 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/DiagnosticsAccessTests 2>&1 | bundle exec xcpretty
```

Expected: the Child/Parent/Individual decision matrix passes.

- [ ] **Step 6: Run a gated debug build for all view and manager wiring**

```bash
set -o pipefail
scripts/xcode-stream.sh --agent build2 --session collab -- \
  xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -configuration Debug build 2>&1 | bundle exec xcpretty
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit the child diagnostics gate**

```bash
git add Foqos/Components/Dashboard/VersionFooter.swift Foqos/Views/HomeView.swift \
  Foqos/Views/SettingsView.swift Foqos/Views/DebugView.swift \
  Foqos/Views/LogExportView.swift Foqos/Utils/LogExportManager.swift
git commit -m "Block diagnostics export in Child mode"
```

---

### Task 4: Version and final verification

**Files:**
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: all 12 target/configuration pairs at `MARKETING_VERSION = 2.0.6` and
  `CURRENT_PROJECT_VERSION = 25`.

- [ ] **Step 1: Increment every version pair and commit separately**

```bash
git add FamilyFoqos.xcodeproj/project.pbxproj
git commit -m "Bump version to 2.0.6 build 25"
```

- [ ] **Step 2: Run the full gated test suite**

```bash
set -o pipefail
scripts/xcode-stream.sh --agent build2 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  2>&1 | bundle exec xcpretty
```

Expected: all tests pass.

- [ ] **Step 3: Run formatting and static verification**

```bash
swift-format lint --recursive .
plutil -lint FamilyFoqos.xcodeproj/project.pbxproj
bash scripts/test-check-version-increment.sh
bash scripts/check-version-increment.sh origin/main HEAD
git diff --check origin/main...HEAD
```

- [ ] **Step 4: Re-run the Task 2 source guards and verify 12/12 version pairs**

Confirm the sensitive patterns remain absent, the private format remains present, and exactly 12
occurrences each use `CURRENT_PROJECT_VERSION = 25` and `MARKETING_VERSION = 2.0.6`.

- [ ] **Step 5: Refresh `origin/main`, rebase only if required, and re-bump in a new commit if main
      moved**

Never amend the reviewed commits. Re-run the full version and up-to-date gates after any rebase.

- [ ] **Step 6: Open a draft PR and request independent review**

The PR body closes #358 and #359, lists the four redacted call sites, identifies the retained
role-label decoy, documents the defense-in-depth Child-mode gate, and notes that #360 follows as a
separate build-phase lint PR.
