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
| `Foqos/Views/BlockedProfileView.swift:668,782` and `Foqos/Models/BlockedProfiles.swift:739` | Duplicate is available whenever `!isBlocking`; neither the menu action nor clone confirmation checks the lock. `cloneProfile` copies `isManaged` and `managedByChildId`, saves the clone, and its caller registers it. Delete at line 687 checks the Child lock before continuing. | Duplication is another editor mutation that lacks the lock check. Apply Delete's authorization check before duplicating a locked profile. |
| `Foqos/Utils/PreActivationReminderScheduler.swift:40` | Eligibility means active V2 or legacy start schedule and `!needsAppSelection`. Reconciliation visits only eligible profiles. | Missing stop-only registrations are not repaired. Removed schedules and newly ineligible profiles are skipped instead of having stale registrations removed. |
| `Foqos/Utils/DeviceActivityCenterUtil.swift:7` | Direct registration lacks the selection gate, replaces the start activity, and catches registration failure at info level. Its stop helper logs errors but also returns no result. | A direct caller can register a start that automatic reconciliation deliberately skips. Callers cannot surface OS failures. |
| `Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift:51` | The extension refuses every scheduled start whose snapshot has `needsAppSelection == true`, before applying restrictions or creating a session. | An OS activity can exist while the profile remains unable to start; the missing-name warning then disappears misleadingly. |
| `Foqos/Views/BlockedProfileView.swift:966` and `Foqos/Models/BlockedProfiles.swift:514` | Domain-only or allow-mode content passes save validation, while an existing `needsAppSelection` flag clears only for local tokens or the two safety options. | Fix Schedule can successfully save and register a profile while preserving the exact flag that causes the extension to refuse its start. This does not require OS registration to fail. |
| `Foqos/Components/Sync/AppSelectionPrompt.swift:4` and `Foqos/Views/HomeView.swift:230` | The selection banner opens the normal profile editor; it has no separate persistence path. | Keep this navigation and the existing lock-code flow. |

The normal save sequence is `updateProfile` or `createProfile`, `finalizeSave`, trigger snapshot refresh, registration, sync enqueue, and dismissal.

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
- A required independent stop registration means a configured stop without a required V2 start registration. The existing stop registrar supports an active legacy start alongside an independent V2 stop; it does not yet support a selection-pending V2 start alongside that stop.

Change `scheduleStopActivity`'s guard explicitly: replace “configured stop and no configured V2 start” with “configured stop and no required V2 start registration.” A configured V2 start requires registration only when `!needsAppSelection`. This is a behavior change for a selection-pending V2 profile with a configured stop, not merely reuse of the existing legacy behavior.

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

Apply Delete's lock check to **Duplicate Profile**: `isManagedProfile && appModeManager.currentMode == .child && !isUnlockedForEditing`. When it holds, use the existing lock-code sheet with a `.duplicate` pending action; successful verification opens the clone-name prompt. Otherwise open that prompt directly. Re-check the same lock condition and `isBlocking` at clone confirmation before `cloneProfile` can mutate, save, or register anything, so an expired unlock or newly active session cannot bypass the menu check. If authorization has expired, request it again through the same pending action. Keep the copied management metadata and the existing behavior for Parent, Individual, and authorized Child editing.

The existing **Select apps on this device** card banner keeps opening the editor. Saving the selection still requires normal edit authorization. Add no editor instruction or selection banner, and no special selection save.

Preserve the selection-confirmation rules, including the safety-only exceptions. Domain-only saves that leave `needsAppSelection` true may remain saved, but must keep the existing card banner and must not register a start. Redefining local confirmation for domain or allow-mode profiles is outside this fix.

### Describe the condition accurately

Use **Schedule not registered on this device** on the home card and in the editor when a required activity is absent. The editor explanation is: “A required schedule is not registered. The app retries when you return to it.”

The missing-activity check is a recoverable device-local condition. It does not assert a CloudKit problem, compare all OS interval settings, or prove that a future callback will execute. If selection is the only missing prerequisite, retain the existing card selection banner and show no schedule warning in either view. If a required independent stop also fails, the card can show both warnings; the editor keeps its schedule warning.

Keep the existing notification-based refresh: `DeviceActivityCenter.activities` is not a SwiftData-observed property. Emit the refresh after every registration attempt or cleanup, including failure. Refresh the card and editor after those events and when their profile inputs change. Do not leave a cached false value for a profile whose required registration has changed. Preserve `ScheduleOutOfSyncCardState.refresh` rebuilding its dictionary from the current profiles, which already prunes deleted IDs. Avoid adding a polling timer or another persistent status cache.

### Return and surface OS failures

Change both registration functions to report failures to callers, preserving the OS description and distinguishing start from stop. The implementer can use `throws` or `[String]`; the required behavior is to preserve each operation's failure, attempt independent required operations even if one fails, and continue reconciliation with later profiles. Log each failed registration at error level. Never interpret a failed fetch of profiles as successful reconciliation.

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

## Minimal implementation boundary

