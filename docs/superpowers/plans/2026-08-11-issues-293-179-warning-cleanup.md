# Issues #293 and #179 Implementation Plan

**Goal:** Eliminate the settled tree's known warning noise with behavior-neutral code and test changes.

**Architecture:** Correct actor isolation at test boundaries, express tombstone assertions as key-membership checks, adopt the supported StoreKit API, and explicitly classify the two irreducible Xcode metadata notices.

**Tech stack:** Swift 6, XCTest, StoreKit, Xcode.

## Task 1: Correct XCTest actor isolation

**Files:**

- `FoqosTests/EstablishmentGenerationGateTests.swift`
- `FoqosTests/MutationFunnelTests.swift`
- `FoqosTests/ResetSeederTests.swift`
- `FoqosTests/SessionStopOutboxTests.swift`
- `FoqosTests/SyncEngineResetTests.swift`
- `FoqosTests/TimerDurationSnapTests.swift`

1. Convert synchronous lifecycle overrides in the five `@MainActor` classes to async throwing overrides.
2. Preserve setup/teardown statement order.
3. Mark `TimerDurationSnapTests` as `@MainActor`.
4. Run the six focused test classes and inspect the raw warning stream.

## Task 2: Correct tombstone assertions

**File:** `FoqosTests/SyncEngineControllerTests.swift`

1. Replace all 13 warned nested-optional assertions with explicit key membership assertions.
2. Preserve each assertion message and presence/absence expectation.
3. Run `SyncEngineControllerTests` and inspect the raw warning stream.

## Task 3: Adopt supported StoreKit API and classify metadata notices

**Files:**

- `Foqos/Utils/RatingManager.swift`

1. Replace the deprecated review request call with `AppStore.requestReview(in:)`.
2. Retain no ineffective metadata filter or extraction-disabling project setting.
3. Run a clean Debug build and require zero project-source warnings plus exactly the allowlisted ShieldConfig metadata notice.

## Task 4: Advance the strict release version

**File:** `FamilyFoqos.xcodeproj/project.pbxproj`

1. Change all 12 `MARKETING_VERSION` values from 2.0.15 to 2.0.16.
2. Change all 12 `CURRENT_PROJECT_VERSION` values from 34 to 35.
3. Run the strict version gate against `origin/main`.

## Task 5: Full verification and review

1. Run swift-format lint and repository policy gates.
2. Run a clean serialized full test while capturing raw output.
3. Require 1,223 passing tests, zero project-source warnings, and exactly the two allowlisted Xcode metadata notices.
4. Run a clean serialized Debug build and require zero project-source warnings plus exactly the one allowlisted ShieldConfig notice.
5. Request independent read-only review of the exact head.

## Task 6: Publish

1. Refresh live `origin/main` and confirm ancestry.
2. Push the exact reviewed head and open one non-draft PR closing #293 and #179.
3. Wait for all GitHub checks.
4. Hand the green PR to the planner for merge; do not merge it directly.
