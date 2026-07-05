# B1: Lock-Code Gating Audit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close six lock-code gating defects (epic #263, bundle B1) so that Child mode is correctly blocked by locked items, Parent/Individual modes are never wrongly blocked, and UI copy matches actual behavior.

**Architecture:** Each fix extracts the gating decision out of the SwiftUI View body into a small pure, statically-testable helper (following the existing `LockCodeManager.verifyCode` pure-static precedent), then routes the View through it. This is the only way to satisfy the "named regression test per fix" requirement, since SwiftUI `View` computed properties and `disabled:` expressions cannot be unit-tested directly. Behavior outside each defect's scope is unchanged; extractions are pure refactors.

**Tech Stack:** Swift 6, SwiftUI, SwiftData (custom CloudKit sync, `cloudKitDatabase: .none`), XCTest (`FoqosTests` target), swift-format (pre-commit hook).

## Global Constraints

Copied verbatim from AGENTS.md and the issue handovers. **Every task implicitly includes this section.**

- **Lock-code restriction checks MUST use `appModeManager.currentMode == .child`.** The pattern `!= .parent` is **FORBIDDEN** (it wrongly blocks Individual mode). Do not introduce it anywhere.
- **`!= .child` as an array-selector ternary is legitimate and must NOT be "fixed".** `LockCodeManager` uses `appModeManager.currentMode != .child ? lockCodes : cachedLockCodes` (lines 248, 265, 271) to *choose which code array to read* (parent's own vs. child's cached). This is not a restriction gate — leave it alone.
- **App Modes (AGENTS.md table):** Individual = no lock code possible, cannot create locked items, NOT blocked by locks. Parent = can SET code, can create locked items, full access (NOT blocked). Child = code synced from parent, blocked by locked items (requires code).
- **Never force-push or amend.** New commits only. Feature branch: `fix/b1-lockcode-gating-audit` (already created off `main`).
- Views must use `@SafeQuery` (never raw `@Query`); non-query model arrays filtered with `.valid`.
- Use `Log.<level>(_, category:)` — never `print()`. Never log lock codes or personal identifiers.
- swift-format: 2-space indent, ~100-120 col. Pre-commit hook auto-formats staged Swift files. Run `swift-format --in-place --recursive .` before committing if unsure.
- **Test naming:** `testGivenX_WhenY_ThenZ()`. **Pin time:** capture one `let now = Date()` per test, derive all other instants from it, inject via `now:` parameters. Never call `Date()` more than once per test.
- **Request code review before merging** (AGENTS.md requirement). NO LIVE USERS — pre-release; prefer structural fixes over compatibility patches, no migration constraints.

### Test infrastructure (verified against `main` @ `3cd0ab8`)

- **In-memory container** — `FoqosTests/Helpers/TestModelContainer.swift`:
  ```swift
  let container = try TestModelContainer.create()   // schema includes SavedLocation, BlockedProfiles, BlockedProfileSession
  let context = container.mainContext
  ```
- **setUp/tearDown pattern** (from `UpdateProfileTests.swift`) — isolate `UserDefaults` per test:
  ```swift
  private var container: ModelContainer!
  private var context: ModelContext!
  private var testSuiteName: String!

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "B1Tests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: testSuiteName)!)
    container = try TestModelContainer.create()
    context = container.mainContext
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: testSuiteName)
    try await super.tearDown()
  }
  ```
- **Class scaffolding:** `@MainActor final class XxxTests: XCTestCase` with `@testable import FamilyFoqos`.
- **`AppModeManager.shared` is a `@MainActor` singleton** whose `selectMode(_:)` persists `currentMode` to `UserDefaults.standard`. Tests that call `selectMode` leak global state — **capture the original mode in setUp and restore it in tearDown**.
- **`LockCodeManager.shared.overrideDefaults(_ defaults: UserDefaults?)`** swaps the manager's persistence `UserDefaults` (used today by `LockCodeThrottleTests`). Call it in setUp with the test suite, and `overrideDefaults(nil)` in tearDown. **Note:** today it only reloads *throttle* state; Task 4 extends it to also re-hydrate `cachedLockCodes`, so after that change it isolates the lock-code cache too. Until then, tests of the lock-code cache must not rely on it for isolation.
- **Fixtures:**
  ```swift
  let profile = BlockedProfiles(name: "Test")           // isManaged defaults false
  let location = SavedLocation(id: UUID(), name: "Home", latitude: 1, longitude: 2, isLocked: true)
  let code = FamilyLockCode(code: "1234", scope: .allChildren)   // hashes internally (SHA256 + salt)
  context.insert(profile); try context.save()
  ```

### Running tests (from AGENTS.md — reuse a booted simulator, never a device name)

```bash
# 1) Look up the iPhone 17 simulator UUID ONCE, then export it for the session:
xcrun simctl list devices available | grep "iPhone 17"
export SIM_UUID=<paste-the-UUID-here>   # e.g. on the current dev machine: B9E4A679-BDF3-4541-A59F-DA4BE21F80ED
# 2) Boot it ONCE per session:
xcrun simctl boot "$SIM_UUID"
# 3) Run a single new test class (reuses the booted sim):
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination "platform=iOS Simulator,id=$SIM_UUID" \
  -only-testing:FoqosTests/<ClassName> | xcpretty
```
> Every per-task command below uses `<SIM_UUID>` — substitute the real UUID (or `export SIM_UUID=...` once and use `$SIM_UUID`). Never use the device *name* in `-destination` (it clones a new ~16GB simulator each run). Simulator boot takes 3-5 min; tests run in <1s. Boot once, run many times.

### Task order & shared-file note

