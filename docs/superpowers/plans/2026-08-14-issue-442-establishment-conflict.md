# Issue #442 Establishment Conflict Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make fixed-name establishment conflicts converge instead of leaving a pending seed that fails again on every launch.

**Architecture:** Give `SyncEngineController` a narrow reconciliation path based on server/local generation ordering, preserve `ResetController` semantics for live resets, and let `RecordProvider` materialize the server change tag for local-winner retries.

**Tech Stack:** Swift 6, CloudKit, CKSyncEngine, XCTest, Xcode simulator gate.

## Global Constraints

- Work only in `.worktrees/build2-442` on `fix/442-establishment-conflict`.
- Base is main `3410b5d`; publish reserved version 2.0.43 (62) across all 12 configurations.
- Use synthetic fixtures only; never include private diagnostics or real family data.
- Preserve higher-generation adoption and existing live-reset semantics.
- Do not broaden this fixed-name lifecycle into generic entity conflict handling.
- Use new signed commits; request independent exact-head review; the planner merges.

### Task 1: Capture the recurrence and metadata contract

**Files:**
- Modify: `FoqosTests/SyncEngineControllerTests.swift`
- Modify: `FoqosTests/RecordProviderTests.swift`

- [ ] Add an equal-generation, no-reset conflict test proving server system fields are cached, the
  pending seed resolves, and a simulated relaunch does not enqueue `SyncEstablishment` again.
- [ ] Run only that test and confirm RED for the unresolved seed or missing metadata.
- [ ] Add focused tests for lower-generation retry, higher-generation adoption, and provider
  materialization from cached system fields.

### Task 2: Implement minimal reconciliation

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineController.swift`
- Modify: `Foqos/CloudKit/SyncEngine/RecordProvider.swift`

- [ ] Route establishment success through reset handling, then cache fields and resolve a normal
  seed when no reset remains.
- [ ] Route `serverRecordChanged` through reset handling first, decode the server establishment,
  and compare generations: adopt higher, reconcile equal, or cache/re-enqueue lower.
- [ ] Materialize cached establishment fields before updating current payload values.
- [ ] Run the new focused tests and existing controller/provider/reset suites until GREEN.

### Task 3: Version and delivery verification

**Files:**
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj`

- [ ] Set every `MARKETING_VERSION` to 2.0.43 and every `CURRENT_PROJECT_VERSION` to 62.
- [ ] Format touched Swift files and run recursive format lint plus `git diff --check`.
- [ ] Run the complete simulator-gated test suite and standalone Debug build using agent `build2`,
  session `implement_beta_fixes`.
- [ ] Commit with signing, push the branch, open a ready-for-review PR closing #442, verify checks,
  request independent exact-head review through AMQ, and report the result to the planner.
