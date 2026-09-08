# Correct schedule registration warnings

## Decision and scope

Delete the editor's **Fix Schedule** action. It is a second profile-save entry point that bypasses the edit gate. Automatic registration already runs at launch, foreground entry, completed sync fetches, and deferred migration. Keep a passive warning for missing required OS registrations, with copy that describes that condition accurately.

Use one definition of required registrations for the model warning, automatic reconciliation, and direct registration callers. Surface registration failures without treating a saved profile as an unsaved profile or rolling back an active session.

This is a specification for later implementation by the build streams. The only repository change in this PR is this document. Scope covers [#472: locked-profile editing through Fix Schedule](https://github.com/mnbf9rca/family-foqos/issues/472), [#473: app-selection-only profiles shown as out of sync](https://github.com/mnbf9rca/family-foqos/issues/473), and [#474: invisible OS registration failures](https://github.com/mnbf9rca/family-foqos/issues/474), including their shared registration paths. Do not change PR #471 or `SECURITY.md`.

Do not redesign schedule windows, day matching, suppression, takeover policy, sync transport, lock-code lifecycle, or device-local selection confirmation. No new dependency, persistent status field, CloudKit field, background retry job, or registration manager is needed.

## Verified behavior

The source baseline is `02bbdb2dce41df6daea9ec0534c919ffc85eb896`. Paths below are relative to the repository root; line numbers identify this baseline.

| Path | Evidence | Consequence |
| --- | --- | --- |
| `Foqos/Models/BlockedProfiles.swift:229` | `scheduleIsOutOfSync` asks whether an expected activity name exists in `DeviceActivityCenter.activities`. It neither compares interval configuration nor checks execution. It ignores `needsAppSelection`. | “Out of sync” overstates the check and conflates missing registration with deliberately pending local setup. |
| `Foqos/Components/BlockedProfileCards/ProfileScheduleRow.swift:98` | The missing-activity flag replaces the schedule details with “Schedule Out of Sync.” | A synced profile can show this warning alongside “Select apps on this device.” |
| `Foqos/Views/BlockedProfileView.swift:303` | `ScheduleWarningPrompt(onApply: { saveProfile() }, disabled: isBlocking)` checks only active blocking. The normal Save control at line 711 is gated by `editingDisabled`. | Fix Schedule can invoke saving while the normal Save control is hidden. |
| `Foqos/Views/BlockedProfileView.swift:1058` | `saveProfile()` checks loaded trigger configuration and content validation, but not `editingDisabled`. The name and app picker remain editable draft controls under the lock. `updateProfile` saves those values. | In Child mode, a managed profile with an active lock and no temporary unlock can persist changed name and selection through Fix Schedule. Validation does not prevent this when the selection is valid. |
| `Foqos/Utils/PreActivationReminderScheduler.swift:40` | Eligibility means active V2 or legacy start schedule and `!needsAppSelection`. Reconciliation visits only eligible profiles. | Missing stop-only registrations are not repaired. Removed schedules and newly ineligible profiles are skipped instead of having stale registrations removed. |
| `Foqos/Utils/DeviceActivityCenterUtil.swift:7` | Direct registration lacks the selection gate, replaces the start activity, and catches registration failure at info level. Its stop helper logs errors but also returns no result. | A direct caller can register a start that automatic reconciliation deliberately skips. Callers cannot surface OS failures. |
| `Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift:51` | The extension refuses every scheduled start whose snapshot has `needsAppSelection == true`, before applying restrictions or creating a session. | An OS activity can exist while the profile remains unable to start; the missing-name warning then disappears misleadingly. |
| `Foqos/Views/BlockedProfileView.swift:966` and `Foqos/Models/BlockedProfiles.swift:514` | Domain-only or allow-mode content passes save validation, while an existing `needsAppSelection` flag clears only for local tokens or the two safety options. | Fix Schedule can successfully save and register a profile while preserving the exact flag that causes the extension to refuse its start. This does not require OS registration to fail. |
| `Foqos/Components/Sync/AppSelectionPrompt.swift:4` and `Foqos/Views/HomeView.swift:230` | The selection banner opens the normal profile editor; it has no separate persistence path. | Keep this navigation and the existing lock-code flow. |

The normal save sequence is `updateProfile` or `createProfile`, `finalizeSave`, trigger snapshot refresh, registration, sync enqueue, and dismissal. `finalizeSave` also logs a trigger-save error and continues. Registration errors must not reuse that pattern.

A completed sync fetch runs the reconciler after failed applies have been retried (`SyncEngineController.swift:945`). App foreground refresh merges schedule suppression, repairs missing snapshots, reconciles registrations, and performs missed-start catch-up (`FoqosApp.swift:424`). Catch-up calls the same shared start implementation as the monitor extension, including its selection gate.

The remaining direct callers are editor duplication (`BlockedProfileView.swift:785`), session restoration and activation (`StrategyManager.swift:141,898`, stop helper only), and deferred migration after a session ends (`StrategyManager.swift:955`). All need the same policy and failure contract. Registration after deferred migration must see the refreshed snapshot before an OS callback can fire.

## Required behavior

### One registration policy

Keep the policy beside the existing registration utility or model; expose the small computed decision needed by its callers. Do not introduce a service hierarchy or duplicate these conditions in three places.

Use these definitions:

- A configured V2 start means `startTriggers.schedule && startSchedule?.isActive == true`.
- A configured legacy start means `schedule?.isActive == true`; retain the existing V2-first interval selection and legacy fallback.
- A configured stop means `stopConditions.schedule && stopSchedule?.isActive == true`.
- A required start registration means a configured start and `!needsAppSelection`.
- A required independent stop registration means a configured stop without a required V2 start registration. An active legacy start does not replace the independent V2 stop activity: the existing stop registrar already supports both.

This yields the following registration requirements:

| Profile configuration | Required start activity | Required independent stop activity | Selection warning |
| --- | --- | --- | --- |
| No schedules | No | No | Only if `needsAppSelection` |
| V2 start, selection confirmed | Yes | No; a configured stop uses the start activity's interval end | No |
| V2 start, selection pending, no stop | No | No | Yes |
| V2 start and stop, selection pending | No | Yes; registration does not start a session | Yes |
| V2 stop only | No | Yes, independent of selection readiness | If selection is pending |
| Legacy start, selection confirmed | Yes | Only when a separate V2 stop is configured | No |
| Legacy start, selection pending | No | Only when a separate V2 stop is configured | Yes |

Do not gate a stop registration on local app selection. A stop callback does not start restrictions, and an already active session must retain its configured stop when selection becomes pending. This state is reachable: `SyncEngineController.clearAllLocalProfileSelections` at line 293 clears selection and sets the flag on every profile during sync reset, including a profile with an active session. Keep the shared extension's policy checks as the final authority for whether a particular callback may act.

The warning is true only if a required activity name is missing. Both the model property and registration code consume the same decision. Rename visible copy, not every internal identifier: `scheduleIsOutOfSync` and the existing card data plumbing can remain with a precise comment. Retain screenshot-demo suppression and newer-schema read-only presentation.

Reconciliation visits valid supported profiles even when they have no required start. For each profile, register required activities and remove only its obsolete start and stop activity names. Preserve the registrar's existing cancellation of pre-activation reminders before registration. This repairs stop-only profiles and cleans up disabled schedules without touching break, strategy, one-more-minute, or deadline-backstop activities. Do not add a global orphan-activity sweep.

Keep the existing re-registration timing and interval construction. Do not optimize by checking activity names alone: a synced time change can keep the same name. Preserve reminder rescheduling for successfully registered starts. Selection-pending profiles must not acquire start activities or start reminders through save, clone, reconciliation, or migration.

### Remove the alternate save path

Remove **Fix Schedule**, its callback parameter, and its call to `saveProfile()`. Keep `ScheduleWarningPrompt` as a passive warning, or inline its remaining text if the component no longer helps. It must have no write or registration side effect.

Add `guard !editingDisabled else { return }` at the beginning of `saveProfile()`, before validation or mutation. Reuse the existing edit decision, including the loaded-configuration check, active-session check, Child-mode managed lock, and temporary unlock. Do not change `ProfileEditGate` semantics or lock-code availability policy under this issue.

This guard protects the persistence entry point if the lock or session state changes after the toolbar was rendered. It also ensures that subsequent view changes cannot accidentally recreate this bypass. Authorized editing and unlocked-profile creation continue through the normal Save control.

The **Select apps on this device** card banner keeps opening the editor. When `needsAppSelection` is true, the editor shows the same instruction near the app selector. Saving the selection still requires the normal edit authorization. Do not introduce a special selection save or bypass the lock to configure a synced profile.

Preserve the selection-confirmation rules, including the safety-only exceptions. Domain-only saves that leave `needsAppSelection` true may remain saved, but must keep the selection instruction and must not register a start. Redefining local confirmation for domain or allow-mode profiles is outside this fix.

### Describe the condition accurately

Use **Schedule not registered on this device** on the home card and in the editor when a required activity is absent. The editor explanation is: “A required schedule is not registered. The app retries when you return to it.”

The missing-activity check is a recoverable device-local condition. It does not assert a CloudKit problem, compare all OS interval settings, or prove that a future callback will execute. If selection is the only missing prerequisite, show only the selection instruction. If a required independent stop also fails, both instructions are justified.

Keep the existing notification-based refresh: `DeviceActivityCenter.activities` is not a SwiftData-observed property. Emit the refresh after every registration attempt or cleanup, including failure. Refresh the card and editor after those events and when their profile inputs change. Do not leave a cached false value for a profile whose required registration has changed. Preserve `ScheduleOutOfSyncCardState.refresh` rebuilding its dictionary from the current profiles, which already prunes deleted IDs. Avoid adding a polling timer or another persistent status cache.

### Return and surface OS failures

Change both registration functions to return `[String]`: one descriptive message per failed operation, preserving the OS description and distinguishing start from stop. Callers join messages with a newline. Log each failed registration at error level. Attempt independent required operations even if one fails, and continue reconciliation with later profiles. Never interpret a failed fetch of profiles as successful reconciliation.

Use the existing error presentation at each call site:

| Caller | Required outcome after OS failure |
| --- | --- |
| Normal profile save | Keep the persisted profile. Present “Profile saved, but its schedule could not be registered: …” through the editor alert. Acknowledging the alert dismisses the editor. |
| Duplicate profile | Keep the created clone and surface “Profile created, but its schedule could not be registered: …” in the existing non-dismissing `.error` alert. Keep the source editor open; do not use the save-completion alert or invite a retry of cloning. |
| Session restoration or activation | Keep the active session and restrictions. Set `StrategyManager.errorMessage` after the registration call; activation clears it at line 892 before registering at line 898. Continue session activation bookkeeping and sync. |
| Deferred migration | Refresh the snapshot before registering. Keep the completed migration; surface registration failure through the existing strategy error channel. |
| Automatic reconciliation | Log the concrete OS error, continue other profiles, and refresh the passive missing-registration warnings. No repeating modal alert on every foreground or sync fetch. |

Registration failure must not skip sync enqueue for a successfully saved profile or clone. Preserve the existing `notAttached` deferral. If both enqueue and registration fail, retain both messages rather than overwriting one. Report the saved-versus-registered distinction honestly even when the sync error is also shown. Session restoration may show a stop-registration failure on each launch while an active session remains affected; this deliberate warning is separate from passive reconciliation.

Add one `AlertIdentifier.AlertType` case for a save completed with warnings. Its OK action calls `dismiss()`. The save action dismisses immediately only when no warning is pending. Use that modal alert for registration failure, sync-enqueue failure, or both. This also fixes the existing swallowed sync-enqueue alert: `finalizeSave` sets it, then `saveProfile` unconditionally dismisses at line 1166. No presenting-view callback is needed. While the alert is visible, the creation form cannot be resubmitted; acknowledgment closes it instead of leaving a creation form with `profile == nil`.

As part of touching `finalizeSave`, stop after a failed trigger `context.save()`: call `modelContext.rollback()`, refresh `BlockedProfiles.updateSnapshot(for:)` from the restored profile, and skip registration and sync enqueue. The profile-field save already succeeded; only the trigger edits remain pending at this point. Present “Profile saved, but its triggers could not be saved: …” using the same alert whose OK action dismisses the editor. Retry means reopening the saved profile. Do not add state to retry a creation form, move snapshot ownership, or introduce a transaction layer.

## Minimal implementation boundary

The expected production edits are `BlockedProfiles.swift`, `DeviceActivityCenterUtil.swift`, `PreActivationReminderScheduler.swift`, `BlockedProfileView.swift`, `ScheduleWarningPrompt.swift`, `ProfileScheduleRow.swift`, and the direct registration call sites in `StrategyManager.swift`. `ScheduleOutOfSyncBannerState.swift` and `BlockedProfileCarousel.swift` need only the refresh corrections that their existing cache requires. The four production `BlockedProfileView` constructors in `HomeView` and `BlockedProfileListView` need no changes.

Keep `TriggerConfigurationModel.saveToProfile` and its snapshot behavior; the failure branch repairs the snapshot after rollback. Do not change the sync engine, shared start/stop policy, or schedule schema unless review identifies a concrete dependency that this specification missed. `FoqosApp` and `SyncEngineController` already invoke reconciliation at the required times.

Use one implementation stream for the coupled policy, registrar, and UI contract. Splitting these files between simultaneous builders would require an unnecessary interim interface. Submit one coherent implementation PR with independent review; only the orchestrator can merge after the human approves that specific PR.

## Acceptance checks

Extend the existing tests instead of adding a parallel framework. Put the required-activity decision in one pure function on the profile, tested directly. Give the registrar two defaulted closure parameters: a throwing operation that starts a named activity with a schedule, and an operation that stops a list of activity names. Pass those closures through its stop helper. This follows the existing reconciliation `register:` seam and `BlockedProfiles.DeleteCleanup`; no protocol is needed. Inject activity inventory for the missing-registration check. Pin time once per test and use isolated SharedData defaults.

1. Cover the policy table in `PreActivationReminderSchedulerTests` or a focused registration test file. For every row, assert exact start and stop activity names attempted and removed. Include legacy plus V2 stop, disabled schedule cleanup, and a selection-pending V2 profile with a configured stop.
2. Supply missing and present activity inventories. Assert the model warning and card/editor state agree with those same requirements. A selection-pending start-only profile never shows the schedule warning; a missing required stop does. Preserve `ScreenshotDemoScheduleTests`.
3. Inject a thrown OS start-registration error and a stop-registration error. Verify returned messages, continued independent operations and later profiles, and refresh notification after failure. A later successful attempt clears the warning. Verify error-level logging by diff review: the logger has no capture seam, and this task does not add one.
4. Review the persistence entry point: `guard !editingDisabled else { return }` is the first statement of `saveProfile()`, and the warning component has no callback parameter. Keep `ProfileEditGateTests` covering Child lock, temporary unlock, Parent, Individual, and active-session decisions. The private SwiftUI save method has no direct test interface; do not add a view-testing dependency or a duplicate gate to test it.
5. When a managed Child profile with an active lock is available, perform a focused UI walkthrough with no temporary unlock. Confirm Fix Schedule is absent, the normal Save remains hidden, and changed drafts cannot be persisted from the warning. Confirm the selection banner still opens the authorized editor flow and the two warning conditions have distinct instructions. If the required family CloudKit setup is unavailable, report the walkthrough as not run and complete check 4's diff review; do not add test infrastructure or block the implementation on creating family setup.
6. Review and walk through the local save failure branches: registration and sync-enqueue warnings share the modal alert, both messages survive, and acknowledgment closes the editor without creating another profile. Review trigger-save failure for rollback before snapshot repair, no registration or enqueue, and the partial-save warning. Reopen the saved profile to retry. Do not claim these private view branches have automated coverage from utility tests.
7. Keep `ProfileAppSelectionStateTests`, `BlockedProfileSaveValidationTests`, and `ProfileSafetyOptionsTests` passing. Add the domain-only, selection-pending registration regression without changing the confirmation policy. Keep the shared scheduled-start refusal test in `ScheduleTimerActivityTests`.
8. Review session stop-registration failure for retained session state, error assignment after activation clears old errors, and uninterrupted activation bookkeeping. Verify deferred migration refreshes the snapshot before registration. Keep `StrategyManagerReconcileTests` and the existing snapshot tests passing.
9. Review the implementation diff for scope and run the normal gated build plus the changed test classes through the assigned build stream's `scripts/xcode-stream.sh` ownership. Do not run Xcode for this documentation-only PR.

## Alternatives considered

Deleting every warning is shorter but hides real registration failures, including stop-only schedules. Keeping Fix Schedule and adding the edit gate prevents the immediate bypass but preserves a misleading full-save action and the conflicting registration policy. A dedicated retry button could safely register persisted values without saving drafts, but the existing automatic retries cover that need; adding another control is unnecessary for this fix.

The selected design deletes the unsafe action, retains a narrowly truthful failure signal, and fixes the common registration boundary. It preserves device-local selection confirmation and extension enforcement.
