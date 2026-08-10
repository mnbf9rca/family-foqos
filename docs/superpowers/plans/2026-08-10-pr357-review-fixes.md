# PR #357 Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the establishment-generation wipe races and compatibility gaps found in the PR #357 adversarial review while making wipe adoption visible, child-safe, and enforcement-ending.

**Architecture:** Keep `ResetController` responsible for reset-intent and outbox coordination, and keep `ProfileSyncManager` responsible for local discard/adoption and reattachment. Route adoption-first cancellation through the existing engine facade into `ResetController`, stop all enforcement before deleting SwiftData models, and preserve the existing tokenless-refetch adoption contract. Reuse HomeView’s alert surface for the one-time adoption notice and static SettingsView policy helpers for child-mode gating.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, CloudKit/CKSyncEngine, XCTest, swift-format.

## Global Constraints

- Only Child mode is lock-restricted; every lock gate must use `mode == .child`, never `mode != .parent`.
- Profile deletion must use `BlockedProfiles.deleteProfile`; never delete a `@Model` profile directly.
- Generation adoption must delete entities before bumping the generation and must force a tokenless refetch with `engineState = nil`.
- Origin wipe deletion is local-only and must not enqueue per-record deletes.
- Use the existing iPhone 17 simulator UUID `966A5E52-D795-4AB5-86A5-67D17B2D6413`; never use a device name destination.
- Run the complete test suite once, after all targeted tests and static checks pass.
- Never amend or force-push; publish fixes through GitHub’s signed `createCommitOnBranch` mutation.

---

### Task 1: Reset/adoption race safety

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/ResetController.swift`
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineControlling.swift`
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineController+Cutover.swift`
- Modify: `Foqos/CloudKit/ProfileSyncManager.swift`
- Modify: `FoqosTests/SyncEngineResetTests.swift`
- Modify: `FoqosTests/ProfileSyncAccountResolverTests.swift`
- Modify: `FoqosTests/Mocks/MockSyncEngineControlling.swift`
- Modify: `FoqosTests/Mocks/ResetSeamMocks.swift`

**Interfaces:**
- Produces: `SyncEngineControlling.cancelDeletingWipeForEstablishmentAdoption()`.
- Produces: `ResetController.cancelDeletingWipeForEstablishmentAdoption()` which removes pending reset-zone changes and clears only a live wipe intent at `.deleting`.
- Preserves: `ProfileSyncManager.adoptEstablishmentGeneration(_:) async` as the serialized public adoption entry point.

- [ ] Add a deleting-gate regression proving a higher server generation clears the wipe intent without changing the local generation or re-enqueuing a zone delete.
- [ ] Run the new `SyncEngineResetTests` case and verify it fails because the generation advances.
- [ ] Change `runWipeDeletingGate` to clear only `resetIntent` on a higher generation.
- [ ] Re-run the focused test and verify it passes.
- [ ] Add an adoption-first regression proving a live deleting wipe is cancelled and its zone changes are dequeued before local adoption.
- [ ] Run the new `ProfileSyncAccountResolverTests` case and verify it fails because cancellation is not forwarded.
- [ ] Add the facade/reset cancellation seam and call it at the start of a higher-generation adoption.
- [ ] Re-run both ordering tests and verify they pass.
- [ ] Add a server-record-changed regression proving a higher winning generation clears `engineState`.
- [ ] Run it red, set `engineState = nil` in the server-conflict arm, then run it green.

### Task 2: Persisted-ledger compatibility and production schema

**Files:**
- Modify: `Foqos/CloudKit/SyncModels.swift`
- Modify: `FoqosTests/EmergencyUnblockEventLedgerTests.swift`
- Modify: `fastlane/required-prod-schema.txt`

**Interfaces:**
- Preserves: `SyncedEmergencyUnblockEvent: Codable`.
- Adds: a decoder default of generation `0` when persisted JSON has no `generation` key.

- [ ] Add a pre-upgrade JSON regression that decodes an event without `generation` and asserts the event survives with generation `0`.
- [ ] Run the focused ledger test and verify `keyNotFound` causes failure.
- [ ] Add explicit `CodingKeys` and `init(from:)`, using `decodeIfPresent(Int.self, forKey: .generation) ?? 0`.
- [ ] Re-run the focused ledger test and verify it passes.
- [ ] Insert `RECORD TYPE SyncEstablishment` immediately before `RECORD TYPE SyncResetRequest`.

### Task 3: One-time notice and child fail-closed policy

**Files:**
- Modify: `Foqos/CloudKit/ProfileSyncManager.swift`
- Modify: `Foqos/Views/HomeView.swift`
- Modify: `Foqos/Views/SettingsView.swift`
- Modify: `FoqosTests/ProfileSyncAccountResolverTests.swift`
- Modify: `FoqosTests/SettingsWipeConfirmationTests.swift`

**Interfaces:**
- Produces: `HomeView.syncedDataResetNoticeMessage` with exact copy `Synced data was reset from another device.`.
- Produces: `SettingsView.wipeIsAllowed(mode:canVerifyCode:) -> Bool`.

- [ ] Add an adoption regression that observes `.syncEnginePurged` and asserts one notification for a coalesced adoption.
- [ ] Run it red against the current per-loop posting behavior.
- [ ] Guard adoption with `defer`, track whether any generation was adopted, and post once after the coalescing loop.
- [ ] Wire HomeView’s notification subscriber to its existing alert surface with a `Sync Reset` title and the required copy.
- [ ] Add Settings policy assertions for child-with-code, child-without-code, Parent, and Individual.
- [ ] Run the Settings test red because child-without-code is currently permitted.
- [ ] Disable the wipe row only for Child mode without a verifiable code and show `Ask a parent - lock code not available.` below it.
- [ ] Re-run the focused Settings test green.

### Task 4: End enforcement before deletion

**Files:**
- Modify: `Foqos/CloudKit/ProfileSyncManager.swift`
- Modify: `FoqosTests/ProfileSyncAccountResolverTests.swift`

**Interfaces:**
- Extends: `wipeLocalSyncedEntitiesForGeneration(cleanup:stopRemoteSession:clearResidualEnforcement:endLiveActivity:)` with production defaults backed by `StrategyManager.stopRemoteSession`, `StrategyManager.resetBlockingState`, and `LiveActivityManager.endSessionActivity`.

- [ ] Add an active-session ordering regression whose injected stop seam observes the profile before deletion and whose residual/live-activity seams are called once.
- [ ] Run it red because generation wipe does not invoke enforcement seams.
- [ ] Invoke session stop for every profile before `BlockedProfiles.deleteProfile`, then clear residual restrictions and end Live Activity before entity deletion completes.
- [ ] Re-run the focused test green.
- [ ] Add a DEBUG fault hook after entity delete staging and before final save; prove an origin wipe failure leaves the generation unchanged and the reset at `.recreating`.
- [ ] Run the failure-ordering test red, implement the hook, and run it green.

### Task 5: Requested hardening and minor cleanup

**Files:**
- Modify: `Foqos/CloudKit/ProfileSyncManager.swift`
- Modify: `Foqos/CloudKit/SyncEngine/ResetController.swift`
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineController.swift`
- Modify: `FoqosTests/ProfileSyncAccountResolverTests.swift`
- Modify: `FoqosTests/WipeInterleavingTests.swift`
- Modify: `FoqosTests/SyncEngineFacadeTests.swift`
- Modify: `FoqosTests/SyncEngineResetTests.swift`
- Modify: `FoqosTests/Mocks/MockSyncEngineControlling.swift`

