# Bundle I — App-Group UserDefaults Migration Ordering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the main-app app-group key migration from clobbering fresher values that an extension (DeviceActivity monitor / widget) wrote through `SharedData` before the app's first post-update launch — which today resurrects an already-ended schedule session as "active" and permanently loses a just-completed session record (#217).

**Architecture:** Two composed fixes. **Fix B (migration ordering):** `UserDefaultsMigration.migrateAppGroupIfNeeded` copies a legacy value to the new prefixed key **only when the new key is absent**, and always drops the legacy key. **Fix A (write hygiene):** every `SharedData` setter clears its pre-migration (legacy) key on write, so a stale legacy value can never shadow or resurrect state after migration. Together they make "the new prefixed key always wins" hold in every ordering. No behavior change to normal migration (legacy-only → still copied).

**Tech Stack:** Swift 6, Foundation (`UserDefaults`), the `FoqosShared` Swift package, XCTest. iOS app target module name is `FamilyFoqos`; the shared code is module `FoqosShared`.

**Source commit (current `main` at authoring):** `6ffb8c22b52c4b47da610b978783ccc69774f712`

**Citations refreshed before implementation:** `66ba422241c2c75115451929866516e02cdf90f7`

**Epic:** #263 (defect-audit follow-ups). Bundle I. Issue: #217 (high).

## Implementation Sequencing (read first)

