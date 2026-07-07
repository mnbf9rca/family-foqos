# Plan for #285 — SafeModelView/`.valid` Fail Open After `context.save()` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Strengthen the SwiftData zombie-model validity check in one central place so every `.valid` / `SafeModelView` call site rejects a model that has been deleted **and saved** (the post-save window where `isDeleted` flips back to `false`), eliminating the 100%-reproducible crash when a profile is deleted while the home carousel is visible.

**Architecture:** Introduce a single `isPersistentModelValid` computed property on `PersistentModel` (in `Extensions.swift`). It gates on `modelContext != nil && !isDeleted` (pre-save window, unchanged) **and additionally** `modelContext.registeredModel(for: persistentModelID) != nil` (post-save window, new). Route both existing call sites — the `.valid` array extension and `SafeModelView.body` — through this one property. No per-view patching; every call site heals at once.

**Tech Stack:** Swift 6, SwiftData, SwiftUI, XCTest. iOS app (`FamilyFoqos.xcodeproj`, scheme `FamilyFoqos`, test target `FoqosTests`).

## Global Constraints

- **Central fix only.** Do NOT patch individual views (`BlockedProfileCarousel`, `BlockedProfileCard`, etc.). All healing happens in `Extensions.swift` + `SafeModelView.swift` via the shared property. Copy verbatim from the issue: _"Strengthen the validity predicate centrally … so every call site heals at once."_
- **No fetch-per-row.** The check runs per-element inside `ForEach` on every render. It MUST NOT issue a SwiftData fetch (`context.fetch`) per element. `registeredModel(for:)` is an in-memory registration-table lookup (no SQL, no fault, no I/O) — this constraint is satisfied by design; do not replace it with a fetch.
- **Both windows must be tested.** Every predicate/`.valid`/`SafeModelView` regression test must cover BOTH the pre-save window (`delete` without `save`) AND the post-save window (`delete` then `save`). The post-save window is the one the existing suite missed.
- **No new files.** Reuse `Foqos/Utils/Extensions.swift`, `Foqos/Utils/SafeModelView.swift`, and `FoqosTests/SafeModelViewTests.swift`.
- **Test naming:** `testGivenX_WhenY_ThenZ`. No `Date()` is involved anywhere in this fix — there are no dates to pin and no `now:` parameter to inject; do not add one.
- **Formatting:** 2-space indent, run `swift-format lint --recursive .` clean before commit. A pre-commit hook auto-formats staged Swift files.
- **Never** force-commit or amend. New commits only.
- **This PR plans the fix for #285 — it does not close it.** GitHub auto-closes an issue when a commit message or the PR body contains a closing keyword (`fix`/`fixes`/`fixed`/`close`/`closes`/`resolve`/`resolves`) adjacent to `#285`; trailing words do NOT suppress it — `fix #285 mechanism` still closes it. Reference the issue ONLY with a non-closing form: `plans the fix for #285`, `refs #285`, or `part of #285`. Never place any closing keyword next to `#285` in a commit message or the PR body.

---

## Background: the exact mechanism (re-verified against current code, 2026-07-07)

Current shared predicate (duplicated in two places):

- `Foqos/Utils/Extensions.swift:18-20`
  ```swift
  var valid: [Element] {
    filter { $0.modelContext != nil && !$0.isDeleted }
  }
  ```
- `Foqos/Utils/SafeModelView.swift:28-32`
  ```swift
  var body: some View {
    if model.modelContext != nil && !model.isDeleted {
      content(model)
    }
  }
  ```

SwiftData deletion has two windows:

| Window | Trigger | `isDeleted` | `modelContext` | Reading a stored attr (e.g. `selectedActivity`) | Current guard result |
|---|---|---|---|---|---|
| Pre-save | `context.delete(model)` | `true` | non-nil | traps | **rejected** (via `!isDeleted`) ✅ |
| Post-save | `context.delete(model)` then `context.save()` | **`false`** (SwiftData resets it) | **non-nil** | **traps `EXC_BREAKPOINT`** | **accepted → CRASH** ❌ |

Device evidence in #285 (4/4 identical crash reports, iOS 27.0): the crash is `BlockedProfiles.selectedActivity.getter` inside `BlockedProfileCard.body`, reached because the delete handler saves synchronously and the carousel card re-renders on the same runloop with the saved-deleted model **before** `@SafeQuery` publishes the filtered array. The current guard passes it through because in the post-save window `modelContext` is still non-nil and `isDeleted` has flipped back to `false`.