**Interfaces:**
- Adds DEBUG-only counters that assert the maximum number of concurrent reattachments is `1`.
- Adds `ResetOutbox.removeEstablishmentSave()` for stop-time cleanup.
- Records both `wipe` and `clearRemoteAppSelections` in `MockSyncEngineControlling` reset calls.

- [ ] Add overlapping adoptions for generations 2 and 3; assert final generation 3 and maximum concurrent reattachments 1.
- [ ] Convert WipeInterleaving S-W1, S-W3, and S-W4 to call the real manager adoption path before asserting gate behavior.
- [ ] Record the mock wipe flag and assert `resetSync(wipe: true)` forwards `wipe: true`.
- [ ] Add establishment-save removal to `abandonForStop` and pin it with a wiping-stage stop test.
- [ ] Assert the origin wipe driver/outbox contains no `.deleteRecord` changes.
- [ ] Remove the unreachable `SyncedEstablishment` branch from `localIsStrictlyNewer` and remove its direct-call test.
- [ ] Run each changed focused test class after its red-green cycle.

### Task 6: Verification and signed publication

**Files:**
- Verify all modified Swift, schema, and plan files.

- [ ] Run `./scripts/check-sync-guards.sh` and require exit 0.
- [ ] Run `swift-format lint --recursive .` and require exit 0.
- [ ] Confirm simulator UUID `966A5E52-D795-4AB5-86A5-67D17B2D6413` is booted.
- [ ] Run the full `FamilyFoqos` suite once through `/opt/homebrew/lib/ruby/gems/4.0.0/bin/xcpretty` and capture the raw log.
- [ ] Review `git diff --check`, status, test counts, warnings, and failures.
- [ ] Create one to three logical GitHub-signed commits with `createCommitOnBranch`, using the current remote head as `expectedHeadOid` and base64 additions for every changed file.
- [ ] Request code review before any merge, reply to the planner with finding-by-finding evidence, and remove the worktree.
