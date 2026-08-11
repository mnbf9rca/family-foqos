# Issue #319 Implementation Plan

**Goal:** Remove the Buy NFC Tags affiliate link from Settings and remove its unused constant.

**Architecture:** This is a local SwiftUI deletion in `SettingsView`. NFC strategy, scanner, writer, onboarding, and generic feature copy remain untouched.

**Tech stack:** SwiftUI, Xcode project build settings, repository verification scripts.

## Task 1: Remove the Settings purchase link

**File:** `Foqos/Views/SettingsView.swift`

1. Delete the file-level `amznStoreLink` constant.
2. Delete the complete `Section("Buy NFC Tags")` block.
3. Confirm the About section now flows directly to Help from the original author.
4. Sweep for `amznStoreLink`, `Buy NFC Tags`, the affiliate label, and the exact URL; expect no matches.

## Task 2: Advance the strict release version

**File:** `FamilyFoqos.xcodeproj/project.pbxproj`

1. Change every `MARKETING_VERSION` from 2.0.14 to 2.0.15.
2. Change every `CURRENT_PROJECT_VERSION` from 33 to 34.
3. Run the strict version gate against `origin/main`.

## Task 3: Verify and review

1. Run swift-format lint and `git diff --check`.
2. Run C2, sync, version, and privacy gates.
3. Run the existing test suite through the serialized Xcode wrapper.
4. Run a serialized Debug build.
5. Request independent read-only review of the exact head.

## Task 4: Publish

1. Refresh `origin/main` and verify it is still the branch base.
2. Push the reviewed branch and open a non-draft PR closing only #319.
3. Wait for all GitHub checks.
4. Hand the green PR to the planner for merge; do not merge it directly.
