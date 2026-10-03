# Remove the background-stop safeguard implementation plan — slice 3

> **For agentic workers:** Use `superpowers:executing-plans` in the assigned build1 worktree, with the existing Herdr reviewer. Checkbox steps are the task tracking. Planner changes only this plan.

**Goal:** Remove Disable Background Stops as a user setting and runtime authority, so configured V2 stops and existing authorization rules alone decide completion.

**Architecture:** Delete the old veto and UI/API consumers. Keep the existing policy for exact-session matching, Manual permission and geofence checks; retain inert persisted/deployed columns to avoid unnecessary data/schema migration.

**Tech stack:** Swift/SwiftUI, SwiftData, FoqosShared, DeviceActivity and private-account CloudKit.

**Spec:** [#508 rulebook](../specs/2026-10-02-508-v2-conditions-rulebook.md), R5 and release scope; [slice 2](2026-10-03-507-starting-and-stopping.md). Implements #514 after slice 2; research baseline `52fb651`. Build against the actual merged slice-2 head and rerun its tests, rather than copying old line-number behavior.

## Global constraints

- R5: Remove the "Disable Background Stops" safeguard entirely. The profile's own stop options decide completion. Stored/synced old values are ignored whenever V2 is authoritative. Preserve the old veto only for genuine pre-update V1 wire snapshots or deferred active V1 sessions, behind the schema-version boundary; no new human ruling is needed.
- Preserve Shortcut device-unlock and Manual-stop authorization, relevant geofence checks and outgoing Manual/geofence eligibility for scheduled takeover. Timer/Schedule expiry cannot be vetoed by geofence.
- Preserve slice-2 admission, provisional registration, exact-session cancellation and authoritative restore. No new universal stop permission, strategy pairing or fallback to Emergency Unblock.
- No new user copy or replacement warning. Deleting the safeguard's copy is sufficient. Actual iOS delivery remains best effort.
- Keep genuine V1 reader/data and active-session conversion boundaries. No schema-field deletion, force/amended commits or unreserved writes. Simulator owner is `build1`, session `collab`.

## Stopping point

This slice removes every V2 flag veto, exposed control, debug/status consumer and V2 sync meaning. The widget count line is removed by build2 in #518/#519 by orchestrator ruling, and is a dependency to verify in the final epic coverage check. It does not fix recurrence registration/precedence/catch-up (#515–#517, slice 4), or authorize ordinary links to stop: slice 5 (#521) removes the separate Link stop and defines verified tag switching. Until then, existing configured legacy link-stop paths only lose the flag veto; do not expand their admission or add new link behavior. Cards/widgets' independent summaries remain build2's #518/#519 work.

## Exact reservations proposed to orchestrator

Paths refine the rulebook's #514 row. Transfer overlapping slice-2 paths before implementation; planner does not grant ownership.

| Group | Exact paths |
| --- | --- |
| Policy and completion adapters | `Packages/FoqosShared/Sources/FoqosShared/BackgroundStopPolicy.swift`; `Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift`; `Packages/FoqosShared/Sources/FoqosShared/Timers/StopScheduleTimerActivity.swift`; `Foqos/Utils/StrategyManager.swift`; `Foqos/Intents/IntentError.swift`; `Foqos/Intents/ShortcutStatus.swift` |
| Setting removal and inert data | `Foqos/Models/BlockedProfiles.swift`; `Foqos/Views/BlockedProfileView.swift`; `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift`; `Foqos/CloudKit/SyncModels.swift`; `Foqos/CloudKit/SyncEngine/SyncApplyService.swift`; `Foqos/CloudKit/SyncEngine/SyncPayloadEquality.swift` |
| Remaining presentation consumers | `Foqos/Views/DebugView.swift`; `Foqos/Components/Debug/ProfileDebugCard.swift` |
| Existing tests under `FoqosTests/` | `BackgroundStopPolicyTests.swift`; `StrategyManagerBackgroundTests.swift`; `ScheduleTimerActivityTests.swift`; `ShortcutsStatusTests.swift`; `SyncApplyServiceTests.swift`; `SyncPayloadEqualityTests.swift`; `UpdateProfileTests.swift`; `ProfileSnapshotStopConditionsTests.swift`; `SessionTimerEndTests.swift` |
| New test | `FoqosTests/BackgroundStopSafeguardRemovalTests.swift` |
| Serialized finalization | `FamilyFoqos.xcodeproj/project.pbxproj` only after project-file gate for test membership/mandatory versions |

Widget view is read-only in this slice: build2 owns the one-line count cleanup. No `StartStopActionResolver` edit: slice 2 already removes `hasUsableStop`. Schema/manifest files remain read-only: deployed `disableBackgroundStops` declarations stay. New consumer discovered by preflight requires exact reservation arbitration before editing.

## Review focus

1. Old true values from local store, app-group snapshot or CKRecord must not revive a veto (Tasks 1/2).
2. Removing the veto must not turn an NFC-only session into an authorized Shortcut stop (Task 1).
3. Shortcut geofence/device-unlock denial and session replacement during async checks must remain effective (Task 1).
4. Due configured schedule/Timer stops remain accepted while geofence is unavailable (Task 1).
5. Ignoring old payload differences must not discard genuine changes to stop settings or unrelated fields (Task 2).

## Task 1: Delete vetoes while retaining condition authorization

**Files:** policy/adapters/IntentError/ShortcutStatus and their existing tests.

**Interfaces:** `BackgroundStopPolicy.evaluate(channel:sessionMatchesProfile:geofence:stopConditions:) -> Decision` retains current types, removes the V2 `disableBackgroundStops` parameter and `.backgroundStopsDisabled` denial. Genuine V1 callers perform their existing old veto before this policy, explicitly guarded by snapshot missing/V1 schema or active session profile schema < 2 with conversion deferred. Never classify a V2 record as V1 from a missing condition blob. Keep the existing V1 error surface/copy in that bounded path; remove obsolete V2 mapping branches. Shortcut/takeover continue requiring `conditions.manual`; schedule requires `conditions.schedule` and bypasses geofence independently of what a caller supplied. Timer expiry uses slice 2's own exact-session path. Retain `IntentError.backgroundStopsDisabled` only for the genuine V1 veto path; V2 no-matching-session maps to the existing no-active-session error.

- [ ] Change contrary tests to `testOldTrueFlagDoesNotVetoConfiguredStops`: persisted true profile/snapshot executes allowed Shortcut Manual stop, configured schedule stop on each actual schedule adapter, and exact-session Timer expiry. False/true cases have equal effects and clear only the matching session. Registration/Timer setup is already slice 2's responsibility.
- [ ] Add `testGenuineV1VetoPreservedUntilConversion`: shipped-V1 snapshot without schema, explicit V1 snapshot, and a deferred active V1 session with true flag survive the same schedule/Shortcut/link stop that a V2 fixture accepts. After ending and converting that profile, true retained column no longer vetoes V2 stops. No missing-V2-blob fallback to V1.
- [ ] Retain/add `testShortcutAndTakeoverStillRequireManualAndGeofence`: NFC-only stop refuses Shortcut and takeover; Manual+unavailable/not-satisfied geofence refuses; satisfied/no-rule allows. Schedule with unavailable geofence allows; wrong profile/session and schedule disabled refuse. Retain device-unlock setting change and replacement-during-geofence tests; replace the old flag mutation case with a real Manual permission mutation.
- [ ] Add `testShortcutStatusShowsConfiguredScheduleWithOldTrueFlag`: identical next stop time/copy under true and false, preserving accepted countdown precedence and genuine V1 unavailable-timing behavior. Existing link adapter loses only its flag guard; use a configured/disabled stop test to prevent accidental permission broadening while slice 5 is pending. Include exactly the old V2 combination `stopConditions.deepLink == true` plus retained safeguard true: configured link stop follows current configured behavior, disabled stop remains denied, then slice 5 removes Link stop authority entirely.
- [ ] Run owning tests red through the wrapper, delete V2 early vetoes/switch cases and update policy calls. Remove every unversioned production branch on the field, including baseline `toggleSessionFromDeeplink`, `stopSessionFromBackground`, both schedule callbacks and status. Reuse slice-2 guarded completion so replacement timers survive. Rerun green; signed commit `fix: let configured stops run without a background veto`.

## Task 2: Remove the setting and neutralize old serialized data

**Files:** BlockedProfiles/editor/snapshots/sync/equality/widget/debug and removal tests.

**Interfaces:** Keep the existing SwiftData Boolean and optional snapshot field as inert legacy columns, with a comment stating no V2 runtime authority; no rename or data rewrite is needed. Remove setting parameters from app create/update/clone APIs and editor state/bindings. SyncedProfile keeps its existing field/key declaration for additive schema accounting, but decodes/constructs/exports it as false for V2, never reflecting a stored V2 setting. Only genuinely unmigrated V1 wire data may retain the value at its explicit version gate until conversion. New V2 ProfileSnapshots write nil/false; genuine V1 snapshots preserve the old value for the bounded active/pre-update lifecycle. SyncApplyService ignores it for V2; genuine V1 retained data remains governed by the existing active-session deferral. Remove it from V2 semantic payload equality; any retained genuine V1 comparison must be explicitly version-gated. Do not alter other profile flags or stop-owned data.

- [ ] Add `testIncomingOldFlagIgnoredAndStopChangesStillApply`: CKRecord true/false, old JSON snapshot and local persisted true all preserve correct operational stops. Compare two otherwise equal SyncedProfiles with differing old values as semantically equal; a Manual/Schedule/Specific/timer change remains unequal and applies normally. Outgoing V2 wire and new V2 snapshot values are false/nil; genuine V1 values remain behind the boundary; deployed schema declarations remain intact.
- [ ] Add `testEditorCloneSnapshotHaveNoSafeguardSetting`: actual editor save/clone no longer accepts or copies a chosen flag; old column may remain true but has no observable permission or count/status meaning. Reopen a preexisting true profile without changing its stop settings; assert identical settings after save and no warning/replacement control. Preserve context.save/error handling and snapshot publication order.
- [ ] Run red; delete the editor toggle/help, save arguments, debug card/export row. Verify build2’s #518/#519 handoff includes widget count removal; no widget edit/reservation belongs here. No mass formatter pass.
- [ ] Rerun green. Run `rg -n 'disableBackgroundStops|backgroundStopsDisabled|Disable Background Stops' Foqos Packages FoqosWidget --glob '*.swift'`: each remaining hit must be an inert storage/wire declaration/neutral assignment or an explicit genuine-V1 data description, never a V2 control, comparison, count or permission branch. The only behavioral exceptions are explicitly version-gated genuine V1 paths; pin each in the V1 preservation test. Run schema drift/check scripts to prove constant legacy declarations still satisfy the deployed manifest, without modifying schema tooling. Signed commit `refactor: remove the background stop setting`.

## Task 3: Verify and hand off

- [ ] Use `scripts/xcode-stream.sh --agent build1 --session collab -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/<ClassName>` for the owning classes; then the full target once. Require `TEST SUCCEEDED`. Run changed-file Swift formatting/lint and `git diff --check`.
- [ ] Agent drives throwaway, uncommitted simulator UI tests: reopen formerly true profile, confirm toggle/help absent; normal configured Manual/Shortcut stop works, NFC-only Shortcut remains denied; scheduled status remains visible. Preserve locked Child editor restrictions and latest build2 widget layout/countdown. Remove temporary scripts/project changes before final diff. Unit-driven schedule/Timer callback acceptance needs no human manual simulator work; actual delayed OS delivery evidence is covered by slices 2/4 release verification.
- [ ] Obtain orchestrator project-file transfer, update mandatory marketing/build versions and required membership, run version gate and wrapper build with `--xcbeautify`; require `BUILD SUCCEEDED`. Build1 carries this approved plan in the implementation PR, ready rather than draft, with exact head/base/checks, independent exact-head review and once-only `greptile-review` label when ready. Orchestrator asks the human before that specific merge.
- [ ] Report exact reservation release, slice-4/5 remainder and actual evidence. Do not claim #507 finished; every slice remains required before V2 App Store release.

## Planner review record

Round 1: approved with correction, 1 blocking and 3 non-blocking. Retained only genuine V1 version-gated veto behavior; V2 wire/snapshot fields are neutral, interim old link-stop+true fixture is explicit. Orchestrator assigned widget count deletion to build2’s #518/#519 PR; that path is removed from this reservation. Round 2 approved by reviewer with 0 blocking and 0 non-blocking findings; no separate docs PR.
