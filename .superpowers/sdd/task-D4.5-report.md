# Task D4.5 Report: Re-snapshot App Group After V1 to V2 Migration

## Status

Implemented Task D4.5 (#266) only.

## Grounding

- `SharedData.ProfileSnapshot` has no `profileSchemaVersion` field.
- `BlockedProfiles.getSnapshot(for:)` rebuilds a snapshot from the live model and cannot prove
  a persisted app-group write occurred.
- A persisted V1 profile with an active legacy schedule migrates to V2 schedule trigger flags
  and split start/stop schedules. Those fields are stored by `SharedData.ProfileSnapshot`.
- The task grounding matches `ProfileMigrationUtil` and the deferred session-end path in
  `StrategyManager`; no migration behavior was simplified or loosened.

## TDD Evidence

### RED

Added `MigrationSnapshotTests.testGivenV1ScheduledProfile_WhenMigrated_ThenAppGroupSnapshotContainsV2Schedule`.
The test configures an isolated `SharedData` suite, persists a true V1 profile through
`TestModelContainer.create().mainContext`, writes its pre-migration snapshot, migrates it, and
reads `SharedData.snapshot(for:)`.

Command:

```sh
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -only-testing:FoqosTests/MigrationSnapshotTests | xcpretty
```

Result: expected failure (`xcodebuild` exit 65). The XCTest result bundle reported stale
`startTriggersSchedule == false` where the migrated snapshot must contain `true`.

### GREEN

Added `BlockedProfiles.updateSnapshot(for:)` after the successful save and
`DeviceActivityCenterUtil.scheduleTimerActivity(for:)` in both required migration paths.

Re-ran the focused command above. Result: exit 0, `Test Succeeded` (1 passed, 0 failed).

## Files Changed

- `Foqos/Utils/ProfileMigrationUtil.swift`
  - Refreshes each successfully migrated profile's app-group snapshot after schedule registration.
- `Foqos/Utils/StrategyManager.swift`
  - Refreshes the deferred profile's app-group snapshot after its successful session-end migration
    save and schedule registration.
- `FoqosTests/MigrationSnapshotTests.swift`
  - Adds the persisted V1-to-V2 app-group snapshot regression test.

## Verification

- Focused XCTest: passed, 1 test / 0 failures.
- `swift-format lint Foqos/Utils/ProfileMigrationUtil.swift Foqos/Utils/StrategyManager.swift FoqosTests/MigrationSnapshotTests.swift`: passed.
- `git diff --check`: passed.

## Self-Review

- Confirmed both snapshot writes occur only after the existing successful `context.save()` and
  after the existing DeviceActivity reschedule.
- Confirmed no changes to V1-to-V2 migration transformations, active-session deferral, legacy
  fallback behavior, #311, #305, or #315 subsystems.
- Confirmed the test reads persisted `SharedData.snapshot(for:)`, not a live recomputation, and
  asserts V2 fields actually introduced by migration.
- Confirmed no raw `@Query`, lock checks, or logging behavior was touched.

## Concerns

None.

## Task Review Fix: Deferred Save Failure

### Change

Updated `StrategyManager`'s deferred session-end migration path so a failed
`context.save()` logs the error and exits before the migration success log,
DeviceActivity reschedule, or app-group snapshot refresh. Successful migration
behavior is unchanged.

No additional focused test was added: the existing `MigrationSnapshotTests`
coverage verifies the persisted snapshot after a successful migration, while
the deferred session-end path has no suitable injection seam for forcing a
`context.save()` failure and observing its scheduling side effects. The fix is
a direct control-flow guard immediately after the throwing save.

### Verification

- `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' -only-testing:FoqosTests/MigrationSnapshotTests 2>&1 | xcpretty`: passed, exit 0.
- `swift-format lint Foqos/Utils/StrategyManager.swift Foqos/Utils/ProfileMigrationUtil.swift FoqosTests/MigrationSnapshotTests.swift`: passed.
- `git diff --check`: passed.

### Review Scope

- Only `Foqos/Utils/StrategyManager.swift` changed for this fix.
- No migration transformations, startup migration behavior, or snapshot test behavior changed.
