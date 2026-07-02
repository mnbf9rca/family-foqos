# Defect Audit Handovers (2026-07-02)

One handover per GitHub issue from the 2026-07-02 multi-agent defect audit
(12 domain finders, adversarial verification, dedupe). Each doc is self-contained:
an implementing agent should read the doc, re-verify the defect against current
code, then fix it following AGENTS.md.

**Sequencing:** see [REMEDIATION-PLAN.md](REMEDIATION-PLAN.md) (21 PR bundles, 5 waves) and tracking epic [#263](https://github.com/mnbf9rca/family-foqos/issues/263).

## Critical (5)

- [#195](https://github.com/mnbf9rca/family-foqos/issues/195) — [Reset Sync race lets deletion reconciliation wipe all local profiles on other devices](issue-195-reset-sync-race-lets-deletion-reconciliation-wip.md)
- [#197](https://github.com/mnbf9rca/family-foqos/issues/197) — [Lock-code enforcement fails open when shared codes cannot be fetched (offline/CloudKit error)](issue-197-lock-code-enforcement-fails-open-when-shared-cod.md)
- [#198](https://github.com/mnbf9rca/family-foqos/issues/198) — [Profile save writes app-group snapshot before trigger/schedule edits are applied, so scheduled blocking never starts in the background](issue-198-profile-save-writes-app-group-snapshot-before-tr.md)
- [#199](https://github.com/mnbf9rca/family-foqos/issues/199) — [Child mode can edit locked SavedLocations without a lock code, defeating geofence restrictions](issue-199-child-mode-can-edit-locked-savedlocations-withou.md)
- [#260](https://github.com/mnbf9rca/family-foqos/issues/260) — [Ending a break early never re-applies restrictions in-process; session left unblocked in permanent 'break' state](issue-260-ending-a-break-early-never-re-applies-restrictio.md) **(disputed — verify first)**

## High (20)

- [#200](https://github.com/mnbf9rca/family-foqos/issues/200) — [5-minute notification throttle silently drops remote session start/stop — other devices stay blocked/unblocked indefinitely](issue-200-5-minute-notification-throttle-silently-drops-re.md)
- [#201](https://github.com/mnbf9rca/family-foqos/issues/201) — [Failed CloudKit pushes (profile save/delete, session stop) are logged and dropped with no retry — silent divergence and stuck blocking](issue-201-failed-cloudkit-pushes-profile-save-delete-sessi.md)
- [#202](https://github.com/mnbf9rca/family-foqos/issues/202) — [SyncResetRequest is consumed by the first device that sees it and never cleaned up by the origin — missed resets and stale resets that wipe app selections](issue-202-syncresetrequest-is-consumed-by-the-first-device.md)
- [#203](https://github.com/mnbf9rca/family-foqos/issues/203) — [Remote deletion of an actively-blocking profile never deactivates ManagedSettings restrictions and leaves StrategyManager holding a zombie session](issue-203-remote-deletion-of-an-actively-blocking-profile.md)
- [#204](https://github.com/mnbf9rca/family-foqos/issues/204) — [startRemoteSession bypasses activateSession: no elapsed timer, no Live Activity, no stop-schedule registration, no widget reload](issue-204-startremotesession-bypasses-activatesession-no-e.md)
- [#205](https://github.com/mnbf9rca/family-foqos/issues/205) — [One-more-minute expiry re-activates restrictions in the middle of an active break](issue-205-one-more-minute-expiry-re-activates-restrictions.md)
- [#206](https://github.com/mnbf9rca/family-foqos/issues/206) — [ScheduleTimerActivity.stop ends sessions with no day-of-week, stop-condition, or session-origin check](issue-206-scheduletimeractivity-stop-ends-sessions-with-no.md)
- [#207](https://github.com/mnbf9rca/family-foqos/issues/207) — [One More Minute registers a 60-second DeviceActivity interval — always below the 15-minute minimum, so the feature always aborts](issue-207-one-more-minute-registers-a-60-second-deviceacti.md)
- [#208](https://github.com/mnbf9rca/family-foqos/issues/208) — [Two divergent lock-code caches: child rejects a newly changed PIN and keeps accepting the old one until app relaunch](issue-208-two-divergent-lock-code-caches-child-rejects-a-n.md)
- [#209](https://github.com/mnbf9rca/family-foqos/issues/209) — [Duplicated (cloned) profile never gets a SharedData snapshot, so its schedule fires into a nil profile and does nothing](issue-209-duplicated-cloned-profile-never-gets-a-shareddat.md)
- [#210](https://github.com/mnbf9rca/family-foqos/issues/210) — [Swipe-delete in profile list never deletes the profile from CloudKit, so sync resurrects it](issue-210-swipe-delete-in-profile-list-never-deletes-the-p.md)
- [#211](https://github.com/mnbf9rca/family-foqos/issues/211) — [Trigger selectors use lock check without child-mode guard, permanently disabling start/stop trigger editing for Parent (and Individual) mode](issue-211-trigger-selectors-use-lock-check-without-child-m.md)
- [#212](https://github.com/mnbf9rca/family-foqos/issues/212) — [Timer duration snap-to-preset can select 1440 minutes, producing a zero-length DeviceActivity interval so the timed session never auto-stops](issue-212-timer-duration-snap-to-preset-can-select-1440-mi.md)
- [#213](https://github.com/mnbf9rca/family-foqos/issues/213) — [ProfileInsightsUtil reads profile.sessions with no zombie-model filtering — crash if the profile is deleted (e.g. via sync) while the insights sheet is open](issue-213-profileinsightsutil-reads-profile-sessions-with.md)
- [#214](https://github.com/mnbf9rca/family-foqos/issues/214) — [5- and 10-minute break durations schedule DeviceActivity intervals below the 15-minute minimum, so breaks never start](issue-214-5-and-10-minute-break-durations-schedule-devicea.md)
- [#215](https://github.com/mnbf9rca/family-foqos/issues/215) — [Geofence rules referencing deleted locations become permanently unsatisfiable — active profile can never be stopped](issue-215-geofence-rules-referencing-deleted-locations-bec.md)
- [#216](https://github.com/mnbf9rca/family-foqos/issues/216) — [Remote location deletion via sync leaves dangling geofence references in profiles (local delete cleanup is never replicated)](issue-216-remote-location-deletion-via-sync-leaves-danglin.md)
- [#217](https://github.com/mnbf9rca/family-foqos/issues/217) — [App-group key migration clobbers newer values written by extensions before first app launch](issue-217-app-group-key-migration-clobbers-newer-values-wr.md)
- [#261](https://github.com/mnbf9rca/family-foqos/issues/261) — [StopProfileIntent (Siri/Shortcuts) bypasses the profile's configured stop conditions](issue-261-stopprofileintent-siri-shortcuts-bypasses-the-pr.md) **(disputed — verify first)**

## Medium (23)

- [#218](https://github.com/mnbf9rca/family-foqos/issues/218) — [Profile version-counter conflict resolution: ties diverge permanently and stale devices clobber newer cloud data](issue-218-profile-version-counter-conflict-resolution-ties.md)
- [#219](https://github.com/mnbf9rca/family-foqos/issues/219) — [CKQuery-based pull + reconciliation can delete a just-created profile due to query index lag](issue-219-ckquery-based-pull-reconciliation-can-delete-a-j.md)
- [#220](https://github.com/mnbf9rca/family-foqos/issues/220) — [Location sync ping-pongs forever: every pull bumps updatedAt, every sync re-pushes, retriggering the other device](issue-220-location-sync-ping-pongs-forever-every-pull-bump.md)
- [#221](https://github.com/mnbf9rca/family-foqos/issues/221) — [Emergency-unblock counter uses last-write-wins with swallowed serverRecordChanged — concurrent use loses decrements, granting extra unblocks](issue-221-emergency-unblock-counter-uses-last-write-wins-w.md)
- [#222](https://github.com/mnbf9rca/family-foqos/issues/222) — [sendCommand fails with serverRecordChanged when a command with the same deterministic recordName is still pending](issue-222-sendcommand-fails-with-serverrecordchanged-when.md)
- [#223](https://github.com/mnbf9rca/family-foqos/issues/223) — [Cloning an unmigrated V1 profile stamps the clone as schema V2 with all-false triggers, producing a profile that can never start](issue-223-cloning-an-unmigrated-v1-profile-stamps-the-clon.md)
- [#224](https://github.com/mnbf9rca/family-foqos/issues/224) — [No active-session guard on startWithTag/startBlocking allows double-start: zombie active session or silently lost scheduled session](issue-224-no-active-session-guard-on-startwithtag-startblo.md)
- [#225](https://github.com/mnbf9rca/family-foqos/issues/225) — [Shortcut/deep-link/scan starts skip the needsAppSelection check, creating an 'active' session that blocks nothing](issue-225-shortcut-deep-link-scan-starts-skip-the-needsapp.md)
- [#226](https://github.com/mnbf9rca/family-foqos/issues/226) — [Scheduled-session CAS reconciliation overwrites startTime of whichever session is active, without verifying profile identity](issue-226-scheduled-session-cas-reconciliation-overwrites.md)
- [#227](https://github.com/mnbf9rca/family-foqos/issues/227) — [activateSession/stopBreak wipe ALL pending notifications, killing other profiles' pre-activation reminders until next app foreground](issue-227-activatesession-stopbreak-wipe-all-pending-notif.md)
- [#228](https://github.com/mnbf9rca/family-foqos/issues/228) — [V2 schedule windows shorter than 15 minutes (including stop-only schedules before 00:15) fail DeviceActivity registration silently](issue-228-v2-schedule-windows-shorter-than-15-minutes-incl.md)
- [#229](https://github.com/mnbf9rca/family-foqos/issues/229) — [Legacy-schedule profiles restart a manually stopped session when the app is foregrounded (no lastStoppedAt suppression on the legacy path)](issue-229-legacy-schedule-profiles-restart-a-manually-stop.md)
- [#230](https://github.com/mnbf9rca/family-foqos/issues/230) — [Parent commands (Reset PIN Attempts / Reset Emergency Count) are only processed at child app launch](issue-230-parent-commands-reset-pin-attempts-reset-emergen.md)
- [#231](https://github.com/mnbf9rca/family-foqos/issues/231) — [ModeSelectionView commits the mode after a fixed 1-second wait, racing the FamilyControls authorization prompt](issue-231-modeselectionview-commits-the-mode-after-a-fixed.md)
- [#232](https://github.com/mnbf9rca/family-foqos/issues/232) — [Parent receives a duplicate 'Screen Time Permissions Lost' notification on every heartbeat refresh](issue-232-parent-receives-a-duplicate-screen-time-permissi.md)
- [#233](https://github.com/mnbf9rca/family-foqos/issues/233) — [Profile reorder is never pushed to sync, so remote updates revert the user's ordering](issue-233-profile-reorder-is-never-pushed-to-sync-so-remot.md)
- [#234](https://github.com/mnbf9rca/family-foqos/issues/234) — [Reminder-time field feeds unchecked Int into UInt32(), crashing on large or negative input at save](issue-234-reminder-time-field-feeds-unchecked-int-into-uin.md)
- [#235](https://github.com/mnbf9rca/family-foqos/issues/235) — [BlockedSessionsHabitTracker caches selected sessions in @State and later dereferences session.blockedProfile — zombie crash after deletion](issue-235-blockedsessionshabittracker-caches-selected-sess.md)
- [#236](https://github.com/mnbf9rca/family-foqos/issues/236) — [Scheduled start in the monitor extension force-ends any other active session, ignoring disableBackgroundStops and stop conditions](issue-236-scheduled-start-in-the-monitor-extension-force-e.md)
- [#237](https://github.com/mnbf9rca/family-foqos/issues/237) — [Session mutators write to SharedData's active session without identity checks, clobbering extension-created sessions](issue-237-session-mutators-write-to-shareddata-s-active-se.md)
- [#238](https://github.com/mnbf9rca/family-foqos/issues/238) — [Monitor extension never reloads widget timelines, so the home-screen widget shows stale session state after scheduled starts/stops](issue-238-monitor-extension-never-reloads-widget-timelines.md)
- [#239](https://github.com/mnbf9rca/family-foqos/issues/239) — [Deviation #17 still present: disableBackgroundStops ignored by schedule-based stops (StopScheduleTimerActivity)](issue-239-deviation-17-still-present-disablebackgroundstop.md)
- [#240](https://github.com/mnbf9rca/family-foqos/issues/240) — [TODO in FamilyLockCode acknowledges brute-forceable PIN hash that syncs to child-readable CloudKit DB](issue-240-todo-in-familylockcode-acknowledges-brute-forcea.md)

## Low (20)

- [#196](https://github.com/mnbf9rca/family-foqos/issues/196) — [ChildDashboardView footer wrongly says the lock code is required to STOP a locked profile (copy fix; decided 2026-07-02)](issue-196-design-conflict-stopping-a-locked-managed-profil.md)
- [#241](https://github.com/mnbf9rca/family-foqos/issues/241) — [syncShareParticipantsToFamilyMembers deletes a child's FamilyMember record when the participant's userRecordID is unresolved](issue-241-syncshareparticipantstofamilymembers-deletes-a-c.md)
- [#242](https://github.com/mnbf9rca/family-foqos/issues/242) — [Emergency unblock schedules the post-session reminder twice, producing duplicate notifications](issue-242-emergency-unblock-schedules-the-post-session-rem.md)
- [#243](https://github.com/mnbf9rca/family-foqos/issues/243) — [scheduleLastStoppedAt written by the monitor extension is never imported back into SwiftData and is clobbered by app-side snapshot writes](issue-243-schedulelaststoppedat-written-by-the-monitor-ext.md)
- [#244](https://github.com/mnbf9rca/family-foqos/issues/244) — [Setting a lock code in Individual mode claims to make the device a parent device but never switches the mode](issue-244-setting-a-lock-code-in-individual-mode-claims-to.md)
- [#245](https://github.com/mnbf9rca/family-foqos/issues/245) — [deleteProfile leaves pending pre-activation reminder notifications and the stop-only DeviceActivity registered](issue-245-deleteprofile-leaves-pending-pre-activation-remi.md)
- [#246](https://github.com/mnbf9rca/family-foqos/issues/246) — [Carousel resets scroll position to the first card whenever the profiles array changes](issue-246-carousel-resets-scroll-position-to-the-first-car.md)
- [#247](https://github.com/mnbf9rca/family-foqos/issues/247) — [Debug Mode (reachable in Child mode without lock code) displays and copies the physical-unblock NFC tag UID](issue-247-debug-mode-reachable-in-child-mode-without-lock.md)
- [#248](https://github.com/mnbf9rca/family-foqos/issues/248) — [DebugView and DeviceActivitiesDebugCard each fail to recognize one real activity type, reporting 'Unknown' / 'Matches Profile: No' for live activities](issue-248-debugview-and-deviceactivitiesdebugcard-each-fai.md)
- [#249](https://github.com/mnbf9rca/family-foqos/issues/249) — [Live Activity shows the previous profile's name after a session switch because attributes are never recreated](issue-249-live-activity-shows-the-previous-profile-s-name.md)
- [#250](https://github.com/mnbf9rca/family-foqos/issues/250) — [Extension processes write Log files to their own sandbox containers, so 'Export Logs' never includes extension logs](issue-250-extension-processes-write-log-files-to-their-own.md)
- [#251](https://github.com/mnbf9rca/family-foqos/issues/251) — [Location Restrictions selector is not disabled for locked managed profiles, unlike all other trigger selectors](issue-251-location-restrictions-selector-is-not-disabled-f.md)
- [#252](https://github.com/mnbf9rca/family-foqos/issues/252) — [Personal identifiers (real names and email addresses of family-share participants) written to exportable logs](issue-252-personal-identifiers-real-names-and-email-addres.md)
- [#253](https://github.com/mnbf9rca/family-foqos/issues/253) — [README documents wrong minimum OS/toolchain: says iOS 17.6+/Xcode 15/Swift 5.9 but project requires iOS 18.6/Swift 6.0](issue-253-readme-documents-wrong-minimum-os-toolchain-says.md)
- [#254](https://github.com/mnbf9rca/family-foqos/issues/254) — [README 'Blocking Strategies' section documents the removed V1 strategy-selection system as current behavior](issue-254-readme-blocking-strategies-section-documents-the.md)
- [#255](https://github.com/mnbf9rca/family-foqos/issues/255) — [ChildAuthorizationRequiredView (and SetupStepRow) is dead code — the Family Sharing setup guidance is never shown](issue-255-childauthorizationrequiredview-and-setupsteprow.md)
- [#256](https://github.com/mnbf9rca/family-foqos/issues/256) — [AppSelectionPrompt sheet, AppSelectionPromptModifier and .appSelectionPrompt() extension are dead — superseded by opening the profile editor](issue-256-appselectionprompt-sheet-appselectionpromptmodif.md)
- [#257](https://github.com/mnbf9rca/family-foqos/issues/257) — [AddFamilyMemberView and EnrollFamilyMemberButton are dead duplicate enrollment UIs](issue-257-addfamilymemberview-and-enrollfamilymemberbutton.md)
- [#258](https://github.com/mnbf9rca/family-foqos/issues/258) — [FoqosUITests target has zero source files and no source directory, yet is a parallelizable target in FamilyFoqos.xctestplan](issue-258-foqosuitests-target-has-zero-source-files-and-no.md)
- [#259](https://github.com/mnbf9rca/family-foqos/issues/259) — [Orphaned meaningless 'Supported' key in main app Info.plist — debris from ITSAppUsesNonExemptEncryption removal](issue-259-orphaned-meaningless-supported-key-in-main-app-i.md)