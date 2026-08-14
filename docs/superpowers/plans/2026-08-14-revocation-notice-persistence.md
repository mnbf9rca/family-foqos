# Family Revocation Notice Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this
> plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the existing confirmed-revocation alert after termination and pin both child PIN
cache representations without global mode state.

**Architecture:** A tiny injected-`UserDefaults` store owns one pending Bool. The common
revocation transition orders cleanup, flag persistence, then publication; startup and dismissal
map the flag to the existing alert state. A DEBUG-only count accessor observes the private child
PIN cache in tests.

**Tech Stack:** Swift 6, SwiftUI, CloudKit, XCTest, UserDefaults, Xcode simulator gate.

## Constraints

- Work only in `.worktrees/build1-revocation-persistence` on
  `fix/revocation-notice-persistence`, based on main `312a773`.
- Preserve the exact title, message, and root alert introduced by #445.
- Persist only after confirmed cleanup/mode persistence; clear on alert dismissal.
- Do not read or mutate `AppModeManager` from `ChildRevocationCacheTests`.
- Publish reserved version 2.0.45 (64) using only new signed commits; the planner merges.

### Task 1: Add failing persistence and cache tests

**Files:**
- Modify: `FoqosTests/ChildRevocationTests.swift`
- Modify: `FoqosTests/ChildRevocationCacheTests.swift`

- [ ] Simulate process termination with two notice-store instances backed by one isolated suite.
- [ ] Pin startup restoration, transition ordering, and dismissal clearing.
- [ ] Pin the child cache count before and after confirmed revocation alongside the persisted key.
- [ ] Run the focused tests and confirm RED from missing production APIs.

### Task 2: Implement the minimal persistence path

**Files:**
- Modify: `Foqos/CloudKit/CloudKitManager.swift`
- Modify: `Foqos/Utils/LockCodeManager.swift`

- [ ] Add the pending-notice store with production and isolated-suite construction.
- [ ] Restore the existing alert message at manager initialization when pending.
- [ ] Order confirmed cleanup, pending persistence, and message publication.
- [ ] Clear pending persistence and the message on dismissal.
- [ ] Add the DEBUG-only cached child lock-code count accessor.
- [ ] Run focused tests until GREEN and format changed Swift files.

### Task 3: Version, verify, review, and deliver

**Files:**
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj`

- [ ] Set all `MARKETING_VERSION` values to 2.0.45 and all
  `CURRENT_PROJECT_VERSION` values to 64.
- [ ] Run focused and full tests, Debug build, recursive format lint, diff checks, and project
  structural/version/sync/privacy guards.
- [ ] Verify exact-head signatures and a clean worktree.
- [ ] Obtain independent exact-head review and address Critical/Important findings with new signed
  commits and proportionate reruns.
- [ ] Push without force, open a ready PR linked to #445/#435, confirm version gate and
  mergeability, then send exact-SHA evidence to the workflow reviewer and planner.
