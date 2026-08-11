# Diagnostic Roster Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a transient, explicitly opted-in `roster.txt` to diagnostic exports so support can decode family-member, CloudKit participant, and cached heartbeat-device identifiers without putting names into ordinary logs.

**Architecture:** A pure `FamilyRosterExport` formatter turns main-actor snapshots of family members and monitored devices into deterministic text. `LogExportView` owns consent and dynamic disclosure, while `LogExportManager` receives only an optional preformatted string and stages it without reading CloudKit or UI state.

**Tech Stack:** Swift 6, SwiftUI, Foundation file APIs, XCTest, the existing serialized iOS simulator gate, and the existing Xcode project version gate.

## Global Constraints

- The roster toggle is transient `@State`, starts off whenever `LogExportView` is created, and is never persisted.
- With the toggle off, no `roster.txt` exists and family member names remain absent from the export.
- A member line is `<redactedLogLabel> — <displayName> — <full UUID> — <CK recordName> [— (departed)]`.
- A matched cached device line is `  device — <device identifier> — <heartbeat record name>` immediately below its member.
- Member ordering is role, display name, then full UUID; device ordering is device identifier, then heartbeat record name.
- Empty CloudKit record names and unmatched cached devices are omitted; names and identifiers are never logged.
- Export uses only `CloudKitManager.shared.familyMembers` and `HeartbeatManager.shared.monitoredDevices`; it performs no CloudKit fetch.
- Existing callers of `createLogArchive()` remain privacy-safe through a default `familyRoster: nil` argument.
- The existing no-logs check runs before roster staging, and a roster write failure fails the export instead of silently omitting the requested file.
- Marketing version must be exactly `2.0.7` and build number exactly `26` in all 12 target/configuration pairs.
- Never add Child-mode diagnostics gating. Only Child mode is subject to lock checks elsewhere: `currentMode == .child`.
- Run every Xcode test/build through `scripts/xcode-stream.sh --agent build2 --session collab --`; never pass a destination or DerivedData path.

---

### Task 1: Pure deterministic roster formatter

**Files:**
- Create: `Foqos/Utils/FamilyRosterExport.swift`
- Create: `FoqosTests/FamilyRosterExportTests.swift`

**Interfaces:**
- Consumes: `FamilyMember`, `FamilyMember.redactedLogLabel`, `MonitoredDevice`, and `DeviceHeartbeat.recordName(childUserRecordName:deviceIdentifier:)`.
- Produces: `FamilyRosterExport.content(for:monitoredDevices:) -> String` for the export UI.

- [ ] **Step 1: Write the first failing formatter test**

Create `FoqosTests/FamilyRosterExportTests.swift` with a fixed UUID and an exact active-member expectation:

```swift
import Foundation
import XCTest

@testable import FamilyFoqos

final class FamilyRosterExportTests: XCTestCase {
  func testGivenActiveMember_WhenFormattingRoster_ThenIncludesEveryLogIdentityToken() {
    let member = FamilyMember(
      id: UUID(uuidString: "3F2A9C1B-672E-4C4A-9039-FF6107FBCE91")!,
      userRecordName: "_abc123",
      displayName: "Emma",
      role: .child
    )

    XCTAssertEqual(
      FamilyRosterExport.content(for: [member], monitoredDevices: []),
      "child·3F2A9C1B — Emma — 3F2A9C1B-672E-4C4A-9039-FF6107FBCE91 — _abc123\n"
    )
  }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
scripts/xcode-stream.sh --agent build2 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/FamilyRosterExportTests
```

Expected: build/test failure because `FamilyRosterExport` does not exist.

- [ ] **Step 3: Implement the minimal member formatter**

Create `Foqos/Utils/FamilyRosterExport.swift`:

