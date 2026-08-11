# Issue #193 Safe Preview Context Implementation Plan

> **For implementers:** Follow the repository's TDD, serialized Xcode, versioning, review, and
> verification requirements. Do not merge this PR; hand the green reviewed PR to the planner.

**Goal:** Make the three carousel previews and the child dashboard preview render with valid
SwiftData contexts while preserving production zombie-model protections.

**Architecture:** A debug-only carousel preview fixture owns an in-memory `ModelContainer`, inserts
its directly constructed profiles, and passes both the registered profiles and the same container
to the preview hierarchy. The query-backed child dashboard preview receives an in-memory container
directly. Production views and model-validation logic remain unchanged.

**Tech stack:** SwiftUI previews, SwiftData, XCTest, Xcode project build settings.

---

## Task 1: Add the failing carousel preview registration test

**Files:**

- Modify: `FoqosTests/BlockedProfileCarouselTests.swift`

1. Add a test that iterates every `BlockedProfileCarouselPreview.Scenario` and asserts that the
   fixture supplies three profiles and every profile is `isPersistentModelValid`.
2. Run the focused test through the serialized stream:

   ```bash
   set -o pipefail
   scripts/xcode-stream.sh --agent build1 --session collab -- \
     xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
     -only-testing:FoqosTests/BlockedProfileCarouselTests 2>&1 | bundle exec xcpretty
   ```

3. Confirm RED because `BlockedProfileCarouselPreview` does not exist yet. Do not continue if the
   test unexpectedly passes.
4. Commit the red test as a new commit.

## Task 2: Implement the in-memory preview contexts

**Files:**

- Modify: `Foqos/Components/BlockedProfileCards/BlockedProfileCarousel.swift`
- Modify: `Foqos/Views/Child/ChildDashboardView.swift`

1. Import SwiftData in `BlockedProfileCarousel.swift`.
2. Add a debug-only, main-actor `BlockedProfileCarouselPreview` fixture with `CaseIterable`
   scenarios for active, inactive, and starting-profile previews.
3. In the fixture initializer, create an in-memory `ModelContainer` for `BlockedProfiles`, build
   the scenario's three profiles, insert them all into `container.mainContext`, and retain the
   matching active/starting IDs.
4. Render the existing carousel configuration from the fixture and attach `.modelContainer` using
   that exact container.
5. Replace the three duplicated preview bodies with the corresponding fixture scenarios.
6. Attach `.modelContainer(for: BlockedProfiles.self, inMemory: true)` to the child dashboard
   preview.
7. Re-run the focused command from Task 1 and confirm GREEN.
8. Commit the implementation as a new commit.

## Task 3: Apply the strict version bump

**Files:**

- Modify: `FamilyFoqos.xcodeproj/project.pbxproj`

1. Update every target configuration from marketing version `2.0.8` to `2.0.9` and build version
   `27` to `28`.
2. Run the repository version-increment check against `main` and confirm it passes.
3. Commit the version bump as a new commit.

## Task 4: Verify the complete #193 change

**Files:** none

1. Run `swift-format lint --recursive .` and `git diff --check`.
2. Run repository guard scripts relevant to all commits, including log privacy; no log-site floor
   change is expected because #193 removes no log calls.
3. Run the full unit test suite through `scripts/xcode-stream.sh` with caller `pipefail` and
   `bundle exec xcpretty`.
4. Run a Debug build through the same serialized stream to compile both preview declarations.
5. Inspect the complete diff against `main` and confirm only the approved #193 design, test,
   preview changes, and version bump are present.

## Task 5: Review and publish

1. Request independent code review before publication and address only verified findings in new
   commits.
2. Re-run affected verification after any review changes.
3. Push `fix/193-safe-preview-context` and open an undrafted PR that closes #193.
4. Wait for green CI, then report the PR and evidence to the planner for merge. Do not begin #248
   until the planner confirms #193 is merged and `main` is updated.