Why the bug shipped: `FoqosTests/SafeModelViewTests.swift` only ever calls `context.delete(...)` **without** a following `context.save()`, so every existing test exercises only the (already-working) pre-save window. No test covered the post-save window.

### The chosen detection API: `ModelContext.registeredModel(for:)`

```swift
let registered: Self? = context.registeredModel(for: persistentModelID)
```

`registeredModel(for:)` returns the model instance the context currently tracks for a `PersistentIdentifier`, or `nil` if the context is no longer tracking that id. It reads the context's in-memory registration table only — **no fetch, no fault, no SQL**.

**Why it detects the post-save window:** once a delete is committed with `context.save()`, the context de-registers the object (the store row is gone). `registeredModel(for: persistentModelID)` then returns `nil`, even though `isDeleted` has been reset to `false`. That nil is the signal the old guard lacked.

**Why it cannot false-negative a live model** (reject something that is actually alive):
- Any model handed to `.valid` / `SafeModelView` is a concrete `Model` reference the view holds — it came from `@SafeQuery`/`@Query`, a relationship traversal, or `context.insert(...)`. A model your code holds a live reference to and whose `modelContext` is non-nil is, by definition, registered in that context — that is what "managed by a context" means. `registeredModel(for:)` on that same context therefore returns the instance (non-nil). SwiftData does not silently de-register a model you still hold a strong reference to.
- Newly `insert`ed, not-yet-saved models are registered at insert time (under a temporary identifier); `registeredModel(for: persistentModelID)` finds them. (Covered by a dedicated false-negative-guard test in Task 1.)
- The only state that yields `nil` is "the context is not tracking this id" — i.e. a deleted model (pre-save it is already rejected earlier by `!isDeleted`; post-save it is rejected here). That is exactly the set we want to reject.

**Reading the inputs is crash-safe.** `modelContext`, `isDeleted`, and `persistentModelID` are model metadata, not stored attributes — reading them does not fault the vacated backing row (the crash is specifically on stored-attribute getters like `selectedActivity`). So evaluating the guard on a saved-deleted model is safe; only the content closure (which reads real attributes) must be prevented from running, which the guard does.

**Cost:** per element, one `PersistentIdentifier` read (cached metadata) + one hash lookup in the context's registration table. O(1), no I/O — the same order of magnitude as the existing `modelContext`/`isDeleted` reads it sits beside. For a carousel of N cards re-rendered per frame this is N cheap lookups; negligible.

**Empirical gate (honesty note for the implementer):** this plan was authored without a build/simulator run. The claim "`registeredModel(for:)` returns `nil` in the post-save window" is asserted from SwiftData's documented registration semantics and the device crash signature. The Task 1 post-save test *exercises* that clause — but only when its pre-asserts (`modelContext != nil`, `isDeleted == false`) hold, confirming the in-memory `TestModelContainer` actually reproduces the post-save window; otherwise the test could go green via the older `modelContext`/`isDeleted` clauses without touching `registeredModel` at all (see Contingency Mode C). The **authoritative** proof that #285 is fixed is the on-device repro in Task 4 Step 3 — the crash only manifests against the real on-disk/CloudKit-backed store. If any Task 1 step fails, apply the matching Contingency mode below rather than improvising.

---

## File Structure

- **Modify** `Foqos/Utils/Extensions.swift`
  - Add a `PersistentModel` protocol extension with `var isPersistentModelValid: Bool` — the single source of truth.
  - Rewrite the existing `.valid` array extension to delegate to it.
- **Modify** `Foqos/Utils/SafeModelView.swift`
  - Rewrite `body` to gate on `model.isPersistentModelValid`.
- **Modify (tests)** `FoqosTests/SafeModelViewTests.swift`
  - Add post-save-window regression tests + predicate tests + false-negative-guard test. Keep the existing pre-save tests (they still document that window).

No other files change. The two production call sites are the only consumers (`Extensions.swift:19` internal to `.valid`; `SafeModelView.swift:29`); `@SafeQuery` uses `.valid` internally so it heals transitively.

---

## Task 1: Central `isPersistentModelValid` predicate (both windows)

**Files:**
- Modify: `Foqos/Utils/Extensions.swift` (add protocol extension after the existing `Array where Element: PersistentModel` block, ~line 21)
- Test: `FoqosTests/SafeModelViewTests.swift` (add a new `MARK` section for predicate tests)