```swift
import Foundation

enum FamilyRosterExport {
  static func content(
    for members: [FamilyMember],
    monitoredDevices: [MonitoredDevice]
  ) -> String {
    let lines = members.sorted(by: memberComesBefore).map { member in
      var fields = [member.redactedLogLabel, member.displayName, member.id.uuidString]
      if !member.userRecordName.isEmpty {
        fields.append(member.userRecordName)
      }
      if !member.isActive {
        fields.append("(departed)")
      }
      return fields.joined(separator: " — ")
    }

    guard !lines.isEmpty else { return "" }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func memberComesBefore(_ lhs: FamilyMember, _ rhs: FamilyMember) -> Bool {
    if lhs.role.rawValue != rhs.role.rawValue {
      return lhs.role.rawValue < rhs.role.rawValue
    }
    if lhs.displayName != rhs.displayName {
      return lhs.displayName < rhs.displayName
    }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the Step 2 command. Expected: 1 test, 0 failures.

- [ ] **Step 5: Add failing edge, ordering, and device-mapping tests**

Extend `FamilyRosterExportTests` with:

```swift
func testGivenInactiveMember_WhenFormattingRoster_ThenAppendsDeparted() {
  let member = FamilyMember(
    id: UUID(uuidString: "81D45AA0-DB15-48E2-9E20-0BE031607A19")!,
    userRecordName: "_def456",
    displayName: "Dad",
    role: .parent,
    isActive: false
  )

  XCTAssertTrue(
    FamilyRosterExport.content(for: [member], monitoredDevices: [])
      .contains("_def456 — (departed)\n")
  )
}

func testGivenMatchedCachedDevices_WhenFormattingRoster_ThenAddsSortedDeviceLines() {
  let member = FamilyMember(
    id: UUID(uuidString: "3F2A9C1B-672E-4C4A-9039-FF6107FBCE91")!,
    userRecordName: "_abc123",
    displayName: "Emma",
    role: .child
  )
  let devices = [
    monitoredDevice(identifier: "device-z", childRecordName: "_abc123"),
    monitoredDevice(identifier: "device-a", childRecordName: "_abc123"),
    monitoredDevice(identifier: "unmatched", childRecordName: "_missing"),
  ]

  XCTAssertEqual(
    FamilyRosterExport.content(for: [member], monitoredDevices: devices),
    """
    child·3F2A9C1B — Emma — 3F2A9C1B-672E-4C4A-9039-FF6107FBCE91 — _abc123
      device — device-a — heartbeat-_abc123-device-a
      device — device-z — heartbeat-_abc123-device-z

    """
  )
}

func testGivenMembersOutOfOrder_WhenFormattingRoster_ThenSortsRoleNameAndUUID() {
  let parent = FamilyMember(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
    userRecordName: "parent",
    displayName: "Alex",
    role: .parent
  )
  let laterChild = FamilyMember(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
    userRecordName: "child-b",
    displayName: "Sam",
    role: .child
  )
  let earlierChild = FamilyMember(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    userRecordName: "child-a",
    displayName: "Sam",
    role: .child
  )

  let lines = FamilyRosterExport.content(
    for: [parent, laterChild, earlierChild], monitoredDevices: []
  ).split(separator: "\n")

  XCTAssertEqual(lines.map(String.init), [
    "child·00000000 — Sam — 00000000-0000-0000-0000-000000000001 — child-a",
    "child·00000000 — Sam — 00000000-0000-0000-0000-000000000002 — child-b",
    "parent·00000000 — Alex — 00000000-0000-0000-0000-000000000003 — parent",
  ])
}

func testGivenEmptyRecordName_WhenFormatting_ThenOmitsBlankFieldAndDoesNotMatchDevices() {
  let member = FamilyMember(
    id: UUID(uuidString: "3F2A9C1B-672E-4C4A-9039-FF6107FBCE91")!,
    userRecordName: "",
    displayName: "Emma",
    role: .child
  )

  XCTAssertEqual(
    FamilyRosterExport.content(
      for: [member],
      monitoredDevices: [monitoredDevice(identifier: "device-a", childRecordName: "")]
    ),
    "child·3F2A9C1B — Emma — 3F2A9C1B-672E-4C4A-9039-FF6107FBCE91\n"
  )
}

func testGivenNoMembers_WhenFormattingRoster_ThenReturnsEmptyContent() {
  XCTAssertEqual(FamilyRosterExport.content(for: [], monitoredDevices: []), "")
}