The expected production edits are `BlockedProfiles.swift`, `DeviceActivityCenterUtil.swift`, `PreActivationReminderScheduler.swift`, `BlockedProfileView.swift`, `ScheduleWarningPrompt.swift`, `ProfileScheduleRow.swift`, and the direct registration call sites in `StrategyManager.swift`. `ScheduleOutOfSyncBannerState.swift` and `BlockedProfileCarousel.swift` need only the refresh corrections that their existing cache requires. The four production `BlockedProfileView` constructors in `HomeView` and `BlockedProfileListView` need no changes.

Keep `TriggerConfigurationModel.saveToProfile`, snapshot ownership, and trigger-persistence failure handling outside this change. Do not change the sync engine, shared start/stop policy, or schedule schema unless review identifies a concrete dependency that this specification missed. `FoqosApp` and `SyncEngineController` already invoke reconciliation at the required times.

Use one implementation stream for the coupled policy, registrar, and UI contract. Splitting these files between simultaneous builders would require an unnecessary interim interface. Submit one coherent implementation PR with independent review; only the orchestrator can merge after the human approves that specific PR.

## Acceptance checks

Extend the existing tests instead of adding a parallel framework. Start with one pure `requiredActivities(for:)` decision and the existing reconciliation `register:` seam, adapting that seam to the chosen failure contract. Test missing-registration decisions with supplied activity inventories. The implementer can add narrow defaulted start/stop operation closures if they provide useful effect tests; they are optional, and no protocol or registrar class is needed. Pin time once per test and use isolated SharedData defaults.

1. Cover the policy table in `PreActivationReminderSchedulerTests` or a focused registration test file. For every row, assert the exact required activity names. Use the reconciliation seam to verify that stop-only and newly ineligible profiles are visited for registration or cleanup. Include legacy plus V2 stop, disabled schedules, and a selection-pending V2 profile with a configured stop. Verify the registrar uses this decision for actual registration and removal by diff review, or by effect tests if the optional operation closures are added.
2. Supply missing and present activity inventories. Assert the model warning and card/editor state agree with those same requirements. A selection-pending start-only profile never shows the schedule warning; a missing required stop does. Preserve `ScreenshotDemoScheduleTests`.
3. Inject registration failures through the reconciliation seam. Verify later profiles are still visited and refresh notification follows failure. A later successful attempt clears the missing-registration warning. Verify the registrar preserves start and stop errors and attempts independent operations by diff review, or by effect tests through the optional closures. Verify error-level logging by diff review: the logger has no capture seam, and this task does not add one.
4. Review the persistence entry points: `guard !editingDisabled else { return }` is the first statement of `saveProfile()`, the warning component has no callback parameter, and Duplicate applies Delete's Child-lock condition at both menu activation and clone confirmation. Confirm cloning is refused if a session becomes active before confirmation. Keep `ProfileEditGateTests` covering Child lock, temporary unlock, Parent, Individual, and active-session decisions. The private SwiftUI actions have no direct test interface; do not add a view-testing dependency or a duplicate gate to test them.
5. When a managed Child profile with an active lock is available, perform a focused UI walkthrough with no temporary unlock. Confirm Fix Schedule is absent, normal Save remains hidden, and Duplicate requires verification before opening its name prompt. Cancel verification and confirm that no clone is created. After verification, confirm duplication succeeds and retains the management metadata. Confirm the existing card selection banner still opens the authorized editor flow, with no added editor instruction. If the required family CloudKit setup is unavailable, report the walkthrough as not run and complete check 4's diff review; do not add test infrastructure or block the implementation on creating family setup.
6. Review and walk through the local save failure branches: registration and sync-enqueue warnings share the modal alert, both messages survive, and acknowledgment closes the editor without creating another profile. Do not claim these private view branches have automated coverage from utility tests.
7. Keep `ProfileAppSelectionStateTests`, `BlockedProfileSaveValidationTests`, and `ProfileSafetyOptionsTests` passing. Add the domain-only, selection-pending registration regression without changing the confirmation policy. Keep the shared scheduled-start refusal test in `ScheduleTimerActivityTests`.
8. Review session stop-registration failure for retained session state, error assignment after activation clears old errors, and uninterrupted activation bookkeeping. Verify deferred migration refreshes the snapshot before registration. Keep `StrategyManagerReconcileTests` and the existing snapshot tests passing.
9. Review the implementation diff for scope and run the normal gated build plus the changed test classes through the assigned build stream's `scripts/xcode-stream.sh` ownership. Do not run Xcode for this documentation-only PR.

## Alternatives considered

Deleting every warning is shorter but hides real registration failures, including stop-only schedules. Keeping Fix Schedule and adding the edit gate prevents the immediate bypass but preserves a misleading full-save action and the conflicting registration policy. A dedicated retry button could safely register persisted values without saving drafts, but the existing automatic retries cover that need; adding another control is unnecessary for this fix.

The selected design deletes the unsafe action, retains a narrowly truthful failure signal, and fixes the common registration boundary. It preserves device-local selection confirmation and extension enforcement.