**Interfaces:**
- Produces: `extension PersistentModel { var isPersistentModelValid: Bool { get } }` — `true` iff the model is safe to read stored attributes from (live in its context, not deleted in either window). Consumed by Task 2 (`.valid`) and Task 3 (`SafeModelView`).

- [ ] **Step 1: Write the failing predicate tests**

Add to `FoqosTests/SafeModelViewTests.swift`, after the existing tests (before the closing brace):

```swift
  // MARK: - isPersistentModelValid predicate (both deletion windows)

  func testGivenLiveSavedModel_WhenCheckingValidity_ThenValid() throws {
    let profile = BlockedProfiles(
      id: UUID(), name: "Live", selectedActivity: .init(),
      blockingStrategyId: "manual")
    context.insert(profile)
    try context.save()

    XCTAssertTrue(profile.isPersistentModelValid)
  }

  func testGivenInsertedUnsavedModel_WhenCheckingValidity_ThenValid() throws {
    // False-negative guard: a freshly inserted, not-yet-saved model is alive.
    let profile = BlockedProfiles(
      id: UUID(), name: "Fresh", selectedActivity: .init(),
      blockingStrategyId: "manual")
    context.insert(profile)

    XCTAssertTrue(profile.isPersistentModelValid)
  }

  func testGivenModelDeletedWithoutSave_WhenCheckingValidity_ThenInvalid() throws {
    // Pre-save window: isDeleted == true.
    let profile = BlockedProfiles(
      id: UUID(), name: "PreSaveGone", selectedActivity: .init(),
      blockingStrategyId: "manual")
    context.insert(profile)
    try context.save()

    context.delete(profile)

    XCTAssertFalse(profile.isPersistentModelValid)
  }

  func testGivenModelDeletedThenSaved_WhenCheckingValidity_ThenInvalid() throws {
    // Post-save window: isDeleted flips back to false — the gap #285 shipped through.
    let profile = BlockedProfiles(
      id: UUID(), name: "PostSaveGone", selectedActivity: .init(),
      blockingStrategyId: "manual")
    context.insert(profile)
    try context.save()

    context.delete(profile)
    try context.save()

    // Pre-asserts: prove the unit environment actually reproduces the post-save window, so
    // the assertion below exercises the NEW registeredModel clause rather than passing via
    // the old modelContext/isDeleted clauses. If either fails, the in-memory store does not
    // reproduce #285 here — see Contingency Mode C; rely on Task 4 Step 3 device verification.
    XCTAssertNotNil(profile.modelContext, "post-save window requires a non-nil modelContext")
    XCTAssertFalse(profile.isDeleted, "post-save window requires isDeleted == false")

    XCTAssertFalse(
      profile.isPersistentModelValid,
      "A deleted-and-saved model must be rejected even though isDeleted == false")
  }
```

- [ ] **Step 2: Run the tests to verify they fail (and prove the mechanism)**

Boot the simulator once (see AGENTS.md), then run only the new predicate tests:

```bash
xcrun simctl list devices available | grep "iPhone 17"   # pick UUID once
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' \
  -only-testing:FoqosTests/SafeModelViewTests | xcpretty
```

Expected: **compile failure** — `isPersistentModelValid` is not defined yet (`value of type 'BlockedProfiles' has no member 'isPersistentModelValid'`). This confirms the tests exercise the not-yet-built API.

- [ ] **Step 3: Implement the central predicate**

In `Foqos/Utils/Extensions.swift`, add below the existing `Array where Element: PersistentModel` extension:

```swift
extension PersistentModel {
  /// Single source of truth for "is this SwiftData model safe to read stored attributes from?"
  ///
  /// Rejects zombie models across BOTH deletion windows:
  ///  - Pre-save (`context.delete` without save): `isDeleted == true`.
  ///  - Post-save (`context.delete` + `context.save`): SwiftData resets `isDeleted` to `false`
  ///    and leaves `modelContext` non-nil, but the store row is gone — reading any stored
  ///    attribute traps with `EXC_BREAKPOINT`. The context de-registers the id on save, so
  ///    `registeredModel(for:)` returns nil. Reading `modelContext`, `isDeleted`, and
  ///    `persistentModelID` is metadata-only and does not fault the vacated row.
  var isPersistentModelValid: Bool {
    guard let context = modelContext, !isDeleted else { return false }
    let registered: Self? = context.registeredModel(for: persistentModelID)
    return registered != nil
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' \
  -only-testing:FoqosTests/SafeModelViewTests | xcpretty
```