private func monitoredDevice(identifier: String, childRecordName: String) -> MonitoredDevice {
  MonitoredDevice(
    deviceIdentifier: identifier,
    deviceName: "Test Device",
    childUserRecordName: childRecordName,
    lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
    isSuppressed: false,
    notificationIdentifier: nil
  )
}
```

- [ ] **Step 6: Run the focused test and verify RED**

Run the Step 2 command. Expected: the matched-device test fails because device lines are absent.

- [ ] **Step 7: Extend the formatter with cached device lines**

Replace the member-only `lines` construction with `flatMap`, group devices by child record name,
and add this helper:

```swift
let devicesByMember = Dictionary(grouping: monitoredDevices, by: \.childUserRecordName)
let lines = members.sorted(by: memberComesBefore).flatMap { member -> [String] in
  var fields = [member.redactedLogLabel, member.displayName, member.id.uuidString]
  if !member.userRecordName.isEmpty {
    fields.append(member.userRecordName)
  }
  if !member.isActive {
    fields.append("(departed)")
  }

  let matchedDevices =
    member.userRecordName.isEmpty ? [] : (devicesByMember[member.userRecordName] ?? [])
  let deviceLines = matchedDevices
    .sorted(by: deviceComesBefore)
    .map { device in
      let heartbeatRecordName = DeviceHeartbeat.recordName(
        childUserRecordName: device.childUserRecordName,
        deviceIdentifier: device.deviceIdentifier
      )
      return "  device — \(device.deviceIdentifier) — \(heartbeatRecordName)"
    }

  return [fields.joined(separator: " — ")] + deviceLines
}

private static func deviceComesBefore(_ lhs: MonitoredDevice, _ rhs: MonitoredDevice) -> Bool {
  if lhs.deviceIdentifier != rhs.deviceIdentifier {
    return lhs.deviceIdentifier < rhs.deviceIdentifier
  }
  return DeviceHeartbeat.recordName(
    childUserRecordName: lhs.childUserRecordName,
    deviceIdentifier: lhs.deviceIdentifier
  ) < DeviceHeartbeat.recordName(
    childUserRecordName: rhs.childUserRecordName,
    deviceIdentifier: rhs.deviceIdentifier
  )
}
```

- [ ] **Step 8: Run focused tests and formatting checks**

Run the Step 2 command, then:

```bash
swift-format lint Foqos/Utils/FamilyRosterExport.swift FoqosTests/FamilyRosterExportTests.swift
git diff --check
```

Expected: all formatter tests pass; lint and diff checks exit 0.

- [ ] **Step 9: Commit the formatter**

```bash
git add Foqos/Utils/FamilyRosterExport.swift FoqosTests/FamilyRosterExportTests.swift
git commit -S -m "Format diagnostic family roster"
```

---

### Task 2: Optional roster archive staging

**Files:**
- Modify: `Foqos/Utils/LogExportManager.swift`
- Create: `FoqosTests/LogExportManagerRosterTests.swift`

**Interfaces:**
- Consumes: optional UTF-8 roster content from Task 1's UI integration.
- Produces: `createLogArchive(familyRoster: String? = nil) async throws -> URL` and testable `writeFamilyRoster(_:to:fileManager:)` staging behavior.

- [ ] **Step 1: Write failing nil/non-nil staging tests**

Create `FoqosTests/LogExportManagerRosterTests.swift`:

```swift
import Foundation
import XCTest

@testable import FamilyFoqos