`Foqos/Views/BlockedProfileView.swift` is touched by Tasks 5 (#211) and 6 (#251) — do those two in order (Task 5 extracts the `editingDisabled` helper that Task 6 reuses). Task 4 (#197) does **not** touch `BlockedProfileView` under the settled fail-closed-with-cache design (it makes `canVerifyCode` correct by hydrating the cache), so it is independent. Tasks 1–4 may be done in any order; Tasks 5→6 are ordered.

| Task | Issue | Sev | File(s) | One-line fix |
|------|-------|-----|---------|--------------|
| 1 | #196 | low | ChildDashboardView | Footer copy "edit, delete, or stop" → "edit or delete" |
| 2 | #244 | low | ParentDashboardView, AppMode | Promote Individual→Parent on first lock-code set |
| 3 | #199 | critical | SavedLocationsView, SavedLocation | Gate locked-location *edit* behind lock code in Child mode |
| 4 | #197 | critical | LockCodeManager, ParentDashboardView, ChildDashboardView | Fail **closed with cache**: verify against last-synced code offline (no airplane-mode bypass) |
| 5 | #211 | high | BlockedProfileView | Trigger selectors reuse `editingDisabled` (add child-mode guard) |
| 6 | #251 | low | BlockedProfileView | Geofence selector reuse `editingDisabled` |

---

## Task 1: #196 — Fix ChildDashboardView footer copy (stopping is NOT lock-gated)

**Decided scope (maintainer, deviation report #7):** Stopping a locked/managed profile stays **un-gated by design**. Do **NOT** add any lock-code check to any stop path. The only fix is the false footer copy. An audit for other copy making the same promise was already performed (see below) — line 576 is the **only** offending string.

**Audit result (already done — no other copy promises stop-gating):** every other lock-code string is already correct (`ChildDashboardView.swift:296`, `AddLocationView.swift:266`, `ParentDashboardView.swift:635`, `BlockedProfileView.swift:443` all say "edit or delete"); all `stop`-related copy elsewhere (NFC/QR/geofence stop conditions) legitimately describes physical stop conditions, not lock codes. No `.strings`/`.stringsdict` files exist (all copy is inline). **Do not change anything except line 576.**

**Files:**
- Modify: `Foqos/Views/Child/ChildDashboardView.swift:575-577`
- Test: `FoqosTests/ChildDashboardCopyTests.swift` (create)

**Interfaces:**
- Produces: `EditLockedProfilesSheet.lockedProfilesFooter` — a `static let String` constant holding the footer copy, so the copy has a testable surface.

- [ ] **Step 1: Write the failing test**

Create `FoqosTests/ChildDashboardCopyTests.swift`:

```swift
import XCTest

@testable import FamilyFoqos

@MainActor
final class ChildDashboardCopyTests: XCTestCase {
  func testGivenLockedProfilesFooter_WhenRead_ThenPromisesEditOrDeleteNotStop() {
    let footer = EditLockedProfilesSheet.lockedProfilesFooter
    XCTAssertEqual(footer, "Locked profiles require the lock code to edit or delete.")
    XCTAssertFalse(
      footer.lowercased().contains("stop"),
      "Footer must not promise that stopping is lock-gated (stopping is un-gated by design, deviation #7)"
    )
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<SIM_UUID>' \
  -only-testing:FoqosTests/ChildDashboardCopyTests | xcpretty
```
Expected: FAIL to compile with "type 'EditLockedProfilesSheet' has no member 'lockedProfilesFooter'".

- [ ] **Step 3: Extract the constant and fix the copy**

In `Foqos/Views/Child/ChildDashboardView.swift`, find the `EditLockedProfilesSheet` struct. Add the static constant (place it just inside the struct, above `body`):

```swift
  static let lockedProfilesFooter = "Locked profiles require the lock code to edit or delete."
```

Then change the footer (currently lines 575-577):

```swift
        } footer: {
          Text("Locked profiles require the lock code to edit, delete, or stop.")
        }
```

to:

```swift
        } footer: {
          Text(EditLockedProfilesSheet.lockedProfilesFooter)
        }
```

- [ ] **Step 4: Run the test to verify it passes**

Run the same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FoqosTests/ChildDashboardCopyTests.swift Foqos/Views/Child/ChildDashboardView.swift
git commit -m "fix(#196): correct ChildDashboardView footer — stopping is not lock-gated"
```

---

## Task 2: #244 — Promote Individual→Parent when a lock code is set

**The defect:** `LockCodeSetupView` shows "This makes your device a parent device" (`LockCodeEntryView.swift:316`) and `LockCodeManager.setLockCode` deliberately permits Individual mode (guard is `!= .child`, `LockCodeManager.swift:70`), but nothing calls `selectMode(.parent)`. `grep 'selectMode(.parent)'` across `Foqos/` returns **zero** call sites — the only paths to `.parent` are share-acceptance (`FoqosApp.swift`) and CloudKit enforced-mode. So an Individual user sets a code, the card claims parent status, but no Parent-Controlled toggles ever appear.

**Chosen fix (Option A — make behavior match the on-screen promise):** After a successful first `setLockCode` from the dashboard, promote Individual → Parent. This aligns with the on-screen copy and the codebase's pervasive `!= .child` "Individual may own codes" design. The mode-transition **decision** is extracted to a pure static so it can be unit-tested (the `selectMode` side effect itself lives in the View closure and is not unit-testable without CloudKit DI that does not exist).

> Rejected — Option B (reword copy + restrict `setLockCode` to `== .parent`): larger blast radius, contradicts the intentional "Individual mode users can also set lock codes" comments in `LockCodeManager` and its `handleModeChange` behavior. Not chosen. (Note for reviewer: Option A is a real behavior change — an Individual user who sets a code will now see Parent-Controlled toggles. This is exactly what the copy promises, so it is intended.)

**Files:**
- Modify: `Foqos/Models/AppMode.swift` (add pure static helper on `AppModeManager`)
- Modify: `Foqos/Views/Parent/ParentDashboardView.swift:161-177` (call it in the `onSave` closure)
- Modify: `AGENTS.md:305-309` (mode-table footnote — document that setting a code promotes Individual→Parent)
- Test: `FoqosTests/AppModePromotionTests.swift` (create)

**Interfaces:**
- Produces: `AppModeManager.modeAfterSettingLockCode(from:)` — `static func modeAfterSettingLockCode(from currentMode: AppMode) -> AppMode?`; returns `.parent` iff `currentMode == .individual`, else `nil`.

- [ ] **Step 1: Write the failing test**

Create `FoqosTests/AppModePromotionTests.swift`:

```swift
import XCTest

@testable import FamilyFoqos

@MainActor
final class AppModePromotionTests: XCTestCase {
  func testGivenIndividualMode_WhenSettingLockCode_ThenPromotesToParent() {
    XCTAssertEqual(AppModeManager.modeAfterSettingLockCode(from: .individual), .parent)
  }

  func testGivenParentMode_WhenSettingLockCode_ThenNoModeChange() {
    XCTAssertNil(AppModeManager.modeAfterSettingLockCode(from: .parent))
  }

  func testGivenChildMode_WhenSettingLockCode_ThenNoModeChange() {
    XCTAssertNil(AppModeManager.modeAfterSettingLockCode(from: .child))
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<SIM_UUID>' \
  -only-testing:FoqosTests/AppModePromotionTests | xcpretty
```
Expected: FAIL to compile — "type 'AppModeManager' has no member 'modeAfterSettingLockCode'".

- [ ] **Step 3: Add the pure helper**

In `Foqos/Models/AppMode.swift`, add to `AppModeManager` (or an extension on it in the same file):

```swift
  /// The mode a device should switch to after successfully setting its first lock code.
  /// Individual devices become Parent (a lock code makes this a parent device);
  /// Parent and Child devices are unchanged. Returns nil when no switch is needed.
  static func modeAfterSettingLockCode(from currentMode: AppMode) -> AppMode? {
    currentMode == .individual ? .parent : nil
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run the same command as Step 2. Expected: PASS.

- [ ] **Step 5: Wire the promotion into the dashboard save closure**

In `Foqos/Views/Parent/ParentDashboardView.swift`, the `onSave` closure (currently lines 164-175) reads:

```swift
          onSave: { code in
            Task {
              do {
                try await lockCodeManager.setLockCode(code, scope: .allChildren)
              } catch {
                await MainActor.run {
                  errorMessage = error.localizedDescription
                  showError = true
                }
              }
            }
          }
```

Change it to promote after a successful set:

```swift
          onSave: { code in
            Task {
              do {
                let previousMode = appModeManager.currentMode
                try await lockCodeManager.setLockCode(code, scope: .allChildren)
                if let newMode = AppModeManager.modeAfterSettingLockCode(from: previousMode) {
                  await MainActor.run { appModeManager.selectMode(newMode) }
                }
              } catch {
                await MainActor.run {
                  errorMessage = error.localizedDescription
                  showError = true
                }
              }
            }
          }
```

> `appModeManager` is already available in this view as `@ObservedObject private var appModeManager = AppModeManager.shared` (line 21); it already calls `appModeManager.selectMode(.individual)` at lines 212/238, so no new plumbing is needed. `selectMode` is `@MainActor`; the `await MainActor.run` keeps it main-actor-safe from the `Task`.

- [ ] **Step 6: Document the promotion in the AGENTS.md mode table**

The mode table (`AGENTS.md:305-309`) says Individual has "Lock Code: None possible" — under this fix an Individual device *can* set a code, which promotes it to Parent, so it never persists as Individual-with-a-code. Add a footnote directly under the table (after the `| **Child** | ... |` row, line 309) so the invariant is explicit:

```markdown
| **Child** | Synced from parent | Yes | No | Yes (requires code) |

> **Individual → Parent promotion:** an Individual device can set a lock code via the Family
> Controls Dashboard (the only user-initiated path to Parent — `ModeSelectionView` offers only
> Individual/Child). Doing so **promotes the device to Parent** in the same action, so the
> "Individual: Can Create Locked Items = No" invariant holds — a device never persists as
> Individual *with* a lock code. The `setLockCode` guard therefore stays `!= .child` (not
> `== .parent`), otherwise the promotion would deadlock.
```

- [ ] **Step 7: Build to verify the wiring compiles**

Run:
```bash
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug build 2>&1 | xcpretty
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
swift-format --in-place Foqos/Models/AppMode.swift Foqos/Views/Parent/ParentDashboardView.swift
git add Foqos/Models/AppMode.swift Foqos/Views/Parent/ParentDashboardView.swift AGENTS.md FoqosTests/AppModePromotionTests.swift
git commit -m "fix(#244): promote Individual to Parent mode when a lock code is set"
```

---

## Task 3: #199 — Gate locked-SavedLocation editing behind the lock code in Child mode

**The defect:** `SavedLocationsView.handleEdit` (lines 152-156) opens **any** location for editing; its comment falsely claims "In Child mode, AddLocationView will prevent saving changes to locked locations" — but `AddLocationView` has **no** such guard (`saveLocation()` calls `SavedLocation.update` unconditionally; `showLockToggle` only *hides* the toggle). Deletion **is** correctly gated (`handleDelete`, lines 158-166) and the toggle label promises "Requires lock code to edit **or delete**". A child can move a locked geofence location's pin/radius with no code, silently moving the fence for every profile referencing it by UUID.

**Chosen fix:** Mirror the existing, working `handleDelete` gate for `handleEdit` — present `LockCodeEntryView` before opening the editor when the location is locked and the mode is Child. Extract the gate predicate to a pure method on `SavedLocation` so it is unit-testable, and route **both** `handleEdit` and `handleDelete` through it (DRY). Remove the false comment.

**Files:**
- Modify: `Foqos/Models/SavedLocation.swift` (add pure predicate)
- Modify: `Foqos/Views/SavedLocationsView.swift` (gate `handleEdit`; new `@State`; new `.sheet`; refactor `handleDelete` to use the predicate; delete false comment)
- Test: `FoqosTests/SavedLocationLockGateTests.swift` (create)

**Interfaces:**
- Produces: `SavedLocation.requiresLockCodeToModify(mode:)` — `func requiresLockCodeToModify(mode: AppMode) -> Bool`; returns `isLocked && mode == .child`.

- [ ] **Step 1: Write the failing test**

Create `FoqosTests/SavedLocationLockGateTests.swift`:

```swift
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SavedLocationLockGateTests: XCTestCase {
  private func makeLocation(isLocked: Bool) -> SavedLocation {
    SavedLocation(id: UUID(), name: "Home", latitude: 1, longitude: 2, isLocked: isLocked)
  }

  func testGivenLockedLocation_WhenChildMode_ThenRequiresLockCode() {
    let location = makeLocation(isLocked: true)
    XCTAssertTrue(location.requiresLockCodeToModify(mode: .child))
  }

  func testGivenLockedLocation_WhenParentMode_ThenNoLockCodeRequired() {
    let location = makeLocation(isLocked: true)
    XCTAssertFalse(location.requiresLockCodeToModify(mode: .parent))
  }

  func testGivenLockedLocation_WhenIndividualMode_ThenNoLockCodeRequired() {
    let location = makeLocation(isLocked: true)
    XCTAssertFalse(location.requiresLockCodeToModify(mode: .individual))
  }

  func testGivenUnlockedLocation_WhenChildMode_ThenNoLockCodeRequired() {
    let location = makeLocation(isLocked: false)
    XCTAssertFalse(location.requiresLockCodeToModify(mode: .child))
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<SIM_UUID>' \
  -only-testing:FoqosTests/SavedLocationLockGateTests | xcpretty
```
Expected: FAIL to compile — "value of type 'SavedLocation' has no member 'requiresLockCodeToModify'".

- [ ] **Step 3: Add the pure predicate**

In `Foqos/Models/SavedLocation.swift`, add to the `SavedLocation` class (or an extension in the same file):

```swift
  /// Whether modifying (editing or deleting) this location must be gated behind the
  /// parent lock code. Only Child mode is blocked by locked items (AGENTS.md mode table).
  func requiresLockCodeToModify(mode: AppMode) -> Bool {
    isLocked && mode == .child
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run the same command as Step 2. Expected: PASS.

- [ ] **Step 5: Gate `handleEdit` and route `handleDelete` through the predicate**

In `Foqos/Views/SavedLocationsView.swift`:

(a) Add new `@State` near the existing `pendingDeleteLocation` / `showingLockCodeEntry` declarations:

```swift
  @State private var pendingEditLocation: SavedLocation?
  @State private var showingLockCodeEntryForEdit = false
```

(b) Replace `handleEdit` (currently lines 152-156):

```swift
  private func handleEdit(_ location: SavedLocation) {
    // Note: Locked locations can be edited freely in Individual and Parent modes.
    // In Child mode, AddLocationView will prevent saving changes to locked locations.
    locationToEdit = location
  }
```

with (removes the false comment; mirrors the delete gate):

```swift
  private func handleEdit(_ location: SavedLocation) {
    if location.requiresLockCodeToModify(mode: appModeManager.currentMode) {
      pendingEditLocation = location
      showingLockCodeEntryForEdit = true
    } else {
      locationToEdit = location
    }
  }
```

(c) Refactor `handleDelete` (currently lines 158-166) to use the same predicate (DRY):

```swift
  private func handleDelete(_ location: SavedLocation) {
    if location.requiresLockCodeToModify(mode: appModeManager.currentMode) {
      pendingDeleteLocation = location
      showingLockCodeEntry = true
    } else {
      // Directly delete - confirmation was already shown in AddLocationView
      deleteLocation(location)
    }
  }
```

(d) Add a second `.sheet` mirroring the existing delete-gate sheet (currently lines 121-135). Place it adjacent to that sheet:

```swift
      .sheet(isPresented: $showingLockCodeEntryForEdit) {
        LockCodeEntryView(
          title: "Enter Lock Code",
          subtitle: "This location is locked. Enter the lock code to edit it.",
          onVerify: { code in
            lockCodeManager.validateCode(code)
          },
          onSuccess: {
            if let location = pendingEditLocation {
              locationToEdit = location
            }
            pendingEditLocation = nil
          }
        )
      }
```

> This view already holds `@ObservedObject private var appModeManager = AppModeManager.shared` (line 10) and `@ObservedObject private var lockCodeManager = LockCodeManager.shared` (line 11), and `locationToEdit` already drives the `AddLocationView` editor sheet — so no other wiring changes are needed.

- [ ] **Step 6: Build to verify it compiles**

Run:
```bash
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug build 2>&1 | xcpretty
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
swift-format --in-place Foqos/Models/SavedLocation.swift Foqos/Views/SavedLocationsView.swift
git add Foqos/Models/SavedLocation.swift Foqos/Views/SavedLocationsView.swift FoqosTests/SavedLocationLockGateTests.swift
git commit -m "fix(#199): gate locked-location editing behind lock code in Child mode"
```

---

## Task 4: #197 — Fail closed with cache when child lock codes cannot be fetched

> ### ✅ MAINTAINER DECISION (2026-07-05) — SETTLED, not open for redesign
>
> **Decision: fail-closed-with-cache.** When lock codes cannot be fetched/verified (offline, CloudKit error, iCloud signed out), verify against the **last-synced locally cached code**; fail closed (editing stays locked) **only if no code has ever been synced**. **Never fail open** — the current `canVerifyCode` clause makes airplane mode a one-tap bypass.
>
> **Accepted residual (maintainer):** after a parent changes the PIN, the child device accepts the *old* cached PIN until the next sync — this is the existing #208 staleness window, shrunk by B2's cache-refresh fix. It is **not** new exposure introduced by this decision.
>
> **The defect being closed:** In Child mode, `LockCodeManager.canVerifyCode` is `!cachedLockCodes.isEmpty`. `cachedLockCodes` is **in-memory-only**, populated solely by `fetchSharedLockCodes()` on launch/mode-change, **never persisted**. The CloudKit fetch layer is itself fail-open: offline, `findSharedZoneByName()` returns nil → `(codes: [], isConnected: false)` with **no throw**; a mid-flight `CKError` is swallowed → `(codes: [], isConnected: true)` (this task **also fixes** that catch — see Step 6a — so the error case reports disconnected). So after a cold launch in Airplane Mode (or any failed/raced fetch), `cachedLockCodes == []`, `canVerifyCode == false`, and every gate requiring `canVerifyCode` **fails open** (child can strip a managed profile, unlock banner hides, "Leave Family" skips the PIN).

**The fix (fail-closed-with-cache):** persist the last-synced codes to the manager's injectable `UserDefaults`, and **hydrate `cachedLockCodes` from that store** — on launch (in `init`) and whenever a fetch is *not* a trusted connected result. Because verification (`verifyCode` / `validateCode`) and `canVerifyCode` all read `cachedLockCodes`, hydration makes them correct offline **with no change to any gate expression**: the child can still enter the cached code and unlock offline, and the lock only "fails open" when no code was ever synced (i.e. no managed lock exists). A **connected** result — even an empty one — is trusted and *replaces* the cache/store (this is how "parent cleared the PIN" propagates). A **disconnected** result is ignored in favour of the persisted codes.

The trust decision is extracted to a pure static so it is unit-testable.

**Files:**
- Modify: `Foqos/CloudKit/CloudKitNetworkService+LockCodes.swift:120-125` (make a swallowed `CKError` report `isConnected: false`, so it cannot masquerade as a trusted "parent cleared the PIN" result — **prerequisite** for `resolveLockCodes` to be sound)
- Modify: `Foqos/Utils/LockCodeManager.swift` (persistence key + `resolveLockCodes` static + persist/load helpers; hydrate in `init`; re-hydrate in `overrideDefaults`; update `fetchSharedLockCodes`)
- Modify: `Foqos/Views/Parent/ParentDashboardView.swift:53-58` (fix the stale "work offline" comment — the claim is now *true* for the cache, but reword to describe the persisted cache accurately)
- Modify: `Foqos/Views/Child/ChildDashboardView.swift:603-605` (`hasLockCode` reads a *different*, non-persisted in-memory source — route it through the hydrated manager)
- Test: `FoqosTests/LockCodeFailClosedTests.swift` (create)

> **Why the network-layer fix is a prerequisite (greptile P1).** Today `CloudKitNetworkService+LockCodes.swift` swallows a `CKError` that occurs *after* the shared zone is found and falls through to `return (codes: codes, isConnected: true)` with `codes == []` — wire-identical to a genuine "parent cleared the PIN" (connected + empty). Because `resolveLockCodes` trusts `isConnected` as its sole signal, that case would resolve to `(cache: [], persist: [])` and `persistLockCodes([])` would **wipe the on-device store**, so the next offline session fails open again — the exact bypass this task closes. Fixing the catch to report `isConnected: false` cleanly separates the three cases: zone-not-found → disconnected (preserve), zone-found + CKError → disconnected (preserve), zone-found + empty + no error → connected (parent cleared). Do this **before** wiring `resolveLockCodes`.

> **No change to `Foqos/Views/BlockedProfileView.swift` in this task.** `editingDisabled` (lines 129-134), the banner (lines 252-254), and `childNeedsPinCheck` (`ParentDashboardView` lines 79-82) already gate on `canVerifyCode`, which becomes correct automatically once `cachedLockCodes` is hydrated. Do **not** modify those expressions here. (`hasAnyLockCode` is `!lockCodes.isEmpty`, and `lockCodes` is always empty in Child mode, so `childNeedsPinCheck` already reduces to `isChildMode && canVerifyCode`.)

**Interfaces:**
- Produces: `LockCodeManager.resolveLockCodes(fetched:isConnected:persisted:)` — `static func ... -> (cache: [FamilyLockCode], persist: [FamilyLockCode])`. Connected → `(fetched, fetched)` (trusted; empty means parent cleared). Disconnected → `(persisted, persisted)` (keep last-synced; verify offline).

- [ ] **Step 1: Write the failing test (the trust decision)**

Create `FoqosTests/LockCodeFailClosedTests.swift`:

```swift
import XCTest

@testable import FamilyFoqos

@MainActor
final class LockCodeFailClosedTests: XCTestCase {
  private func makeCode() -> FamilyLockCode {
    FamilyLockCode(code: "1234", scope: .allChildren)
  }

  // Connected results are trusted: they replace both the verification cache and the store.
  func testGivenConnectedNonEmptyFetch_WhenResolving_ThenCacheAndStoreUseFetched() {
    let fetched = [makeCode()]
    let result = LockCodeManager.resolveLockCodes(
      fetched: fetched, isConnected: true, persisted: [])
    XCTAssertEqual(result.cache.count, 1)
    XCTAssertEqual(result.persist.count, 1)
  }

  // Connected + empty = parent genuinely cleared the PIN → cache and store clear (unlock).
  func testGivenConnectedEmptyFetch_WhenResolving_ThenClearsCachedCode() {
    let result = LockCodeManager.resolveLockCodes(
      fetched: [], isConnected: true, persisted: [makeCode()])
    XCTAssertTrue(result.cache.isEmpty)
    XCTAssertTrue(result.persist.isEmpty)
  }

  // Disconnected (offline / CloudKit error) → ignore the empty network result, verify
  // against the last-synced persisted code. This is the airplane-mode bypass being closed.
  func testGivenOfflineFetch_WhenResolving_ThenVerifiesAgainstLastSyncedCode() {
    let persisted = [makeCode()]
    let result = LockCodeManager.resolveLockCodes(
      fetched: [], isConnected: false, persisted: persisted)
    XCTAssertEqual(result.cache.count, 1, "offline must verify against the last-synced cached code")
    XCTAssertEqual(result.persist.count, 1, "offline must not clear the persisted code")
  }

  // No code ever synced + offline → nothing to verify (no managed lock exists yet).
  func testGivenNeverSyncedAndOffline_WhenResolving_ThenNoCachedCode() {
    let result = LockCodeManager.resolveLockCodes(
      fetched: [], isConnected: false, persisted: [])
    XCTAssertTrue(result.cache.isEmpty)
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<SIM_UUID>' \
  -only-testing:FoqosTests/LockCodeFailClosedTests | xcpretty
```
Expected: FAIL to compile — "type 'LockCodeManager' has no member 'resolveLockCodes'".

- [ ] **Step 3: Add the persistence key, the pure static, and the persist/load helpers**

In `Foqos/Utils/LockCodeManager.swift`, add a key alongside the existing `ThrottleKey` enum (lines 342-345):

```swift
  private enum CacheKey {
    static let childLockCodes = "family_foqos_child_lock_codes"
  }
```

Add the pure static (near the existing `static func verifyCode`, following that precedent):

```swift
  /// Resolve the verification cache and the persisted store after a fetch (#197).
  /// A CONNECTED result is trusted and replaces both — even when empty, which is how a
  /// parent clearing the PIN propagates to the child. A DISCONNECTED result (offline /
  /// CloudKit error, which the network layer returns as an empty, non-throwing tuple) is
  /// ignored in favour of the last-synced persisted codes, so the child can still verify
  /// the cached code offline. The lock only "fails open" when no code was ever synced.
  static func resolveLockCodes(
    fetched: [FamilyLockCode],
    isConnected: Bool,
    persisted: [FamilyLockCode]
  ) -> (cache: [FamilyLockCode], persist: [FamilyLockCode]) {
    isConnected ? (cache: fetched, persist: fetched) : (cache: persisted, persist: persisted)
  }
```

Add the persist/load helpers (private instance methods; they use the same injectable
`throttleDefaults` that `overrideDefaults(_:)` swaps, so tests can point them at a scratch suite):

```swift
  private func loadPersistedLockCodes() -> [FamilyLockCode] {
    guard let data = throttleDefaults.data(forKey: CacheKey.childLockCodes),
      let codes = try? JSONDecoder().decode([FamilyLockCode].self, from: data)
    else {
      return []
    }
    return codes
  }

  private func persistLockCodes(_ codes: [FamilyLockCode]) {
    if let data = try? JSONEncoder().encode(codes) {
      throttleDefaults.set(data, forKey: CacheKey.childLockCodes)
    }
  }
```

> `FamilyLockCode` is a `Codable` struct (verified: `Foqos/Models/FamilyLockCode.swift:21`), so `JSONEncoder`/`JSONDecoder` round-trips `[FamilyLockCode]` directly. The model's own TODO (lines 65-67) already accepts SHA256+salt for this app's threat model, so caching the hashes locally is consistent with existing design.

- [ ] **Step 4: Run the test to verify it passes**

Run the same command as Step 2. Expected: PASS (4 tests green).

- [ ] **Step 5: Hydrate the cache on launch**

In `Foqos/Utils/LockCodeManager.swift`, `private init(...)` (lines 30-38) currently ends with `loadThrottleState()`. Add a hydration call so a cold offline launch has the last-synced codes *before* any network fetch:

```swift
  private init(
    cloudKitManager: CloudKitManager = .shared,
    appModeManager: AppModeManager = .shared
  ) {
    self.cloudKitManager = cloudKitManager
    self.appModeManager = appModeManager
    setupBindings()
    loadThrottleState()
    cachedLockCodes = loadPersistedLockCodes()
  }
```

> Hydrating unconditionally is safe: `cachedLockCodes` is only read on the child verification path (parent/individual modes read `lockCodes`).

Also make `overrideDefaults(_:)` re-hydrate the cache, so a test that swaps in a scratch suite actually isolates the lock-code cache (today it only reloads throttle state — the cache stays hydrated from whatever `init` read). Change `overrideDefaults` (lines 395-397) from:
```swift
  func overrideDefaults(_ defaults: UserDefaults?) {
    throttleDefaults = defaults ?? .standard
    loadThrottleState()
  }
```
to:
```swift
  func overrideDefaults(_ defaults: UserDefaults?) {
    throttleDefaults = defaults ?? .standard
    loadThrottleState()
    cachedLockCodes = loadPersistedLockCodes()
  }
```

- [ ] **Step 6: Fix the network layer, then route the fetch through `resolveLockCodes`**

**(a) Make a swallowed `CKError` report disconnected (greptile P1 — do this first).** In `Foqos/CloudKit/CloudKitNetworkService+LockCodes.swift`, `fetchSharedLockCodes()` (lines 96-125), the `catch` at lines 120-124 currently logs and falls through to `return (codes: codes, isConnected: true)`:
```swift
    } catch {
      Log.error(
        "Failed to fetch lock codes from zone \(zone.zoneID): \(error)", category: .cloudKit)
    }

    return (codes: codes, isConnected: true)
```
Change the `catch` to return disconnected so a transient error can never masquerade as "parent cleared the PIN":
```swift
    } catch {
      Log.error(
        "Failed to fetch lock codes from zone \(zone.zoneID): \(error)", category: .cloudKit)
      // A CKError here means we could not read the family data — report DISCONNECTED so the
      // caller preserves the last-synced cache instead of treating [] as "parent cleared" (#197).
      return (codes: [], isConnected: false)
    }

    return (codes: codes, isConnected: true)
```
> Blast radius: `isConnectedToFamily` also feeds three connection-indicator reads (`AuthorizationVerifier.swift:171`, `ParentDashboardView.swift:138`, `ChildDashboardView.swift:198`). Reporting "disconnected" on a real CKError is *more* correct for all three; confirm none rely on the old fall-through-as-connected behavior. This is a code change — it has **no** standalone unit test (it hits CloudKit); its resolved behavior is covered by the `testGivenOfflineFetch_…` case in Step 1 (disconnected → preserve cache), and the change itself is verified by build + inspection.

**(b) Route the fetch through `resolveLockCodes`.** In `LockCodeManager.fetchSharedLockCodes()` (lines 178-205), replace the `do { ... } catch { ... }` body (currently lines 195-204):

```swift
    do {
      let codes = try await cloudKitManager.fetchSharedLockCodes()
      self.cachedLockCodes = codes
      self.error = nil

      // Also check for pending commands from parent
      await processPendingCommands()
    } catch {
      self.error = error.localizedDescription
    }
```

with:

```swift
    do {
      let codes = try await cloudKitManager.fetchSharedLockCodes()
      // Fail-closed-with-cache (#197): trust a CONNECTED result (even empty = parent cleared)
      // and persist it; on a disconnected/failed fetch keep the last-synced cached codes so
      // verification still works offline and the lock never fails open.
      let resolved = Self.resolveLockCodes(
        fetched: codes,
        isConnected: cloudKitManager.isConnectedToFamily,
        persisted: loadPersistedLockCodes()
      )
      self.cachedLockCodes = resolved.cache
      persistLockCodes(resolved.persist)
      self.error = nil

      // Also check for pending commands from parent
      await processPendingCommands()
    } catch {
      // Defensive: the network layer returns empty without throwing for offline/CKError, but
      // if it ever does throw, keep the last-synced codes rather than falling back to empty.
      self.cachedLockCodes = loadPersistedLockCodes()
      self.error = error.localizedDescription
    }
```

> Do **not** touch the `guard appModeManager.currentMode == .child` at line 179, the auth-loss branch (lines 186-193), or the `!= .child` array-selector ternaries in `canVerifyCode`/`verifyCode`/`validateCode`. `cloudKitManager.fetchSharedLockCodes()` already sets `cloudKitManager.isConnectedToFamily` from the network layer's `isConnected` before returning (`CloudKitManager.swift:112-117`).

- [ ] **Step 7: Fix the two remaining fail-open reads**

(a) `Foqos/Views/Parent/ParentDashboardView.swift` — the stale comment (lines 53-58). Change the third comment line:
```swift
  /// Independent of iCloud — PIN verification uses cached lock codes that work offline
```
to:
```swift
  /// Independent of iCloud — PIN verification uses the last-synced lock codes cached on-device
```
> No logic change here: `childNeedsPinCheck` (lines 79-82) already reads `canVerifyCode`, which is now hydrated-correct offline. The Leave-Family-skips-PIN hole closes automatically.

(b) `Foqos/Views/Child/ChildDashboardView.swift` — `hasLockCode` (lines 603-605) currently reads the *separate*, non-persisted `cloudKitManager.sharedLockCodes`, which is empty offline → "Remove Parental lock" leaves without a PIN. Route it through the hydrated manager:
```swift
  private var hasLockCode: Bool {
    lockCodeManager.canVerifyCode
  }
```
> Confirm this view holds `lockCodeManager` (search the file for `LockCodeManager.shared`). If it is only reachable as `LockCodeManager.shared`, use `LockCodeManager.shared.canVerifyCode`. Do not change the surrounding Leave-share flow.

- [ ] **Step 8: Build, then run the new + existing lock tests (regression)**

Run:
```bash
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug build 2>&1 | xcpretty
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<SIM_UUID>' \
  -only-testing:FoqosTests/LockCodeFailClosedTests -only-testing:FoqosTests/LockCodeVerifyTests \
  -only-testing:FoqosTests/LockCodeThrottleTests | xcpretty
```
Expected: BUILD SUCCEEDED; all three test classes PASS (existing lock tests still green).

- [ ] **Step 9: Commit**

```bash
swift-format --in-place Foqos/Utils/LockCodeManager.swift \
  Foqos/Views/Parent/ParentDashboardView.swift Foqos/Views/Child/ChildDashboardView.swift
git add Foqos/Utils/LockCodeManager.swift Foqos/Views/Parent/ParentDashboardView.swift \
  Foqos/Views/Child/ChildDashboardView.swift FoqosTests/LockCodeFailClosedTests.swift
git commit -m "fix(#197): fail closed with cached last-synced lock code (no airplane-mode bypass)"
```


---

## Task 5: #211 — Trigger selectors must reuse the child-mode-gated `editingDisabled`

**The defect:** `StartTriggerSelector` (line 338) and `StopConditionSelector` (line 378) are disabled with `isBlocking || (isManagedProfile && !isUnlockedForEditing)` — **missing** the `&& appModeManager.currentMode == .child && lockCodeManager.canVerifyCode` qualifiers that `editingDisabled` (lines 129-134) applies. `isUnlockedForEditing` is only ever true after the child enters the lock code (the unlock affordance is Child-mode-only). So in **Parent mode**, a managed profile's trigger sections are permanently greyed out with **no** unlock path — the exact AGENTS.md anti-pattern (only Child mode may be blocked by locks). The secondary case (Child mode before codes sync) is fixed by the same change.

**Chosen fix:** Extract the `editingDisabled` truth table into a pure static `ProfileEditGate.editingDisabled(...)`, route the View's `editingDisabled` property through it (pure refactor, no behavior change), and route both trigger selectors' `disabled:` args through the **same** `editingDisabled` property. This gives a testable surface and makes the selectors inherit the correct child-mode gate.

**Files:**
- Create: `Foqos/Utils/ProfileEditGate.swift`
- Modify: `Foqos/Views/BlockedProfileView.swift` (`editingDisabled` → call the static; lines 338, 378 → `disabled: editingDisabled`)
- Test: `FoqosTests/ProfileEditGateTests.swift` (create)

**Interfaces:**
- Consumes: `LockCodeManager.canVerifyCode` (the `lockActive` argument at the call site — correct offline once Task 4's cache hydration lands, but Task 5 does not depend on Task 4).
- Produces: `ProfileEditGate.editingDisabled(isBlocking:isManaged:isUnlocked:mode:lockActive:)` — `static func ... -> Bool`; returns `isBlocking || (isManaged && !isUnlocked && mode == .child && lockActive)`.

- [ ] **Step 1: Write the failing test**

Create `FoqosTests/ProfileEditGateTests.swift`:

```swift
import XCTest

@testable import FamilyFoqos

final class ProfileEditGateTests: XCTestCase {
  // Parent mode with a managed, not-unlocked profile MUST remain editable (#211 core bug).
  func testGivenParentModeManagedProfile_WhenNotUnlocked_ThenEditingNotDisabled() {
    XCTAssertFalse(
      ProfileEditGate.editingDisabled(
        isBlocking: false, isManaged: true, isUnlocked: false, mode: .parent, lockActive: true))
  }

  func testGivenIndividualModeManagedProfile_WhenNotUnlocked_ThenEditingNotDisabled() {
    XCTAssertFalse(
      ProfileEditGate.editingDisabled(
        isBlocking: false, isManaged: true, isUnlocked: false, mode: .individual, lockActive: true))
  }

  // Child mode with an active lock and not unlocked MUST be disabled.
  func testGivenChildModeManagedProfile_WhenLockedAndNotUnlocked_ThenEditingDisabled() {
    XCTAssertTrue(
      ProfileEditGate.editingDisabled(
        isBlocking: false, isManaged: true, isUnlocked: false, mode: .child, lockActive: true))
  }

  // Child mode, unlocked → editable.
  func testGivenChildModeManagedProfile_WhenUnlocked_ThenEditingNotDisabled() {
    XCTAssertFalse(
      ProfileEditGate.editingDisabled(
        isBlocking: false, isManaged: true, isUnlocked: true, mode: .child, lockActive: true))
  }

  // Active session always disables editing regardless of mode.
  func testGivenActiveSession_WhenAnyMode_ThenEditingDisabled() {
    XCTAssertTrue(
      ProfileEditGate.editingDisabled(
        isBlocking: true, isManaged: false, isUnlocked: true, mode: .individual, lockActive: false))
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<SIM_UUID>' \
  -only-testing:FoqosTests/ProfileEditGateTests | xcpretty
```
Expected: FAIL to compile — "cannot find 'ProfileEditGate' in scope".

- [ ] **Step 3: Create the pure gate**

Create `Foqos/Utils/ProfileEditGate.swift`:

```swift
import Foundation

/// Pure decision for whether editing a BlockedProfile's settings should be disabled.
/// Extracted from BlockedProfileView so it can be unit-tested and reused by every
/// selector in the form (start/stop triggers, geofence). Only Child mode is blocked by
/// locks (AGENTS.md mode table): `mode == .child`, never `!= .parent`.
enum ProfileEditGate {
  static func editingDisabled(
    isBlocking: Bool,
    isManaged: Bool,
    isUnlocked: Bool,
    mode: AppMode,
    lockActive: Bool
  ) -> Bool {
    isBlocking || (isManaged && !isUnlocked && mode == .child && lockActive)
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run the same command as Step 2. Expected: PASS.

- [ ] **Step 5: Route the View's `editingDisabled` through the static (pure refactor)**

In `Foqos/Views/BlockedProfileView.swift`, replace `editingDisabled` (lines 129-134, as left by Task 4):

```swift
  private var editingDisabled: Bool {
    ProfileEditGate.editingDisabled(
      isBlocking: isBlocking,
      isManaged: isManagedProfile,
      isUnlocked: isUnlockedForEditing,
      mode: appModeManager.currentMode,
      lockActive: lockCodeManager.canVerifyCode
    )
  }
```

- [ ] **Step 6: Route both trigger selectors through `editingDisabled`**

In the same file, change the `StartTriggerSelector` `disabled:` arg (line 338):
```swift
            disabled: isBlocking || (isManagedProfile && !isUnlockedForEditing),
```
to:
```swift
            disabled: editingDisabled,
```

And the `StopConditionSelector` `disabled:` arg (line 378) identically:
```swift
            disabled: editingDisabled,
```

> `editingDisabled` folds in `isBlocking`, so the `isBlocking` gate is preserved. Now Parent/Individual mode (where `editingDisabled` is false) can edit triggers, while a locked Child profile disables them — matching every other section of the form.

- [ ] **Step 7: Build and run**

Run:
```bash
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug build 2>&1 | xcpretty
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<SIM_UUID>' \
  -only-testing:FoqosTests/ProfileEditGateTests | xcpretty
```
Expected: BUILD SUCCEEDED; PASS.

- [ ] **Step 8: Commit**

```bash
swift-format --in-place Foqos/Utils/ProfileEditGate.swift Foqos/Views/BlockedProfileView.swift
git add Foqos/Utils/ProfileEditGate.swift Foqos/Views/BlockedProfileView.swift FoqosTests/ProfileEditGateTests.swift
git commit -m "fix(#211): trigger selectors reuse editingDisabled (only Child mode blocked)"
```

---

## Task 6: #251 — Geofence (Location Restrictions) selector must match the trigger selectors

**The defect:** `BlockedProfileGeofenceSelector` (call site lines 359-365) is disabled with `disabled: isBlocking` **only**, while the trigger selectors are gated by the managed-lock expression. On a locked managed profile in Child mode, the child can open the `GeofencePicker`, edit the rule, tap Done (edits into local `@State`), but the Save button is hidden (`editingDisabled`), so the change is silently discarded — an inconsistent, misleading lock state.

**Chosen fix:** Route the geofence selector's `disabled:` through the same `editingDisabled` property Task 5 established. This makes all three selectors consistent.

> **Scope note (from verification):** several `CustomToggle`s and the app/domain selectors (lines 296, 304, 312, 321, 329, 405, 415, 425, 433, 462, 470) are *also* gated only by `isBlocking`. Issue #251 is specifically about the **Location Restrictions** selector matching the trigger selectors — those other toggles are **out of scope** for this bundle. Do not change them here; if the maintainer wants full managed-profile lock consistency, file a follow-up.

**Files:**
- Modify: `Foqos/Views/BlockedProfileView.swift:364`
- Test: **none added.** The gate logic is `ProfileEditGate.editingDisabled`, already fully covered by `ProfileEditGateTests` (Task 5). The #251 defect is the *view wiring* (`disabled: isBlocking` vs `disabled: editingDisabled`), a SwiftUI expression with no unit-testable surface in this codebase.

**Interfaces:**
- Consumes: the View's `editingDisabled` property (from Task 5).

> **No new test (greptile P2).** A test calling `ProfileEditGate.editingDisabled(...)` with geofence-shaped inputs would be a byte-for-byte duplicate of Task 5's assertions — it passes whether or not the geofence row is wired, so it cannot catch a regression where someone re-hardcodes `isBlocking` here. Adding it would be false assurance. The honest coverage story for #251: the shared gate is unit-tested once (Task 5), and the one-line wiring below is verified by **build + code inspection**. If the team later adopts a SwiftUI view-inspection test harness, a real wiring test can be added then.

- [ ] **Step 1: Confirm Task 5's gate tests are green (the shared coverage for this fix)**

Run:
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<SIM_UUID>' \
  -only-testing:FoqosTests/ProfileEditGateTests | xcpretty
```
Expected: PASS. This is the coverage for the gate logic #251 relies on; the step below wires the geofence call site to it.

- [ ] **Step 2: Route the geofence selector through `editingDisabled`**

In `Foqos/Views/BlockedProfileView.swift`, the geofence call site (lines 359-365) currently reads:

```swift
          Section {
            BlockedProfileGeofenceSelector(
              geofenceRule: $geofenceRule,
              savedLocations: savedLocations,
              buttonAction: { showingGeofencePicker = true },
              disabled: isBlocking
            )
```

Change the `disabled:` arg from `isBlocking` to `editingDisabled`:

```swift
              disabled: editingDisabled
```

- [ ] **Step 3: Build and run**

Run:
```bash
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug build 2>&1 | xcpretty
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<SIM_UUID>' \
  -only-testing:FoqosTests/ProfileEditGateTests | xcpretty
```
Expected: BUILD SUCCEEDED; PASS.

- [ ] **Step 4: Commit**

```bash
swift-format --in-place Foqos/Views/BlockedProfileView.swift
git add Foqos/Views/BlockedProfileView.swift FoqosTests/ProfileEditGateTests.swift
git commit -m "fix(#251): geofence selector reuses editingDisabled for lock consistency"
```

---

## Final verification (before requesting review)

- [ ] **Run the full B1 test surface** on the booted simulator:

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<SIM_UUID>' \
  -only-testing:FoqosTests/ChildDashboardCopyTests \
  -only-testing:FoqosTests/AppModePromotionTests \
  -only-testing:FoqosTests/SavedLocationLockGateTests \
  -only-testing:FoqosTests/LockCodeFailClosedTests \
  -only-testing:FoqosTests/ProfileEditGateTests | xcpretty
```
Expected: all five new classes PASS.

- [ ] **Run the entire suite** to confirm no regressions:

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<SIM_UUID>' | xcpretty
```
Expected: full suite green (baseline before this branch was 621+ tests passing).

- [ ] **Lint clean:** `swift-format lint --recursive .` reports no violations.

- [ ] **Grep guard — no forbidden pattern introduced:**

```bash
git diff main --unified=0 | grep -nE '\!= \.parent' && echo "FORBIDDEN PATTERN FOUND — fix before review" || echo "OK: no != .parent"
```
Expected: `OK: no != .parent`.

- [ ] **`#197` decision is SETTLED** (fail-closed-with-cache, maintainer 2026-07-05) — Task 4 implements it as written; no further sign-off needed on the approach.

- [ ] **Request code review** (AGENTS.md requirement). Do not merge without it.

---

## Self-review (author's spec-coverage check)

- **#196** → Task 1 (footer copy + audit already complete; only line 576). ✔
- **#244** → Task 2 (promote Individual→Parent; Option A recommended). ✔
- **#199** → Task 3 (edit gate mirrors delete gate; `== .child`). ✔
- **#197** → Task 4 (fail-closed-with-cache: persist + hydrate last-synced codes; **maintainer decision SETTLED 2026-07-05**). ✔
- **#211** → Task 5 (selectors reuse `editingDisabled`; Parent no longer blocked). ✔
- **#251** → Task 6 (geofence matches trigger selectors). ✔
- **Type consistency:** `ProfileEditGate.editingDisabled(isBlocking:isManaged:isUnlocked:mode:lockActive:)` is defined in Task 5 and reused by Task 6; its `lockActive` argument is fed `LockCodeManager.canVerifyCode` (unchanged API, made offline-correct by Task 4's `resolveLockCodes` cache hydration). `LockCodeManager.resolveLockCodes(fetched:isConnected:persisted:)` is defined and tested in Task 4. `SavedLocation.requiresLockCodeToModify(mode:)` used in both `handleEdit` and `handleDelete`. `AppModeManager.modeAfterSettingLockCode(from:)` defined and consumed in Task 2. ✔
- **Forbidden-pattern check:** no `!= .parent` introduced; all new gates use `== .child`. The legitimate `!= .child` array-selector ternaries in `LockCodeManager` are left untouched. ✔