Expected: PASS — all four new predicate tests green. `testGivenModelDeletedThenSaved_WhenCheckingValidity_ThenInvalid` now exercises the `registeredModel(for:)` clause (its pre-asserts confirm the post-save window is genuine). Device verification (Task 4 Step 3) remains the authoritative proof. If any of these steps fails, STOP and apply the matching Contingency mode — do not improvise.

- [ ] **Step 5: Commit**

```bash
git add Foqos/Utils/Extensions.swift FoqosTests/SafeModelViewTests.swift
git commit -m "refs #285: add isPersistentModelValid guarding the post-save delete window"
```

---

## Task 2: Route `.valid` through the central predicate + post-save regression test

**Files:**
- Modify: `Foqos/Utils/Extensions.swift:18-20` (`.valid` body)
- Test: `FoqosTests/SafeModelViewTests.swift` (add to the existing `.valid` MARK section)

**Interfaces:**
- Consumes: `PersistentModel.isPersistentModelValid` (Task 1).
- Produces: `.valid` on `Array where Element: PersistentModel` now rejects post-save-deleted models. `@SafeQuery` (which calls `.valid` internally, `SafeQuery.swift:16`) heals transitively — no change needed there.

- [ ] **Step 1: Write the failing regression test**

Add to `FoqosTests/SafeModelViewTests.swift` in the `.valid extension tests` MARK section:

```swift
  func testGivenDeletedThenSavedModel_WhenFilteringValid_ThenExcluded() throws {
    // Post-save window regression for #285 — the existing .valid tests only delete
    // without saving, so they never exercised this window.
    let keep = BlockedProfiles(
      id: UUID(), name: "Keep", selectedActivity: .init(),
      blockingStrategyId: "manual")
    let gone = BlockedProfiles(
      id: UUID(), name: "Gone", selectedActivity: .init(),
      blockingStrategyId: "manual")
    context.insert(keep)
    context.insert(gone)
    try context.save()

    context.delete(gone)
    try context.save()

    // Pre-asserts: confirm the post-save window is genuine (see Contingency Mode C).
    XCTAssertNotNil(gone.modelContext, "post-save window requires a non-nil modelContext")
    XCTAssertFalse(gone.isDeleted, "post-save window requires isDeleted == false")

    let result = [keep, gone].valid
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result.first?.name, "Keep")
  }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' \
  -only-testing:FoqosTests/SafeModelViewTests/testGivenDeletedThenSavedModel_WhenFilteringValid_ThenExcluded | xcpretty
```

Expected: FAIL — `.valid` still uses the old inline predicate (`XCTAssertEqual(result.count, 1)` fails because `gone` is not filtered; `result.count == 2`).

- [ ] **Step 3: Route `.valid` through the central predicate**

In `Foqos/Utils/Extensions.swift`, replace the `.valid` body:

```swift
extension Array where Element: PersistentModel {
  /// Filters out zombie SwiftData models across both deletion windows (see
  /// `PersistentModel.isPersistentModelValid`). Used by `@SafeQuery` internally and by
  /// views receiving plain arrays.
  var valid: [Element] {
    filter { $0.isPersistentModelValid }
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' \
  -only-testing:FoqosTests/SafeModelViewTests | xcpretty
```

Expected: PASS — new post-save test green; the pre-existing `.valid` pre-save tests (`testValidFiltersDeletedModels`, `testValidReturnsAllWhenNoneDeleted`, `testValidReturnsEmptyForAllDeleted`) still green.

- [ ] **Step 5: Commit**

```bash
git add Foqos/Utils/Extensions.swift FoqosTests/SafeModelViewTests.swift
git commit -m "refs #285: route .valid through isPersistentModelValid"
```

---

## Task 3: Route `SafeModelView` through the central predicate + post-save regression test

**Files:**
- Modify: `Foqos/Utils/SafeModelView.swift:28-32` (`body`)
- Test: `FoqosTests/SafeModelViewTests.swift` (add to the `SafeModelView unit tests` MARK section)

**Interfaces:**
- Consumes: `PersistentModel.isPersistentModelValid` (Task 1).
- Produces: `SafeModelView.body` no longer renders content for post-save-deleted models — the last-layer render-time guard the carousel relies on.