final class LogExportManagerRosterTests: XCTestCase {
  func testGivenNilRoster_WhenStaging_ThenDoesNotCreateRosterFile() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    try LogExportManager.writeFamilyRoster(nil, to: directory, fileManager: .default)

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("roster.txt").path)
    )
  }

  func testGivenRosterContent_WhenStaging_ThenWritesExactUTF8FileIncludingEmptyContent() throws {
    for content in ["child·ABCDEF12 — Emma\n", ""] {
      let directory = try makeTemporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }

      try LogExportManager.writeFamilyRoster(content, to: directory, fileManager: .default)

      XCTAssertEqual(
        try String(
          contentsOf: directory.appendingPathComponent("roster.txt"), encoding: .utf8),
        content
      )
    }
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RosterTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
```

- [ ] **Step 2: Run focused archive tests and verify RED**

```bash
scripts/xcode-stream.sh --agent build2 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/LogExportManagerRosterTests
```

Expected: build/test failure because `writeFamilyRoster` does not exist.

- [ ] **Step 3: Add the staging helper and archive argument**

Change the archive entry point to:

```swift
func createLogArchive(familyRoster: String? = nil) async throws -> URL {
```

After the existing no-logs guard and before device-info staging, call:

```swift
try Self.writeFamilyRoster(familyRoster, to: stagingDir, fileManager: fileManager)
```

Add this internal helper next to the other nonisolated static staging helpers:

```swift
nonisolated static func writeFamilyRoster(
  _ content: String?,
  to stagingDirectory: URL,
  fileManager: FileManager
) throws {
  guard let content else { return }
  let rosterURL = stagingDirectory.appendingPathComponent("roster.txt")
  try content.write(to: rosterURL, atomically: true, encoding: .utf8)
}
```

- [ ] **Step 4: Run focused archive tests and verify GREEN**

Run the Step 2 command. Expected: 2 tests, 0 failures.

- [ ] **Step 5: Verify existing default callers and fallback behavior**

```bash
rg -n "createLogArchive\(" Foqos FoqosTests
swift-format lint Foqos/Utils/LogExportManager.swift FoqosTests/LogExportManagerRosterTests.swift
git diff --check
```

Confirm existing zero-argument calls compile through the default `nil`, and confirm
`createCombinedLogFileSync` still enumerates every staging file so `roster.txt` is included in the
text fallback.

- [ ] **Step 6: Commit archive staging**

```bash
git add Foqos/Utils/LogExportManager.swift FoqosTests/LogExportManagerRosterTests.swift
git commit -S -m "Stage optional roster in log exports"
```

---

### Task 3: Consent UI and truthful disclosure

**Files:**
- Modify: `Foqos/Views/LogExportView.swift`

**Interfaces:**
- Consumes: `FamilyRosterExport.content(for:monitoredDevices:)` and `LogExportManager.createLogArchive(familyRoster:)`.
- Produces: transient user consent, conditional disclosure, and main-actor snapshots passed into archive creation.

- [ ] **Step 1: Add the transient opt-in state**

Add beside the existing `@State` properties:

```swift
@State private var includeFamilyMemberNames = false
```

Do not use `@AppStorage` or `UserDefaults`.

- [ ] **Step 2: Add the support-only toggle and dynamic disclosure**

Replace the static privacy caption with:

```swift
Text(
  includeFamilyMemberNames
    ? "This export includes family member names, full identifiers, and CloudKit record names in roster.txt. Share it only with Family Foqos support."
    : "Logs may contain profile names, timestamps, and technical device or account identifiers. Family member names, passwords, and lock codes are not included."
)
.font(.caption)
.foregroundColor(.secondary)
```

Add this section before the action buttons:

```swift
Section("Support Options") {
  Toggle("Include family member names", isOn: $includeFamilyMemberNames)
  Text(
    "Turn this on only when Family Foqos support asks. Adds roster.txt so support can match diagnostic identifiers to family members."
  )
  .font(.caption)
  .foregroundColor(.secondary)
}
```

In **What's Included**, conditionally add:

```swift
if includeFamilyMemberNames {
  Label("Family member roster for support", systemImage: "person.text.rectangle")
}
```

Replace `Label("Personal identifiers", ...)` in **Not Included** with:

```swift
if !includeFamilyMemberNames {
  Label("Family member names", systemImage: "person.slash")
}
```

- [ ] **Step 3: Generate the roster only at the Share Logs action**

In `exportLogs()`, immediately before calling the archive manager, compute:

```swift
let familyRoster =
  includeFamilyMemberNames
  ? FamilyRosterExport.content(
    for: CloudKitManager.shared.familyMembers,
    monitoredDevices: HeartbeatManager.shared.monitoredDevices
  )
  : nil
let url = try await LogExportManager.shared.createLogArchive(familyRoster: familyRoster)
```

Remove the old zero-argument `createLogArchive()` call from that method. Do not alter Preview Logs.

- [ ] **Step 4: Format and compile the UI integration**

```bash
swift-format --in-place Foqos/Views/LogExportView.swift
swift-format lint Foqos/Views/LogExportView.swift
git diff --check
scripts/xcode-stream.sh --agent build2 --session collab -- \
  xcodebuild build -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug
```

Expected: formatter clean and `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run the two focused suites together**

```bash
scripts/xcode-stream.sh --agent build2 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/FamilyRosterExportTests \
  -only-testing:FoqosTests/LogExportManagerRosterTests
```

Expected: all focused tests pass with 0 failures.

- [ ] **Step 6: Commit UI integration**

```bash
git add Foqos/Views/LogExportView.swift
git commit -S -m "Add support roster export consent"
```

---

### Task 4: Version bump and final verification

**Files:**
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: merged-main baseline `2.0.6` build `25`.
- Produces: consistent release metadata `2.0.7` build `26` across all 12 target/configuration pairs.

- [ ] **Step 1: Establish the failing live-main version gate**

```bash
git fetch origin main
scripts/check-version-increment.sh origin/main HEAD
```

Expected before the bump: failure stating marketing/build versions did not increase.

- [ ] **Step 2: Update every target/configuration pair**

Use `apply_patch` to replace every `MARKETING_VERSION = 2.0.6;` with
`MARKETING_VERSION = 2.0.7;` and every `CURRENT_PROJECT_VERSION = 25;` with
`CURRENT_PROJECT_VERSION = 26;` in `FamilyFoqos.xcodeproj/project.pbxproj`.

- [ ] **Step 3: Verify the working-tree counts**

```bash
test "$(rg -c 'MARKETING_VERSION = 2\.0\.7;' FamilyFoqos.xcodeproj/project.pbxproj)" -eq 12
test "$(rg -c 'CURRENT_PROJECT_VERSION = 26;' FamilyFoqos.xcodeproj/project.pbxproj)" -eq 12
! rg -n 'MARKETING_VERSION = 2\.0\.6;|CURRENT_PROJECT_VERSION = 25;' \
  FamilyFoqos.xcodeproj/project.pbxproj
```

Expected: 12/12 settings agree and no stale baseline setting remains.

- [ ] **Step 4: Commit the version bump**

```bash
git add FamilyFoqos.xcodeproj/project.pbxproj
git commit -S -m "Bump version to 2.0.7 build 26"
```

- [ ] **Step 5: Verify the committed version gate**

```bash
scripts/check-version-increment.sh origin/main HEAD
```

Expected: the gate reports `2.0.6 -> 2.0.7`, `25 -> 26`.

- [ ] **Step 6: Run the full serialized test suite at the exact committed head**

```bash
scripts/xcode-stream.sh --agent build2 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos
```

Expected: 0 failures (baseline was 1,200 tests; the roster tests increase the count).

- [ ] **Step 7: Run the exact-head serialized Debug build**

```bash
scripts/xcode-stream.sh --agent build2 --session collab -- \
  xcodebuild build -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Run final formatting, project, privacy, version, and signature checks**

```bash
swift-format lint --recursive .
git diff --check origin/main...HEAD
rg -n "FamilyRosterExport|familyRoster|roster\.txt|Include family member names" Foqos FoqosTests
rg -n "Log\.(debug|info|warning|error).*displayName|Log\.(debug|info|warning|error).*deviceIdentifier" Foqos
scripts/check-version-increment.sh origin/main HEAD
git log --show-signature --format=fuller origin/main..HEAD
git status --short
```

Expected: formatting and diff checks pass; the privacy scan finds no roster name/identifier logging;
the version gate passes; every new commit has a good signature; the worktree is clean.

- [ ] **Step 9: Push, open a draft PR, and request review**

```bash
git push -u origin HEAD
```

Open a draft PR targeting `main` with the approved spec, privacy behavior, cached heartbeat mapping,
red-green evidence, exact test/build counts, and version evidence. Request review before any merge;
the planner, not the implementer, performs the merge.
