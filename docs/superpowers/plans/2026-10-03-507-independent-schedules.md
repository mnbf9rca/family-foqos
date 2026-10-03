# Independent V2 schedules implementation plan — slice 4

> **For agentic workers:** Use `superpowers:executing-plans` in build1's assigned worktree with the existing Herdr reviewer. Checkbox steps track work. Planner changes only this plan.

**Goal:** Scheduled starts and stops run by their own weekday/time recurrences; V2 never catches up a historical start or revives a retained V1 schedule.

**Architecture:** Keep the existing start and stop-only activities, with separate registrations and shared pure occurrence queries. Reuse slice 2's admission/registration/ownership transaction and slice 3's V2 policy. Keep genuinely unmigrated V1 activity handling behind its explicit version boundary.

**Tech stack:** Swift, Foundation Calendar, SwiftUI, DeviceActivity, FoqosShared app-group snapshots and existing private sync.

**Spec:** [#508 rulebook](../specs/2026-10-02-508-v2-conditions-rulebook.md), R1/R7/R8 and approved late-callback decision; [slice 2](2026-10-03-507-starting-and-stopping.md), [slice 3](2026-10-03-507-remove-background-stop-safeguard.md). Implements #515–#517. Research baseline `52fb651`; implementation starts from merged slices 2/3 and current build2 presentation head.

## Global constraints

- Start and stop each own weekdays/hour/minute. OR stops remain independent of session origin. Monday 09:00 start / Friday 17:00 stop must never stop Monday 17:00.
- Editor refuses only an enabled start/stop pair sharing a weekday and equal hour/minute. Equal clocks on disjoint weekdays and distinct events less than 15 minutes apart are valid. DeviceActivity minimum interval constrains internal registration windows only.
- No foreground/app-launch/refresh creation for missed scheduled starts. A real late OS start callback skips if a stop occurrence lies from its intended start occurrence through delivery time; otherwise starts once. No arbitrary grace timeout or persisted stop-callback history.
- Runtime stop wins at equal moments in either callback order, including malformed incoming data that could not be saved locally. Invalid originating starts still refuse before effects. Keep existing stopped-occurrence suppression.
- Incoming admission/countdown establishment precedes takeover. Outgoing Manual permission and permitting geofence remain; no V2 background veto. Use exact-session ownership guards for shared completion/restriction effects.
- Version-gate all V1 schedule reads, registration, cleanup and display to genuine V1, including pre-update wire/active-session deferral. Retain legacy columns/data; do not delete shipped data or protect unreleased V2 states.
- Approved copy C9/C10 below; use existing labels for Start/Stop/day summaries and existing error surfaces. Agent runs all simulator UI checks with throwaway uncommitted scripts; owner `build1`, session `collab`. Signed commits, no amend/force.

## Stopping point

Completes recurrence runtime, validation and V1-isolation work for #515–#517. Does not implement verified tag payloads/R10 (#521, slice 5), rewrite general card summaries owned by build2 (#518/#519), retire V1 reading (#59) or change the release process. If build2 already version-gated schedule display, use it and avoid redundant edits. All epic work/device release evidence remains required before V2 App Store release.

## Exact reservations proposed to orchestrator

Serialize shared paths after slices 2/3. Narrow presentation paths need transfer from build2 only if its merged changes do not already satisfy #517.

| Group | Exact paths |
| --- | --- |
| Registration and refresh | `Foqos/Utils/DeviceActivityCenterUtil.swift`; `Foqos/Utils/PreActivationReminderScheduler.swift`; `Foqos/FoqosApp.swift` (remove catch-up call only); `Foqos/Utils/StrategyManager.swift` (schedule cleanup/suppression integration only) |
| Shared recurrence/runtime | `Packages/FoqosShared/Sources/FoqosShared/ProfileScheduleTime.swift`; `Packages/FoqosShared/Sources/FoqosShared/ProfileConditionValidation.swift` (slice-2 file); `Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift`; `Packages/FoqosShared/Sources/FoqosShared/Timers/StopScheduleTimerActivity.swift`; `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift` |
| Editor validation | `Foqos/Models/TriggerValidator.swift`; `Foqos/Models/TriggerConfigurationModel.swift`; `Foqos/Components/BlockedProfileView/ScheduleTimePicker.swift`; `Foqos/Views/BlockedProfileView.swift` (schedule help/validation only) |
| Narrow display version gates, conditional transfer | `Foqos/Components/BlockedProfileCards/ProfileScheduleRow.swift`; `FoqosWidget/Views/ProfileWidgetEntryView.swift` |
| Existing tests under `FoqosTests/` | `PreActivationReminderSchedulerTests.swift`; `ScheduleWindowValidationTests.swift`; `ScheduleTimerActivityTests.swift`; `ProfileScheduleTimeTests.swift`; `StopScheduleIntervalTests.swift`; `ScheduleSuppressionTests.swift`; `ScheduleSuppressionMergeTests.swift`; `ActiveWindowTests.swift`; `ShouldBeActiveNowTests.swift`; `TriggerValidatorTests.swift`; `TriggerConfigurationModelTests.swift`; `ProfileScheduleRowDataTests.swift`; `SharedDataScheduledEndTests.swift`; `ProfileStartAdmissionTests.swift` |
| New test | `FoqosTests/IndependentScheduleRuntimeTests.swift` |
| Serialized finalization | `FamilyFoqos.xcodeproj/project.pbxproj`, membership/mandatory versions only after project-file gate |

No scanner/link producer, schema manifest, operator doc or version-retirement edit. Preflight discovered consumers outside this list require exact reservation arbitration.

## Review focus

1. Start registration failure cannot remove/prevent a valid stop registration (Task 2).
2. Stop-first/start-first equal-moment signals cannot resurrect an occurrence (Task 3).
3. Late callbacks across differing weekdays, midnight and DST must use actual recurrence occurrences rather than same-day clock pairing (Tasks 1/3).
4. Refresh after power-off cannot create a session, while existing authoritative adoption/reconciliation still works (Task 3).
5. A stale V1 column/activity must have no V2 effect but genuine active V1 behavior must survive its boundary (Tasks 2/4).

## Task 1: Replace paired-window validation and queries

**Files:** ProfileScheduleTime/shared validation/TriggerValidator/editor picker and existing time/validation tests.

**Interfaces:** Add `ProfileScheduleTime.previousDailyClockOccurrence(atOrBefore: Date, calendar: Calendar = .current) -> Date?` (clock match ignoring weekday) and `previousOccurrence(atOrBefore: Date, calendar: Calendar = .current) -> Date?` (enabled weekdays) and `hasOccurrence(from: Date, through: Date, calendar: Calendar = .current) -> Bool` (inclusive bounds), reuse the existing next-occurrence API where possible. Validate nonempty usable weekdays and hour 0...23/minute 0...59 before Calendar construction. Use calendar-day math, retaining current timezone and Calendar matching conventions; never add fixed 86400-second days. Add `conflicts(with: ProfileScheduleTime) -> Bool` for shared enabled-day/equal-clock validation and picker reuse.

- [ ] Replace contrary window tests with `testIndependentValidationMatrix`: Mon09:00/Fri09:00 valid; Mon09:00/Fri09:10 valid; Mon09:00/Mon09:01 valid; Sun23:59/Mon00:00 valid; Mon09:00/[Mon,Fri]09:00 uses exact C10; disabled or disjoint recurrences do not conflict. Empty/bad weekdays/hour/minute use C9. Timer duration limits remain unrelated.
- [ ] Add `testOccurrenceQueriesRespectOwnWeekdaysAndInclusiveBounds`: Mon09 start/Fri17 stop has no stop Monday evening; interval spanning Friday includes its 17:00 stop; exact boundary includes it. Test overnight, weekly rollover, timezone and DST fixtures with explicit calendar, including local-time-zone travel between start and delivery so occurrence resolution agrees with the current OS wall-clock schedule. A wall-clock gap/duplicate follows existing Calendar conventions rather than inventing a second product policy. Pin a single `now` per test and derive all dates.
- [ ] Run red; remove `scheduleWindowMinutes`, V2 `activeWindowStart`/`shouldBeActiveNow` paired behavior and their unused callers/tests after Task 3 consumer migration. No helper remains solely to keep the superseded tests green. Shared validator and ScheduleTimePicker use the same conflict predicate; picker tests assert selected weekdays affect Save availability. Use C10 without near-24-hour-window advice.
- [ ] Rerun green; signed commit `fix: validate and query independent schedule recurrences`.

## Task 2: Register both events independently and version-gate names

**Files:** DeviceActivityCenterUtil/activities/refresh and existing registration/interval tests.

**Interfaces:** `requiredActivities(for:)` returns start name whenever enabled valid V2 start/selection is usable, and stop-only name whenever enabled valid V2 stop exists, regardless of start or needsAppSelection. Keep the existing UUID start activity and `StopScheduleTimerActivity:<UUID>` stop activity names; no additional scheduler service. V2 start registration window begins at its configured time and ends one minute before that same time next day (1439 minutes), independent of stop. Reuse the existing `stopScheduleInterval` for stop's OS-valid internal window, ending at its configured stop time. Both repeat; callbacks own weekday checks. Stable names remain valid when recurrence days change. Compare only the desired start/end hour and minute and repeats against `DeviceActivityCenter.schedule(for:)`, rather than whole schedule/DateComponents equality (OS-normalized calendar/timezone must not manufacture a change); do not stop/restart an unchanged monitored schedule at refresh or session end. Register only missing/changed schedules. Before any new/replaced V2 start registration, persist/read back a device-local `SharedData.startRegistrationNotBefore(for profileId: UUID) -> Date?` cutoff equal to registration time; do not register if that publication fails. Callback refuses any intended occurrence before that cutoff. This prevents an immediate mid-window registration callback from creating a historical start even when monitoring was missing after power-off. Cutoff is registration metadata, not synced profile suppression, a stop-event history or a grace timeout; unchanged registrations do not advance it. Remove it on start-disable/profile removal.

- [ ] Add `testBothEventsRegisteredDespiteStartFailure`: Mon09/Fri17 attempts two activities and independent schedules; injected start failure returns failure but still attempts/preserves stop. Start disabled removes only start; stop disabled removes only stop; selection pending removes start while stop remains. Reconciliation, required-name warnings and actual registrar agree. Unreadable/invalid recurrence fails closed without inventing a window.
- [ ] Add `testRefreshAndSessionEndDoNotRestartUnchangedSchedule`: after refused/skipped Mon09 start, refresh and full session-end registration at Mon14 call no stop/startMonitoring for the unchanged start, cause no originating session and leave late genuine existing callbacks eligible. Add `testMissingOrChangedRegistrationCannotCatchUp`: newly registered/edited start at Mon14 publishes cutoff first; immediate intervalDidStart for Mon09 is refused, next valid occurrence works. Failed cutoff write means no new start registration; independent stop still attempts.
- [ ] Add `testStartEndIsArtificialAndStopOwnsItsDays`: start interval end never completes a V2 session; stop callback on Monday17 does nothing for Fri17, on Friday17 ends matching profile regardless of Manual/tag/Shortcut/schedule origin. Wrong profile, invalid/disabled stop and future clock return no effects. Keep 00:00/00:10/00:15 stop internal-interval regression checks.
- [ ] Run red; decouple start/stop attempts and cleanup. All legacy schedule fallbacks are `profileSchemaVersion < 2` or the approved shipped-V1 missing-schema snapshot path. A V2 start callback cannot fall back to `profile.schedule` when its V2 start is off. A V2 combined start end is inert even when legacy stop data disagrees. Genuine active V1 start/end handling remains unchanged.
- [ ] Rerun green; signed commit `fix: register schedule start and stop independently`.

## Task 3: Runtime late delivery, stop precedence and no foreground catch-up

**Files:** activities/shared state/refresh/FoqosApp and suppression/runtime tests.

**Interfaces:** `ScheduleTimerActivity.start(for:now:calendar:)` derives the most recent daily start-clock match at/before actual callback delivery, ignoring weekday, then requires that specific occurrence’s weekday to be enabled. Monday-only callback delivered Tuesday08 resolves to Monday09; Tuesday09’s on-time daily callback resolves to disabled Tuesday and does nothing. It never searches backward for Monday to rescue a refused/skipped occurrence. It and declines if that occurrence predates the schedule configuration update or the device-local registration cutoff, is already suppressed, or a valid configured stop has an occurrence in the inclusive start-to-delivery interval. No extra age/grace heuristic: remove the V2 one-minute-age gate as part of the callback occurrence query. Call only from actual monitor delivery, never refresh. Keep genuine V1 age behavior version-gated. Pass the occurrence into slice 2's schedule-origin transaction for suppression bookkeeping, while the actual session/timer starts at the accepted delivery time.

`StopScheduleTimerActivity.stop(for:now:calendar:)` accepts only its own latest due valid stop occurrence. Re-read/capture exact session under slice-2 ownership transaction, complete only if the session began at/before that occurrence, then guarded restriction effects and suppression update. A delayed old stop cannot end a session started after its occurrence. Clear only that session's timer/origin/deadline. No persisted stop-event history. A real late daily stop-window callback can complete a missed prior enabled stop occurrence: session begun Thursday, Friday17 missed, Saturday callback resolves latest enabled Friday17 and ends that same session. This is late stop acceptance, not start catch-up; a session begun after Friday17 remains untouched.

- [ ] Add `testStopWinsInEitherOrder`: overlapping-day equal clocks in raw incoming snapshot, Manual existing session and idle fixtures. Invoke real start/stop adapters in both orders; no surviving/new scheduled session, no candidate registration when start is inadmissible/due stop wins. Duplicate callback after an early stop cannot restart that occurrence; next scheduled occurrence remains eligible.
- [ ] Add `testRealLateCallbackSkipsAfterInterveningStopOtherwiseStartsOnce`: Mon09/Fri17 delivery Monday evening starts once with Timer saved 37; Friday18 delivery for that start skips; overnight start22/stop06 delivery03 accepts once, delivery07 skips; disjoint equal clocks Friday stop does not veto Monday start. Include Monday-only start refused on Monday and Tuesday09 daily callback creating nothing, configuration update after the supposed start occurrence, duplicate while active, takeover refusal and registrar failure preserving A. Timer begins at delivery, not a manufactured historical deadline.
- [ ] Add `testRefreshNeverOriginatesMissedStart`: actual launch/foreground refresh functions after missed start call zero creators/registrars for session countdowns/restriction activation, while republishing snapshots, future schedule registration, suppression merge, pre-activation reminders and existing authoritative reconciliation still occur. Delete `catchUpMissedScheduleStarts` and its FoqosApp call, not merely hide it behind another predicate.
- [ ] Add `testMissedFridayStopCompletesOnLateSaturdayCallback`: Thursday session ends on late Saturday signal, Monday-created session is not ended by an older Friday occurrence. Add `testLateStopDoesNotEndReplacementStartedAfterOccurrence` and session replacement during callback/commit; exact ownership wins, no global deactivation of the replacement. Existing manual/Timer completion updates suppression for scheduled origin through slice-2 fields, preserving stopped-occurrence sync/merge.
- [ ] Run red/green through wrapper; remove superseded window oracles and update only their relevant expectations. Signed commit `fix: skip historical schedule starts and make due stops win`.

## Task 4: Close V1 schedule leakage in cleanup and display

**Files:** StrategyManager cleanup, shared snapshot usage and conditional narrow display paths; existing row/suppression/runtime tests.

- [ ] Add `testConvertedV2NeverUsesRetainedLegacySchedule`: migrate a V1 fixture, deliberately retain a disagreeing active legacy schedule, disable V2 scheduled start and assert registrar/extension/cleanup/row/widget never consider legacy start active. Enable only V2 stop with different weekdays/time; only independent stop name remains and that recurrence controls completion. Legacy fields stay byte-preserved as data. Genuine V1 active/pre-update fixture retains its old registration/lifecycle and slice-3 gated veto.
- [ ] Run red; make schedule cleanup use actual schema-gated required registrations rather than `hasLegacySchedule` OR V2 flags. Keep safe behavior on database fetch failure. Compare build2's current row/widget changes first; if already correct, no narrow display edit or transfer is needed. Otherwise obtain the listed transfer and add only schema-gated legacy effective-schedule checks. Do not rewrite build2's accepted deadline/countdown/accessibility changes.
- [ ] Rerun green; run `rg -n 'profile\.schedule|hasLegacySchedule|activeWindowStart|shouldBeActiveNow|catchUpMissedScheduleStarts' Foqos Packages FoqosWidget --glob '*.swift'`, verifying every remaining legacy schedule read is explicit genuine-V1 code/data or conversion only, and all V2 paired/catch-up callers are gone. Signed commit `fix: isolate V1 schedules from converted profiles`.

## Approved copy

| ID | Verbatim text |
| --- | --- |
| C9 | Choose the days and time for this schedule. |
| C10 | Choose different moments for scheduled start and stop. |

## Task 5: Verify and hand off

- [ ] Run each owning class through `scripts/xcode-stream.sh --agent build1 --session collab -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/<ClassName>`, then full tests once. Require `TEST SUCCEEDED`, changed-file formatting/lint and `git diff --check`. Record precise failures rather than expanding into unreserved source fixes.
- [ ] Agent drives throwaway simulator UI tests for Mon09/Fri09 save, Mon09/Mon09:01 save, overlapping-day equal-time C10 refusal, distinct start/stop weekday summaries and relaunch without creating a historical session. Include current locked Child behavior and Timer+Schedule with independent valid settings. Remove temporary scripts/project edits. No manual simulator checks delegated to human.
- [ ] Actual DeviceActivity background schedule delivery, especially delayed callbacks while app/device is inactive, requires a physical device: injected callbacks cannot prove OS execution. Route exact-head physical evidence dependency through orchestrator only where fleet cannot run it itself, with why and exact unrun cases; do not claim all release evidence complete from unit/simulator success.
- [ ] Obtain serialized project-file reservation, membership/mandatory version increments, version gate and wrapper build with `--xcbeautify`, requiring `BUILD SUCCEEDED`. Ready implementation PR carries this approved plan. Obtain reviewer exact-head code approval, resolve with new signed commits and label `greptile-review` once when ready. Orchestrator owns human merge gate.
- [ ] Handoff exact head/base/checks/reservation release and slice-5 remainder. No #507 completion/App Store readiness claim until tags/links, build2 presentation, final approved release copy and actual-device evidence are complete.

## Planner review record

Round 1: 2 blocking and 3 non-blocking. Corrected intended daily-start occurrence/weekday handling, idempotent unchanged OS registration, and device-local not-before metadata for truly missing/changed start registration so its immediate callback cannot catch up. Added explicit late-stop, timezone-travel and both re-registration-path tests; expect no display transfer after build2’s approved gates. Round 2 approved with 0 blocking and 1 non-blocking finding; the final efficiency correction compares only configured clock/repeat fields to avoid OS-normalization churn. All other findings resolved; no separate docs PR.