Bundle **F** (zombie-model safety, #213/#235) and Bundle **I** are implemented as **two separate, sequential PRs**. **F ships first; I second.** Branch I from `main` **after F has merged**; open I's PR from there. Do not develop them in parallel — this repo forbids concurrent build/test streams on one machine (AGENTS.md "NO parallel development").

## Global Constraints

- Read `AGENTS.md` at the repo root before writing any code. It overrides everything else.
- Work on a feature branch off `main`. **NEVER** amend or force-push; new commits only. Request code review before merging.
- Use `Log.<level>(_, category:)` instead of `print()`. Never log lock codes or personal identifiers.
- swift-format is enforced by a pre-commit hook (2-space indent, ~100–120 col). Run `swift-format --in-place --recursive .` before committing if not relying on the hook.
- Tests: name `testGivenX_WhenY_ThenZ()`; pin time — capture **one** `let now = Date()` per test if dates are needed.
- Tests import the app module with `@testable import FamilyFoqos`; shared code with `@preconcurrency import FoqosShared`.
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

---

## The defect (re-verified against refreshed `main`)

Confirmed intact on current `main` — PR #277 (D2) added session-**identity** gating to the
`SharedData` mutators, and PR #279 (D1) routed schedule-stop through
`endActiveSharedSession(expectedSessionId:)`; neither touched the migration, the legacy-key
fallback readers, or the write-only-new-key setters.

1. `migrateAppGroupIfNeeded` (`Foqos/Utils/UserDefaultsMigration.swift:57-62`) unconditionally copies each legacy app-group key over the new prefixed key, guarded only by a one-time flag that is unset until the first launch after update. It runs **only** in the main app (`FoqosApp.swift:109`).
2. `SharedData` setters write **only** the new prefixed keys and never remove the legacy keys (`SharedData.swift`: `profileSnapshots` set → 312-318; `completedSessionsInScheduler` set → 348-354; `activeSharedSession` set → 364-370; `deviceSyncId`/`deviceSyncEnabled` → 556-565/574-576). Its getters fall back to the legacy key (`data/string/bool(forKey:legacyKey:)`, 122-136).
3. `SharedData.swift:111-113` explicitly documents that extensions may run before the app migrates — but only the **read** path was handled, not the **write** path.

**Failure chain:** pre-rename app has an active schedule session under legacy `"activeScheduleSession"`. App updates via the App Store overnight. The DeviceActivity interval ends **before** first app launch: `DeviceActivityMonitorExtension.intervalDidEnd` (`FoqosDeviceMonitor/DeviceActivityMonitorExtension.swift:37-41`) routes through `TimerActivityUtil.stopTimerActivity` (`Packages/FoqosShared/Sources/FoqosShared/Timers/TimerActivityUtil.swift:16-25`) to `ScheduleTimerActivity.stop` (`Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift:130-156`), which deactivates restrictions after calling `SharedData.endActiveSharedSession(expectedSessionId:)`. That appends the completed session under the **new** key and clears only the **new** active key — the legacy `"activeScheduleSession"` still holds the session. On first app launch, `migrateAppGroupIfNeeded` copies that stale legacy session over the new active key (resurrecting an ended session as "active" while ManagedSettings restrictions are off) and copies the stale legacy completed list over the new list (losing the just-completed session from stats/insights/sync).

---

## Merge Semantics Analysis — why "new key wins" is correct (NOT a maintainer decision)

The instruction for this bundle was to flag a **MAINTAINER DECISION REQUIRED** if the correct merge, when *both* the app and an extension have written a key, is ambiguous. **It is not ambiguous. No maintainer decision is required.** Reasoning, grounded in the current `SharedData` API:

- Every `SharedData` **getter** reads the new key with a fallback to the legacy key: `suite.data(forKey: new) ?? suite.data(forKey: legacy)` (and the `string`/`bool` equivalents).
- Every `SharedData` **setter** writes the *whole* structure it just read back to the **new** key (dictionaries for `profileSnapshots`, arrays for `completedSessionsInScheduler`, the single object for `activeSharedSession`).
- Therefore any write an extension performs after update **seeds from the legacy value via the getter fallback and re-persists a fresher, superset/replacement value to the new key.** The new key is never an *independent* datum that could lose information relative to legacy — it is always the more-recent merge.

Consequences:
- **"Prefer the new key when present" (Fix B) never loses data.** Example — completed sessions: legacy `[A,B]`; the extension's `endActiveSharedSession` reads `new(absent) ?? legacy [A,B]`, appends `C`, and writes new `[A,B,C]`. Keeping new `[A,B,C]` and discarding legacy `[A,B]` is strictly correct.
- **The one key that can end up "new-absent, legacy-present" after an extension write is `activeSharedSession`** (its setter is driven to `nil` by `endActiveSharedSession`). Fix B alone does **not** cover that case — the new key is absent, so a naive "copy when new absent" would still resurrect the legacy session. **Fix A closes it** by clearing the legacy key on that write. This is why both fixes are required, not just the migration guard.
- `familyFoqosThemeColorName` is **not** managed by `SharedData` — `ThemeManager` reads/writes the *new* key `family_foqos_theme_color_name` directly via `@AppStorage` with no legacy fallback (`ThemeManager.swift:32`). It is cosmetic and covered by Fix B only (if some process wrote the new theme key first, keep it; otherwise migrate legacy). No session-state risk.

If a reviewer disputes the invariant above (i.e. believes some app-group key can hold genuinely independent legacy-vs-new values that must be *merged* rather than new-wins), escalate — but no such key exists in the current `SharedData` surface.

### A note on `activeSharedSession = nil` and `JSONEncoder`

`activeSharedSession`'s setter runs `try? JSONEncoder().encode(newValue)` where `newValue` is `SessionSnapshot?`. Whether encoding a top-level `nil` Optional throws (→ `removeObject`, new key **absent**) or succeeds as a `null` blob (→ new key present-but-undecodable, getter still returns `nil`) is an OS/toolchain detail we deliberately do **not** rely on. Fix A removes the **legacy** key unconditionally on that write, so the resurrection is prevented in either case. (The getter returns `nil` after `end()` regardless, because a `null`/garbage blob fails to decode.)

---

## File Structure

- **Modify** `Foqos/Utils/UserDefaultsMigration.swift` — Fix B: copy legacy→new only when new is absent; always drop legacy (Task I1).
- **Modify** `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift` — Fix A: add a `clearLegacy(_:)` helper and call it from every setter (Task I2).
- **Modify** `FoqosTests/UserDefaultsMigrationTests.swift` — add Fix B regression tests (Task I1).
- **Create** `FoqosTests/SharedDataLegacyKeyClearingTests.swift` — Fix A regression tests (Task I2).

---

## Task I1: Migration copies legacy→new only when new is absent (#217, Fix B)

**Files:**
- Modify: `Foqos/Utils/UserDefaultsMigration.swift` (the `migrateAppGroupIfNeeded` loop, lines 57-62)
- Test: `FoqosTests/UserDefaultsMigrationTests.swift` (add cases)

**Interfaces:**
- Consumes: `appGroupKeyMapping` (`[(old, new)]`) and the `appGroupMigrationFlag`, both already present.
- Produces: no signature change to `migrateAppGroupIfNeeded(defaults:)`. Behavior change: a present new key is no longer overwritten; the legacy key is always removed.

- [ ] **Step 1: Write the failing tests**

Append these methods to `FoqosTests/UserDefaultsMigrationTests.swift` (inside the `final class UserDefaultsMigrationTests`, in the `// MARK: - App group suite tests` section). They reuse the existing `defaults` fixture (suite `"UserDefaultsMigrationTests"`, cleared each test in `setUp`/`tearDown`):

```swift
  func testGivenNewAppGroupKeyAlreadyWritten_WhenMigrate_ThenNewValueKeptAndOldRemoved() {
    // An extension wrote the new key before the first app launch; the legacy shadow lingers.
    defaults.set(Data([4, 5, 6]), forKey: "family_foqos_active_schedule_session")
    defaults.set(Data([9, 9, 9]), forKey: "activeScheduleSession")

    UserDefaultsMigration.migrateAppGroupIfNeeded(defaults: defaults)

    XCTAssertEqual(
      defaults.data(forKey: "family_foqos_active_schedule_session"), Data([4, 5, 6]),
      "fresh extension-written value must survive migration (#217)")
    XCTAssertNil(
      defaults.object(forKey: "activeScheduleSession"), "stale legacy key must be removed")
  }

  func testGivenNewCompletedListWithFreshSession_WhenMigrate_ThenNotClobberedByLegacyList() {
    // Legacy completed list from before the update...
    defaults.set(Data([1, 1]), forKey: "completedScheduleSessions")
    // ...and the extension's appended (superset) list under the new key.
    defaults.set(Data([1, 1, 2, 2]), forKey: "family_foqos_completed_schedule_sessions")

    UserDefaultsMigration.migrateAppGroupIfNeeded(defaults: defaults)

    XCTAssertEqual(
      defaults.data(forKey: "family_foqos_completed_schedule_sessions"), Data([1, 1, 2, 2]),
      "the just-completed session must not be lost to the stale legacy list (#217)")
    XCTAssertNil(defaults.object(forKey: "completedScheduleSessions"))
  }

  func testGivenLegacyOnlyAppGroupKey_WhenMigrate_ThenStillCopiedToNewKey() {
    // Normal migration path (no extension pre-write) must be unchanged.
    defaults.set(Data([7, 8, 9]), forKey: "completedScheduleSessions")

    UserDefaultsMigration.migrateAppGroupIfNeeded(defaults: defaults)

    XCTAssertEqual(
      defaults.data(forKey: "family_foqos_completed_schedule_sessions"), Data([7, 8, 9]))
    XCTAssertNil(defaults.object(forKey: "completedScheduleSessions"))
  }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' \
  -only-testing:FoqosTests/UserDefaultsMigrationTests | xcpretty
```
Expected: `testGivenNewAppGroupKeyAlreadyWritten_…` fails (new key becomes `Data([9,9,9])` — clobbered) and `testGivenNewCompletedListWithFreshSession_…` fails (new key becomes `Data([1,1])` — lost session). `testGivenLegacyOnlyAppGroupKey_…` passes (documents unchanged path). Existing app-group tests still pass.

- [ ] **Step 3: Apply Fix B**

In `Foqos/Utils/UserDefaultsMigration.swift`, replace the `migrateAppGroupIfNeeded` copy loop:
```swift
    for (old, new) in appGroupKeyMapping {
      if let value = defaults.object(forKey: old) {
        defaults.set(value, forKey: new)
        defaults.removeObject(forKey: old)
      }
    }
```
with:
```swift
    for (old, new) in appGroupKeyMapping {
      // Copy the legacy value only when the new key is absent. An extension (DeviceActivity
      // monitor / widget) may have written the new key through SharedData before the main app
      // first launched and migrated; that value is fresher and must win over the legacy shadow
      // (#217). Always drop the legacy key so it can never resurrect stale state on a later run.
      if defaults.object(forKey: new) == nil, let value = defaults.object(forKey: old) {
        defaults.set(value, forKey: new)
      }
      defaults.removeObject(forKey: old)
    }
```

Leave the `standardKeyMapping` loop in `migrateIfNeeded` unchanged — those are standard-suite, in-app-only keys with no cross-process extension writer, so the ordering hazard does not apply.

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' \
  -only-testing:FoqosTests/UserDefaultsMigrationTests | xcpretty
```
Expected: PASS (all existing + 3 new).

- [ ] **Step 5: Commit**

```bash
git add Foqos/Utils/UserDefaultsMigration.swift FoqosTests/UserDefaultsMigrationTests.swift
git commit -m "fix(#217): migrate app-group keys only when new key absent"
```

---

## Task I2: `SharedData` setters clear the legacy key on write (#217, Fix A)

**Files:**
- Modify: `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift`
- Test: `FoqosTests/SharedDataLegacyKeyClearingTests.swift` (create)

**Interfaces:**
- Consumes: the existing private `Key` and `LegacyKey` enums; the `suite` accessor.
- Produces: new `private static func clearLegacy(_ legacyKey: LegacyKey)`. No public API change. Behavior change: after any write through a `SharedData` setter, that setter's legacy key is guaranteed absent.

**Critical:** `clearLegacy` must be a plain `suite.removeObject` with **no** `withLock` — `withLock` is non-reentrant and several setters already run inside a caller's `withLock` (`createActiveSharedSession`, `endActiveSharedSession`, `deviceSyncId`). A nested `withLock` would release the process lock early (see the contract comment at `SharedData.swift:70-77`).

- [ ] **Step 1: Write the failing tests**

Create `FoqosTests/SharedDataLegacyKeyClearingTests.swift`:

```swift
@preconcurrency import FoqosShared
import XCTest

@testable import FamilyFoqos

@MainActor
final class SharedDataLegacyKeyClearingTests: XCTestCase {
  private var suite: UserDefaults!
  private var suiteName: String!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "SharedDataLegacyKeyClearingTests-\(UUID().uuidString)"
    suite = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: suite)
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: suiteName)
    suite = nil
    suiteName = nil
    try await super.tearDown()
  }

  private func makeSnapshot(id: String, ended: Bool = false) -> SharedData.SessionSnapshot {
    let now = Date()  // pin time: one Date() per test path (AGENTS.md)
    return SharedData.SessionSnapshot(
      id: id, tag: "t", blockedProfileId: UUID(), startTime: now,
      endTime: ended ? now : nil, forceStarted: true)
  }

  func testGivenLegacyActiveKey_WhenActiveSharedSessionWritten_ThenLegacyKeyCleared() {
    suite.set(Data([1, 2, 3]), forKey: "activeScheduleSession")  // pre-migration legacy shadow

    SharedData.createActiveSharedSession(for: makeSnapshot(id: "s1"))

    XCTAssertNil(
      suite.object(forKey: "activeScheduleSession"),
      "legacy active key must be cleared on write (#217)")
    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, "s1")
  }

  func testGivenLegacyActiveKey_WhenActiveSessionEnded_ThenNoResurrectionPossible() {
    SharedData.createActiveSharedSession(for: makeSnapshot(id: "s1"))
    // Simulate the stale legacy shadow lingering alongside the extension's new-key write.
    suite.set(Data([9, 9, 9]), forKey: "activeScheduleSession")

    SharedData.endActiveSharedSession()

    XCTAssertNil(SharedData.getActiveSharedSession(), "no active session after end")
    XCTAssertNil(
      suite.object(forKey: "activeScheduleSession"),
      "legacy active key must not survive end() — else migration resurrects it (#217)")
  }

  func testGivenLegacyCompletedKey_WhenCompletedSessionAppended_ThenLegacyKeyCleared() {
    suite.set(Data([1, 2, 3]), forKey: "completedScheduleSessions")  // legacy shadow
    SharedData.createActiveSharedSession(for: makeSnapshot(id: "s1"))

    // endActiveSharedSession appends to completedSessionsInScheduler (a setter write).
    SharedData.endActiveSharedSession()

    XCTAssertNil(
      suite.object(forKey: "completedScheduleSessions"),
      "legacy completed key must be cleared on write (#217)")
  }

  func testGivenLegacyDeviceSyncKeys_WhenWritten_ThenLegacyKeysCleared() {
    suite.set("old-id", forKey: "deviceSyncId")
    suite.set(false, forKey: "deviceSyncEnabled")

    SharedData.deviceSyncId = UUID()
    SharedData.deviceSyncEnabled = true

    XCTAssertNil(suite.object(forKey: "deviceSyncId"), "legacy deviceSyncId key cleared on write")
    XCTAssertNil(
      suite.object(forKey: "deviceSyncEnabled"), "legacy deviceSyncEnabled key cleared on write")
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' \
  -only-testing:FoqosTests/SharedDataLegacyKeyClearingTests | xcpretty
```
Expected: all four fail — the legacy keys are still present because setters do not clear them yet.

- [ ] **Step 3: Add the `clearLegacy` helper**

In `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift`, immediately after the `bool(forKey:legacyKey:)` reader helper (the method ending at line 136, just before `// MARK: – Serializable snapshot of a profile`), add:

```swift
  /// Removes the pre-migration (legacy) key on every write, so a stale legacy value can never
  /// shadow or resurrect state after the main-app app-group migration runs (#217). Pairs with
  /// `UserDefaultsMigration`'s copy-only-when-new-absent guard.
  /// MUST NOT take `withLock` — it is called from setters already inside a caller's `withLock`,
  /// which is non-reentrant.
  private static func clearLegacy(_ legacyKey: LegacyKey) {
    suite.removeObject(forKey: legacyKey.rawValue)
  }
```

- [ ] **Step 4: Call `clearLegacy` from every setter**

Make these edits in `SharedData.swift`.

`profileSnapshots` setter — replace:
```swift
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        suite.set(data, forKey: Key.profileSnapshots.rawValue)
      } else {
        suite.removeObject(forKey: Key.profileSnapshots.rawValue)
      }
    }
```
with:
```swift
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        suite.set(data, forKey: Key.profileSnapshots.rawValue)
      } else {
        suite.removeObject(forKey: Key.profileSnapshots.rawValue)
      }
      clearLegacy(.profileSnapshots)
    }
```

`completedSessionsInScheduler` setter — replace:
```swift
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        suite.set(data, forKey: Key.completedScheduleSessions.rawValue)
      } else {
        suite.removeObject(forKey: Key.completedScheduleSessions.rawValue)
      }
    }
```
with:
```swift
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        suite.set(data, forKey: Key.completedScheduleSessions.rawValue)
      } else {
        suite.removeObject(forKey: Key.completedScheduleSessions.rawValue)
      }
      clearLegacy(.completedScheduleSessions)
    }
```

`activeSharedSession` setter — replace:
```swift
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        suite.set(data, forKey: Key.activeScheduleSession.rawValue)
      } else {
        suite.removeObject(forKey: Key.activeScheduleSession.rawValue)
      }
    }
```
with:
```swift
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        suite.set(data, forKey: Key.activeScheduleSession.rawValue)
      } else {
        suite.removeObject(forKey: Key.activeScheduleSession.rawValue)
      }
      clearLegacy(.activeScheduleSession)
    }
```

`deviceSyncId` — clear legacy in **both** the getter's generate-branch and the setter. Replace the getter branch:
```swift
        // Generate new ID if none exists
        let newId = UUID()
        suite.set(newId.uuidString, forKey: Key.deviceSyncId.rawValue)
        return newId
```
with:
```swift
        // Generate new ID if none exists
        let newId = UUID()
        suite.set(newId.uuidString, forKey: Key.deviceSyncId.rawValue)
        clearLegacy(.deviceSyncId)
        return newId
```
and replace the setter:
```swift
    set {
      withLock {
        suite.set(newValue.uuidString, forKey: Key.deviceSyncId.rawValue)
      }
    }
```
with:
```swift
    set {
      withLock {
        suite.set(newValue.uuidString, forKey: Key.deviceSyncId.rawValue)
        clearLegacy(.deviceSyncId)
      }
    }
```

`deviceSyncEnabled` setter — replace:
```swift
    set {
      suite.set(newValue, forKey: Key.deviceSyncEnabled.rawValue)
    }
```
with:
```swift
    set {
      suite.set(newValue, forKey: Key.deviceSyncEnabled.rawValue)
      clearLegacy(.deviceSyncEnabled)
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' \
  -only-testing:FoqosTests/SharedDataLegacyKeyClearingTests | xcpretty
```
Expected: PASS (4 tests).

- [ ] **Step 6: Guard against regressions in the shared session identity/lock suites**

Run the two existing `SharedData` suites to confirm Fix A didn't disturb identity gating or locking:
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' \
  -only-testing:FoqosTests/SharedDataSessionIdentityTests \
  -only-testing:FoqosTests/SharedDataLockTests | xcpretty
```
Expected: PASS (unchanged).

- [ ] **Step 7: Commit**

```bash
git add Packages/FoqosShared/Sources/FoqosShared/SharedData.swift \
        FoqosTests/SharedDataLegacyKeyClearingTests.swift
git commit -m "fix(#217): clear legacy app-group keys on every SharedData write"
```

---

## Final verification (before requesting review)

- [ ] **Full suite green.** Run the whole `FoqosTests` target once (reusing the booted simulator):
  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
    -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty
  ```
  Expected: all existing tests plus the 7 new tests pass.
- [ ] **swift-format clean:** `swift-format lint --recursive .` reports no violations for the changed files.
- [ ] **Reconfirm the end-to-end scenario by inspection:** with both fixes, the extension's `endActiveSharedSession` clears the legacy active key (Fix A) so migration finds nothing to resurrect, and the migration keeps the extension's fresher new-key completed list (Fix B) so no completed session is lost.
- [ ] **Request code review** before merging (AGENTS.md requirement). Reference #217.

## Acceptance criteria (from the handover)

- The #217 failure chain can no longer be reproduced: no resurrected "active" session after an interval ends pre-launch, and no lost completed-session record on the upgrade path.
- Regression tests exist in `FoqosTests` (naming `testGivenX_WhenY_ThenZ`): Fix B in `UserDefaultsMigrationTests`, Fix A in `SharedDataLegacyKeyClearingTests`.
- Normal migration (legacy-only keys) is unchanged; all existing tests pass; swift-format clean; review requested.
- Merge semantics are documented (new-key-wins) with the reasoning above; no maintainer decision was required.