- [ ] **Step 1: Write the failing regression test**

Add to `FoqosTests/SafeModelViewTests.swift` in the `SafeModelView unit tests` MARK section:

```swift
  func testGivenModelDeletedThenSaved_WhenRenderingSafeModelView_ThenContentNotCalled() throws {
    // Post-save window regression for #285: the render-time guard must reject the
    // saved-deleted model so BlockedProfileCard never reads its stored attributes.
    let profile = BlockedProfiles(
      id: UUID(), name: "PostSaveGone", selectedActivity: .init(),
      blockingStrategyId: "manual")
    context.insert(profile)
    try context.save()

    context.delete(profile)
    try context.save()

    // Pre-asserts: confirm the post-save window is genuine (see Contingency Mode C).
    XCTAssertNotNil(profile.modelContext, "post-save window requires a non-nil modelContext")
    XCTAssertFalse(profile.isDeleted, "post-save window requires isDeleted == false")

    var contentCalled = false
    let view = SafeModelView(profile) { _ in
      contentCalled = true
      return Text("Should not render")
    }

    // Evaluating body reads only model metadata (safe); the content closure — which would
    // read stored attributes and trap — must not run.
    let _ = view.body

    XCTAssertFalse(
      contentCalled,
      "Content closure must not run for a deleted-and-saved model (isDeleted == false)")
  }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' \
  -only-testing:FoqosTests/SafeModelViewTests/testGivenModelDeletedThenSaved_WhenRenderingSafeModelView_ThenContentNotCalled | xcpretty
```

Expected: FAIL — `body` still uses the old inline predicate, so `contentCalled` becomes `true` (`XCTAssertFalse` fails).

- [ ] **Step 3: Route `SafeModelView.body` through the central predicate**

In `Foqos/Utils/SafeModelView.swift`, replace `body`:

```swift
  var body: some View {
    if model.isPersistentModelValid {
      content(model)
    }
  }
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' \
  -only-testing:FoqosTests/SafeModelViewTests | xcpretty
```

Expected: PASS — new post-save test green; the pre-existing `SafeModelView` tests (`testSafeModelViewWithDeletedModel` pre-save, `testSafeModelViewWithValidModel`, `testSafeModelViewTypeExists`) still green.

- [ ] **Step 5: Commit**

```bash
git add Foqos/Utils/SafeModelView.swift FoqosTests/SafeModelViewTests.swift
git commit -m "refs #285: route SafeModelView render guard through isPersistentModelValid"
```

---

## Task 4: Full verification (suite, format, device)

**Files:** none (verification only).

- [ ] **Step 1: Run the whole test target**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty
```

Expected: entire `FoqosTests` suite passes (0 failures). Confirms no `.valid`/`@SafeQuery`/`SafeModelView` consumer regressed.

- [ ] **Step 2: Formatting check**

```bash
swift-format lint --recursive .
```

Expected: no violations for `Extensions.swift`, `SafeModelView.swift`, `SafeModelViewTests.swift`. (The pre-commit hook also auto-formats staged Swift files.)

- [ ] **Step 3: Device verification (the #285 repro)**

On a physical device or simulator running the app:

1. Ensure ≥1 profile is visible in the home carousel.
2. Delete that profile via a path that keeps the carousel in the hierarchy and saves synchronously (list swipe-delete, or the profile editor's delete button).
3. Observe: **the app does not crash** on the re-render. Before this fix it crashed 100% of the time at `BlockedProfiles.selectedActivity.getter`.
4. Repeat with the app foregrounded and the deleted card currently centered/scrolled-to, to exercise the same-runloop re-render.

Expected: no `EXC_BREAKPOINT`; the deleted card disappears cleanly when `@SafeQuery` republishes.

- [ ] **Step 4: Confirm scope — no per-view patches leaked in**

```bash
git diff --stat main...HEAD
```

Expected: only `Foqos/Utils/Extensions.swift`, `Foqos/Utils/SafeModelView.swift`, `FoqosTests/SafeModelViewTests.swift` (plus this plan doc). No changes to `BlockedProfileCarousel.swift`, `BlockedProfileCard.swift`, or any other view — the fix is central.

---

## Contingency (only if a Task 1 step fails)

Task 1's tests can fail in three distinct ways. Do NOT improvise past any of them.

**Mode A — `testGivenModelDeletedThenSaved_...` still fails after Step 3** (i.e. `registeredModel(for:)` returns a non-nil tombstone after `save()`, so a saved-deleted model is wrongly accepted). There is **no fault-free _generic_ store-membership API**: you cannot filter a `#Predicate`/`FetchDescriptor` by `persistentModelID` — it is a non-persisted computed property, not an `@Attribute` column, and SwiftData traps with an unsupported-keypath error rather than counting rows. A working membership check would have to be a **concrete, per-model** overload filtering on that model's real `@Attribute(.unique) id` column, e.g.:

```swift
// Concrete — NOT generic over PersistentModel. Only if Mode A forces it.
var descriptor = FetchDescriptor<BlockedProfiles>(predicate: #Predicate { $0.id == targetId })
descriptor.fetchLimit = 1
let stillExists = ((try? context.fetchCount(descriptor)) ?? 0) > 0
```

That abandons the single-central-predicate design and reintroduces a per-render store query — deliberately relaxing the "No fetch-per-row" constraint. Do NOT ship it silently: **STOP, report to the maintainer** that `registeredModel(for:)` is insufficient on this SwiftData version, and get a decision (accept the per-render `fetchCount` cost, or find another signal) before adding any fetch.

**Mode B — `testGivenInsertedUnsavedModel_...` fails** (i.e. `registeredModel(for:)` returns `nil` for a freshly inserted, not-yet-saved model — a false-negative from SwiftData's temporary-vs-permanent identifier semantics). This path does **not occur in production**: `.valid`/`SafeModelView` only ever receive already-persisted models from `@SafeQuery`/relationships in this app. If the guard proves flaky, the pragmatic remedy is to change that one test to `insert` **+ `save`** before asserting validity (documenting that unsaved rendering is not a real path) — NOT to complicate the production predicate. Report the observation either way.

**Mode C — a post-save pre-assert (`XCTAssertNotNil(modelContext)` / `XCTAssertFalse(isDeleted)`) fails.** The in-memory `TestModelContainer` does not reproduce the on-device post-save window (it nils `modelContext` or leaves `isDeleted == true`). This is **information, not a defect in the fix**: the unit tests cannot reproduce #285 in this environment, so Task 4 Step 3 device verification becomes the sole authoritative proof. Note it in the PR description and keep the primary `registeredModel(for:)` implementation.

---

## Self-Review

- **Spec coverage:**
  - Central single-place fix → Task 1 predicate + Tasks 2/3 routing both call sites; Global Constraints forbid per-view patches; Task 4 Step 4 verifies scope. ✅
  - Correct SwiftData API + no-false-negative justification → Background section ("chosen detection API" + "why it cannot false-negative") + false-negative-guard tests (live-saved, inserted-unsaved). ✅
  - Performance (no fetch-per-row, stated cost) → Global Constraints + Background "Cost" paragraph. ✅
  - Both windows tested for predicate, `.valid`, and `SafeModelView` → Task 1 (predicate: pre-save + post-save), Task 2 (`.valid` post-save; pre-save retained), Task 3 (`SafeModelView` post-save; pre-save retained). ✅
  - Missing test that let it ship (delete-then-save) → explicitly added in all three surfaces. ✅
  - Device-verification step → Task 4 Step 3. ✅
  - TDD, complete code, `testGivenX_WhenY_ThenZ`, no `now:` (no dates) → all tasks. ✅
  - Plan-only, non-closing wording → Global Constraints forbid any closing-keyword adjacency to `#285`; commits use `refs #285:`; handoff says "plans the fix for #285". ✅
- **Skeptic pass (2026-07-07, applied):** post-save tests now pre-assert the window is genuine so a green truly exercises the `registeredModel` clause (else Mode C); the broken `#Predicate { $0.persistentModelID == ... }` contingency was removed and replaced with concrete/escalation guidance; the false-negative-guard failure mode (inserted-unsaved) is now covered by Contingency Mode B; commit/PR wording hardened against GitHub auto-close. ✅
- **Placeholder scan:** no TBD/TODO/"handle edge cases"/"similar to Task N"; every code step shows full code. ✅
- **Type consistency:** `isPersistentModelValid` (property, no args) used identically in Task 1 (def), Task 2 (`.valid` filter), Task 3 (`SafeModelView.body`). `registeredModel(for:)` bound to `Self?`. `persistentModelID` used consistently. Contingency Mode A example is explicitly concrete (`FetchDescriptor<BlockedProfiles>`), not generic. ✅
