# Family Foqos: V1 assumptions still shaping V2

bobbithy, the defect is broader than a missing Timer call. V2 stores independent start and stop selections, but several editor rules, execution paths, schedule adapters, status messages and tests still treat a start method as the provider of its matching stop method.

## Scope, authority and evidence

- Audited **`origin/main` at `0fa5f9d92caddde49ec3e8f9e3859a254bdb3d59`**, merge #500, dated 2026-10-02 11:18 BST. The ref was unchanged at the final check. Local `main` was not used as code evidence.
- All ordinary `file:line` references below refer to that commit. Historical commits and the unmerged planner branch are explicitly identified separately.
- Read-only audit: no repository files, branches, commits or PRs created or changed. An immutable `git archive` copy and a small diagnostic Swift program were written under `/private/tmp`.
- **Human rulings:** V1 predefined strategy pairs are gone; V2 start conditions and stop conditions are independent and freely combinable; every profile needs a stop condition; selecting Timer must actually start a timer. These supersede contrary historical specs.
- **Fact** means directly supported by source/history or the diagnostic execution. **Inference** means a derived user scenario, diagnosis of intent, or recommended product interpretation. No claim is made that physical NFC, iOS scheduling or device shielding was exercised. No Xcode/simulator run was needed for this read-only audit.

The findings are grouped by corrective boundary; a group lists all located production manifestations rather than reporting every duplicate rule as an unrelated bug.

## Findings

### F1 — Timer is a flag in V2, while duration selection and arming still belong to V1 strategies

**Severity: high. Fact.**

**Evidence:**

- `Foqos/Components/BlockedProfileView/StopConditionSelector.swift:28` exposes only a Timer toggle. Its bindings at lines 6–10 contain no duration.
- `Packages/FoqosShared/Sources/FoqosShared/ProfileStopConditions.swift:9` stores a Boolean timer; `:49` counts it as a valid stop condition. `Foqos/Models/TriggerConfigurationModel.swift:45` validates tags and schedules but no timer duration; `:137` saves triggers, tag IDs and schedules without timer configuration.
- `Foqos/Models/Strategies/NFCTimerBlockingStrategy.swift:29` and `QRTimerBlockingStrategy.swift:28` own the duration picker. They save `profile.strategyData`, create a session, then call the registrar at lines 54 and 53 respectively.
- The only production calls to `startStrategyTimerActivity` are those two V1 classes and `Foqos/Models/Strategies/ShortcutTimerBlockingStrategy.swift:42`. The registrar still obtains the saved duration from V1 `strategyData` at `Foqos/Utils/DeviceActivityCenterUtil.swift:270`.
- Ordinary manual start is forced to `ManualBlockingStrategy` at `Foqos/Utils/StrategyManager.swift:200` and `:1202`; that strategy creates the session without countdown setup at `Foqos/Models/Strategies/ManualBlockingStrategy.swift:24`.
- NFC/QR starts instead create sessions directly in `StrategyManager.swift:1311–1327`, also without countdown setup. Deep-link starts use the manual strategy at `:550` and `:567`. Shortcuts without an explicit invocation duration use it at `:646`.
- The app's common activation path at `StrategyManager.swift:880–915` registers a calendar stop only. Its `startTimer()` call is an elapsed-time UI tick, not `StrategyTimerActivity` registration.
- Scheduled starts and foreground catch-up run `Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift:123–134` and `SharedData.swift:550–575`, which create a fresh snapshot without a countdown. Foreground catch-up reaches that path through `Foqos/Utils/PreActivationReminderScheduler.swift:97–99`.

**User-visible effect:** Manual, NFC, QR, written-link and scheduled starts can have Timer selected but never expire by countdown. Migrated timer profiles can retain a displayed saved duration while their V2 starts never use it. Timer-only manual profiles can be saved and started, then the Stop button tells the user to wait for a nonexistent timer.

**Correction to the supplied premise:** It is not literally true that every V2 start calls `ManualBlockingStrategy`: tag starts and scheduled starts create sessions directly. Also PR #495's explicit Shortcuts Duration branch calls `ShortcutTimerBlockingStrategy` (`StrategyManager.swift:638–644`) and does arm a timer. The inert ordinary V2 Timer finding nevertheless holds across the traced local start routes.

**V1 origin:** V1 strategies owned both activation and countdown setup. `41ff702` (#30) introduced the V2 selectors and bypass/direct-create paths without moving this responsibility. Its commit message promised independent combinations. `5a29545` (merged in #495 via `63ba4a6`) improved timer deadline publication but kept arming attached to those strategy classes.

**V2-correct fix:** Make duration part of the configured Timer stop, available at save time so unattended scheduled starts can use it. Reuse the existing duration representation/control where suitable; move or expose the actual registration at a shared local-session start boundary reachable from the app and monitor extension. Arm exactly one session-owned countdown whenever Timer is enabled, regardless of start modality, and publish the actual registered deadline. An authorized invocation duration can remain a session-only override. Migration must preserve valid old durations and explicitly repair missing ones. A remote mirror must adopt the authoritative session/deadline rather than blindly start a second timer. This is stop-condition behavior, not selection of a replacement V1 pair. See F12 for failure and expiry safety.

### F2 — Changing a start condition hides or deletes stop conditions

**Severity: high. Fact.**

**Evidence:**

- `Foqos/Models/TriggerValidator.swift:27–43` requires an NFC start for Same NFC and a QR start for Same QR; its auto-fixes clear those stop flags. The rules are installed at `:60–64`; availability and explanations repeat the coupling at `:77–93`.
- `Foqos/Models/TriggerConfigurationModel.swift:28–33` invokes that stop mutation whenever start triggers change. The UI-facing availability wrappers repeat the same contract at `:103–110`.
- `Foqos/Models/TriggerPickerOptions.swift:65–69` and `:134–138` exclude Same from the stop picker without the corresponding start.
- `Foqos/Components/BlockedProfileView/StopConditionSelector.swift:34`, `:43–49`, `:59`, `:68–74` independently hide and clear those choices when start modality changes.

**User-visible effect:** Changing NFC start to manual or QR can erase the user's only stop condition. Selecting a stop is constrained by how the profile starts, rather than by independent stop configuration. The editor can also allow manual plus NFC start with Same NFC stop, which then fails when the manual alternative is actually used (F3).

**V1 origin:** All these dependency rules entered with `41ff702` (#30). They encode the old NFC→same-NFC and QR→same-QR strategy semantics inside the supposedly independent V2 model. This ancestry is a design inference supported by the exact rules and old strategies, not a claim about the author's intent.

**V2-correct fix:** Remove start-dependent availability, auto-clearing and validation from the V2 editor/model. Keep validation of the stop's own required data and the nonempty-stop invariant. Resolve Same's independent meaning coherently with F3; do not merely unhide a choice whose evaluator can never succeed.

### F3 — Same-tag stop remains defined exclusively by a matching start credential; the V1 exceptional path was dropped

**Severity: high. Fact.**

**Evidence:**

- `Foqos/Utils/StartStopActionResolver.swift:173–181` requires `sessionTag` to start with `nfc:` and equal the scan; `:200–209` does the corresponding QR check. No force-start/context fallback is an input to `canStop` at `:143–149`.
- V1 `Foqos/Models/Strategies/NFCBlockingStrategy.swift:59–68` first enforces an explicit physical unlock tag, then requires the original tag **only if `!session.forceStarted`**. QR has the same exception at `QRCodeBlockingStrategy.swift:75`.
- V2 manual/deep-link/ordinary Shortcut sessions use `ManualBlockingStrategy.id` as their tag (`ManualBlockingStrategy.swift:33–39`); scheduled sessions use the profile UUID (`Packages/FoqosShared/Sources/FoqosShared/SharedData.swift:569–575`). None can match `nfc:`/`qr:`.
- V2 tag stops route through the resolver at `StrategyManager.swift:1255–1272` and `:1286–1303`, so the old exceptions are not executed.
- Same-user remote adoption also loses the initiating scan: `StrategyManager.swift:1624–1631` creates the mirror with tag `remote-sync`; `Foqos/CloudKit/ProfileSessionRecord.swift:24–31` and `:50–62` carry timing/state but no start-tag credential. Merely transmitting a start timestamp cannot satisfy Same on the mirror.

**User-visible effect:** A valid editor configuration of manual + NFC starts / Same NFC stop can start manually but no tag can stop it. QR is symmetric. Scheduled, deep-link, opposite-modality and same-account mirrored sessions have the same problem where they reach this configuration. Setting `forceStarted = true` alone cannot fix V2 because V2 never reads it during stop validation.

**V1 origin:** The force-start exception predates V2 (present in the #30 parent and the old NFC implementation; physical-tag precedence dates to `2f92563`). `41ff702` added the V2 matcher without that exception; `9e08e61` (#158) extracted it into the resolver. Remote session adoption originated in the older CAS model (`d9812eb`, #7), which did not transport that credential.

**V2-correct fix:** A configured physical stop must have a usable meaning independent of start selection. Specific stop keys already provide the simplest independent primitive: match the configured stop key(s), not the start method. For retained Same choices, implement and explain behavior when there is no matching scan origin; do not reject the independent start or leave an impossible predicate. **Inference / semantic detail:** the smallest legacy-compatible interpretation is “same key when one was captured, otherwise any key of this modality,” preserving explicit stop-key restrictions. That fallback is supported by V1 precedent but is **not explicitly specified by the three human rulings**. An alternative is a migration/UI definition that makes the intended stop key explicit. This semantic detail must be stated in the replacement V2 conditions spec; restoring a blanket force-start bypass must not weaken specific-key restrictions. The confirmed finding does not depend on choosing either representation.

### F4 — `hasUsableStop` converts broken V2 behavior into a new start/stop pairing policy

**Severity: high. Fact; introduced recently rather than inherited unchanged.**

**Evidence:**

- `Foqos/Utils/StartStopActionResolver.swift:124–137` defines a start credential and makes Same NFC/QR depend on it. Timer is absent. Schedule counts only if background stops are allowed.
- Its sole production caller on audited main is `StrategyManager.swift:626–635`, for Shortcuts with credential `.none`. Explicit invocation duration bypasses this predicate.
- `FoqosTests/ShortcutsStatusTests.swift:23–42` requires timer-only rejection, matching credentials for Same, and schedule rejection under the background flag.
- `docs/superpowers/specs/2026-09-10-shortcuts-siri-design.md:72–76` explicitly specifies these rules **because ordinary V2 timers are not armed**, and says not to fix timer setup there. Its path audit at `:102` explicitly preserves nil countdowns for manual/tag/scheduled starts.

**User-visible effect:** The same saved V2 profile can start from the app and become stuck, but refuse from Siri with “Use a start method that provides the required stop.” A configured timer-only stop is treated as unavailable instead of being executed. This expands the old pairing model and hides F1/F3 behind apparently defensive validation.

**V1 origin:** `5a29545`, PR #495. Its lineage is conceptual: it codifies V1-style paired capabilities as a new V2 predicate. This is not an old helper accidentally left around.

**V2-correct fix:** Replace the credential-pair question with validation that the independent configured stops have their required data and can be established for a session. Timer must count once it is genuinely configured and armed. Do not spread this predicate unchanged to save, clone or other start routes. Empty stops must still be rejected; no implicit emergency stop or forced manual stop should be added to satisfy validation.

**Unmerged #493:** The separately inspected branch `planner/493-322-plans`, head `375bb95`, contains `docs/superpowers/specs/2026-10-02-493-profile-stop-validation-design.md`. At lines 10, 32–44 and 60–64 it requires reusing this predicate unchanged for every enabled start, including clone/save and actual-start backstops. At lines 88 and 98 it proposes tests/refusals for the unarmed Timer and treats arming it as a new product question. This is **not on `origin/main` and not a shipping defect**. It would institutionalize the rejected assumption and must be superseded, not used as audit authority.

### F5 — A broad background-stop veto overrides independently selected scheduled stops, while UI promises them

**Severity: high. Fact; intended scope of the old toggle is partly inferential.**

**Evidence:**

- `Packages/FoqosShared/Sources/FoqosShared/BackgroundStopPolicy.swift:43` returns denial before inspecting `.schedule` versus other channels.
- Both scheduled-stop implementations pass the flag: `Timers/ScheduleTimerActivity.swift:143–148` and `Timers/StopScheduleTimerActivity.swift:38–43`.
- `Foqos/Views/BlockedProfileView.swift:471–475` describes background stops by naming Shortcuts and NFC/QR links. It does not warn that enabling it neutralizes the Schedule stop selected above.
- `StartStopActionResolver.swift:104–110` promises a timer or scheduled stop using only flags. `hasUsableStop` at `:137` refuses the same scheduled exit under the flag; `Foqos/Intents/ShortcutStatus.swift:64` hides it. The editor's `TriggerConfigurationModel.validate` has no background-stop input.
- `FoqosTests/BackgroundStopPolicyTests.swift:89–96` explicitly asserts that scheduled stops are denied when the flag is on.

**User-visible effect:** A schedule-only profile can be saved and manually started; its Stop button says it stops at its scheduled time, but the callback refuses. Other channels disagree about whether it has an exit.

**V1 origin:** The V1 flag was checked in deep-link and Shortcut stop entry points in the parent of `41ff702`. Schedule callbacks did not check it there. `8c86df2` (#279) broadened the veto through a common background policy. The earlier audit handover `docs/handovers/issue-239-deviation-17-still-present-disablebackgroundstop.md:12–26` expressly asked for that broadening. Thus this is a V1 background concept expanded during V2 remediation, not evidence that V1 scheduled stops themselves had this rule.

**V2-correct fix:** Distinguish externally initiated background stop requests from the profile's own selected automatic stop conditions. Keep the intended Shortcut/link restriction while allowing configured scheduled expiry, and keep countdown expiry coherent with it. Align stop messaging and Shortcuts status with the actual established mechanisms. **Inference:** exemption of scheduled expiry is the correction consistent with independent automatic stops and the listed toggle examples; the existing sentence says “includes,” so its wording alone is not proof of exclusivity. If a broader veto is intentionally retained, it must be an explicit override with honest configuration/error UX, never a hidden no-exit state. It must not be justified by V1 pairings.

### F6 — Scheduled start and stop still share one paired OS interval, so stop days disappear and stop registration depends on start

**Severity: high. Fact.**

**Evidence:**

- `Foqos/Utils/DeviceActivityCenterUtil.swift:10–17` excludes the independent stop activity whenever a usable V2 start schedule exists.
- `:51–59` places start and stop clock times in one daily interval; `:75–79` sets it to repeat. Neither schedule's weekday list is encoded there.
- `:128–131` removes the independent stop activity in that situation. Even after failed start registration (`:93–100`), the same policy excludes the separate stop, despite the comment promising independence.
- The combined start callback checks start-window/day logic (`Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift:56–63`). Its stop callback at `:134–161` never checks `stopSchedule.days` or even `stopSchedule.isActive`; it asks only the Boolean schedule policy.
- The stop-only callback **does** check the stop day at `Timers/StopScheduleTimerActivity.swift:30–35`.

**User-visible effect:** Adding a scheduled start changes the meaning of an already configured scheduled stop. Example: Monday 09:00 start and Friday 17:00 stop are registered as a daily 09:00–17:00 interval; when the combined Monday end callback arrives, it ends the session although Monday is not a selected stop day. Manual-started sessions on non-stop days are also vulnerable once both schedules are enabled. Failure to register the combined activity also loses the independent stop route.

**V1 origin:** V1 used one `BlockedProfileSchedule` containing both endpoints. `41ff702` retained the combined activity and registered a separate stop only when there was no scheduled start. `8a6b8c1` later centralized that rule in `requiredActivities`, preserving the coupling.

**V2-correct fix:** Give each enabled start/stop schedule an independently owned registration/callback, with its own day/time check. Reuse the existing stop-only activity; do not make it contingent on start registration. Make the start activity's artificial end a no-op for V2. A combined optimization is acceptable only if provably equivalent for both independent recurrences; there is no need to add that optimization now. A stop event ends the matching active profile regardless of which modality started it.

### F7 — Paired-window arithmetic and validation reject or misinterpret valid independent schedules

**Severity: high for timing behavior; medium for editor refusal. Fact.**

**Evidence:**

- `Packages/FoqosShared/Sources/FoqosShared/ProfileScheduleTime.swift:101–134` constructs today's stop from its clock time and assumes a same-day/overnight pair. It never checks stop weekdays. `:154–158` checks only the inferred start weekday.
- Both foreground catch-up (`Foqos/Utils/PreActivationReminderScheduler.swift:87–99`) and the extension (`Timers/ScheduleTimerActivity.swift:56–63`) consume this paired model.
- `Foqos/Models/TriggerConfigurationModel.swift:66–86` rejects equal clock times and clock gaps below 15 minutes whenever both schedule flags are enabled, independently of their different weekday sets.
- `Foqos/Components/BlockedProfileView/ScheduleTimePicker.swift:19–23` compares clock time only; `:60–65` displays the prohibition and `:84` disables Save. `BlockedProfileView.swift:839–848` supplies the opposite schedule to both pickers.

**User-visible effect:** Monday 09:00 start / Friday 09:00 stop cannot be configured despite being different events. Monday 09:00 start / Friday 09:10 stop is treated as a ten-minute interval rather than several days. For Monday 09:00 / Friday 17:00, Monday evening catch-up incorrectly says the window has ended. Start-only catch-up also has a same-day boundary; whether historical starts should be caught up on later days must be specified rather than inferred from a V1 daily window.

**V1 origin:** Combined schedule concepts survived #30. `2e38ca5` (#98) added the current active-window abstraction; `0646039` (#100) imposed equal-time rejection; `a526d15` (#275) added minimum-window validation to satisfy the chosen OS registration shape. Those are later V2 changes preserving a paired-window assumption, not proof that independent recurrences require these limits.

**V2-correct fix:** Evaluate occurrences using each schedule's own days and time, and define catch-up against those occurrences and the last accepted/stopped session. Enforce OS minimum interval length on the internal registration scaffolding, not on the distance between independent product events. Remove equal-clock and short-pair restrictions for independently scheduled events. A truly simultaneous start/stop needs one documented deterministic rule; equal clocks on different days do not present that collision.

### F8 — Retained V1 combined schedules can revive a scheduled start after V2 turns it off

**Severity: high. Fact by traced flow; no device reproduction.**

**Evidence:**

- `Foqos/Models/BlockedProfiles.swift:926–951` migrates `schedule` into V2 fields and changes the version but never clears the old `schedule`.
- The editor passes `schedule: nil` on updates (`Foqos/Views/BlockedProfileView.swift:1157`), while `BlockedProfiles.updateProfile` at `:454–456` treats nil as “do not update.” Saving the V2 draft at `Foqos/Models/TriggerConfigurationModel.swift:137–145` does not clear the old field either.
- Registration at `Foqos/Utils/DeviceActivityCenterUtil.swift:13` accepts an active legacy schedule without testing that the profile is still V1. If V2 scheduled start is off, `:68–72` uses the old combined times.
- `Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift:66–86` likewise falls back to legacy schedule whenever its V2 start branch is absent, with no schema-version gate.
- `Foqos/Utils/StrategyManager.swift:1451–1463` retains these activities as non-ghost schedules. `Foqos/Components/BlockedProfileCards/ProfileScheduleRow.swift:7–19` also treats them as active regardless of schema version. The widget counts legacy scheduling at `FoqosWidget/Views/ProfileWidgetEntryView.swift:184–188`.

**User-visible effect:** After migrating a scheduled V1 profile, disabling Schedule in V2 can leave it starting at its former V1 time. If independent V2 stop remains enabled, the stale combined end can additionally stop at its old time because the combined callback checks only the schedule flag (F6).

**V1 origin:** The ungated fallback and retention entered together in `41ff702` for migration compatibility. Later registration and cleanup refactors preserved it.

**V2-correct fix:** Make schema/version ownership explicit: migrated V2 profiles derive behavior solely from V2 fields. Gate legacy reads to genuinely unmigrated profiles and remove obsolete activities when V2 disables a condition. Old columns may remain for migration/history; their presence must not override a deliberate V2 selection. Do not require destructive data deletion to solve this.

### F9 — “Every profile needs a stop condition” is a form rule, not a consistent session-start invariant

**Severity: high. Fact; related migration-boundary leakage.**

**Evidence:**

- The editor validates nonempty stops through `TriggerValidator.swift:53–64` and `TriggerConfigurationModel.swift:45`; the home Start resolver checks them at `StartStopActionResolver.swift:44–48`. Shortcuts checks them at `StrategyManager.swift:623–625`.
- The core app start guard at `StrategyManager.swift:1338–1357` checks active session and selection only. Tag starts reach it; direct manual execution also relies on upstream UI validation.
- Deep-link start branches at `StrategyManager.swift:481–496`, `:550–570` check the selected start trigger and app selection, but not whether stops exist. A profile switch can stop its existing session before starting a target with empty stops.
- `Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift:49–134` validates selection/schedule and takeover of the victim but not the incoming profile's stops. The snapshot already carries `stopConditions` (`SharedData.swift:268`).
- `BlockedProfiles.stopConditions` returns an empty object on absent/undecodable data (`Foqos/Models/BlockedProfiles.swift:134–142`); creation/sync can therefore expose states not created by the current editor.

**User-visible effect:** A profile arriving from incomplete data/sync or a bypassing caller can start headlessly without any stop, even though the Home button refuses it. A form-only fix leaves these paths inconsistent.

**V1 origin:** Old strategies implicitly provided an exit, so the low-level creation path did not need explicit stop configuration. #30 added a separate stop model without imposing the new invariant at every creation boundary. That causal explanation is inference; the differing guards are source facts.

**V2-correct fix:** Validate nonempty, well-formed independent stops at profile save/duplication and before originating a local session in both app and extension. Reject before restrictions, session insertion or takeover of another profile. Do not use the V1 credential predicate as that validation. Handle already-active/restored authoritative sessions separately; failing a configuration check must not silently discard an existing blocking session.

### F10 — Profile identity in the main card is still a V1 strategy pair

**Severity: medium. Fact.**

**Evidence:**

- `Foqos/Components/BlockedProfileCards/BlockedProfileCard.swift:128` always renders `StrategyInfoView(strategyId: data.blockingStrategyId)` for supported profiles, including V2.
- `StrategyInfoView.swift:9–28` obtains name/icon/color from the V1 strategy factory; `StartStopActionResolver.swift:20–30` falls back to NFC for unknown IDs.
- New V2 profiles are created with `NFCBlockingStrategy.id` regardless of selected starts/stops (`Foqos/Views/BlockedProfileView.swift:1170`). Existing edits pass nil at `:1146`, and `BlockedProfiles.swift:402–404` leaves the old ID untouched.

**User-visible effect:** A manual→timer, scheduled→QR or otherwise independent V2 profile can be labeled “NFC Tags”; migrated profiles retain an obsolete pair label after editing. This teaches the user and reviewer the wrong model and can make an incorrect setup look familiar.

**V1 origin:** Strategy summaries predate V2; #30 retained their use in the card and continued the default strategy ID. The later card snapshot refactor (`a0c98c5`, #300) preserved it.

**V2-correct fix:** Render separate start and stop summaries from V2 configuration, using existing labels/icons as appropriate. Restrict V1 strategy labels to actual unmigrated profiles. No strategy-to-pair compatibility projection should drive V2 UI or behavior.

### F11 — Schedule presentation still declares valid timer combinations unstable and collapses independent weekdays

**Severity: medium. Fact.**

**Evidence:**

- `Foqos/Components/BlockedProfileCards/ProfileScheduleRow.swift:21–37` uses the Timer stop flag but reads duration from legacy `strategyData`.
- `:90–92` shows a warning for any schedule plus Timer; `:115–120` replaces the schedule display with “Unstable Profile with Schedule.” It applies to scheduled start + timer and scheduled stop + timer alike, without testing actual registration.
- `:40–49` unions start and stop weekdays; `:56–65` presents start-to-end clock times as one range. Monday-start / Friday-stop is displayed as a shared-day range rather than independent events.
- `:104–114` displays legacy configured duration for an active session; it is not evidence that the session has a registered countdown or that an invocation override used this duration.

**User-visible effect:** A combination explicitly allowed by V2 is labeled defective. Different start/stop day sets are misrepresented. Old duration data can imply a timer is working when F1 left it unarmed.

**V1 origin:** The instability warning and duration presentation date to `8d3dbf4` (V1); `0aa03d1` expanded timer-strategy handling. #30 changed the schedule inputs but retained the warning and created the union/range representation. Later card and registration work preserved them.

**V2-correct fix:** Display start and stop recurrences separately when their day sets differ; show Timer as another permitted stop. Warn on actual invalid configuration or failed registration, never merely on Timer plus Schedule. Distinguish configured duration from an active session's accepted deadline; use the latter for a countdown claim.

### F12 — Timer failure/expiry still assumes a profile-owned V1 timer, not the current session's independent stop

**Severity: high if triggered. Source facts; stale-callback occurrence is a runtime risk, not reproduced here.**

This is adjacent lifecycle leakage that matters when fixing F1; the V1 origin is direct, although the three human rulings alone do not specify every failure policy.

**Evidence:**

- `Foqos/Models/Strategies/ShortcutTimerBlockingStrategy.swift:35–46` creates/publishes a session before registration. `DeviceActivityCenterUtil.swift:281–302` records a nil deadline on failure and returns a warning without ending/refusing the newly active session.
- The outer `StrategyManager.swift:649–650` throws “The session started, but …”, leaving that session active. Its Duration exception at `:627` allowed a profile whose configured exits otherwise failed the usability check.
- `Packages/FoqosShared/Sources/FoqosShared/Timers/StrategyTimerActivity.swift:14–15` identifies the activity only by profile UUID. Its start callback at `:28–41` can activate restrictions with no active session (it only rejects a different profile). Its stop at `:44–77` checks profile identity but neither the session's accepted deadline nor timer ownership, and ends shared state without an expected session ID.
- In contrast, schedule stop callbacks already pass `expectedSessionId` when ending shared state (`ScheduleTimerActivity.swift:159`, `StopScheduleTimerActivity.swift:55`).

**User-visible effect:** Failure of an explicit Shortcut timer can leave a timer-only session running with no countdown. A stale callback for the same profile could act on a replacement session; a timer start callback with no session can briefly apply restrictions. The callback facts are certain; actual stale delivery is an inference requiring device/lifecycle testing.

**V1 origin:** `87cbefd` introduced `StrategyTimerActivity`; its profile-only shape predates #30 and survived V2. `5a29545` added an accepted session deadline and surfaced registration failure but preserved the old callback behavior.

**V2-correct fix:** Treat countdown establishment as part of originating a timer-enabled session, with an explicit failure outcome that cannot silently strand a timer-only profile. Reuse the accepted session deadline/identity, avoid acting on a missing/replaced session, and end with an identity guard. Coordinate early-stop cleanup and replacement/takeover paths. Do not simply scatter F1 registrar calls across starts while preserving unchecked profile-level expiry.

## What is not proved to be a V2 pairing defect

- One-time conversion of an actual V1 strategy into equivalent V2 starts/stops is legitimate migration. `Foqos/Utils/TriggerMigration.swift:8–55` is not wrong merely because it contains the old pairs. The problem is subsequent execution or validation continuing to depend on the pair. Timer migration produces a Timer flag but is incomplete operationally because of F1.
- `start.shortcuts = start.manual` in migration and the legacy Codable fallback (`ProfileStartTriggers.swift:51`) seed an old-data default. They are not a permanent pairing constraint: current editor switches are separate. Do not remove compatibility defaults simply to eliminate matching words.
- Raw fields such as `blockingStrategyId`, `strategyData`, `forceStarted` and physical-unlock IDs can remain for decoding and migration. The relevant bugs are consumers that give them V2 authority, identified above.
- The private `bypassStrategy: false` branches at `StrategyManager.swift:1202–1205` and `:1378–1381` still permit V1 dispatch, but all located callers of those private app start/stop helpers pass true. Their existence is a maintenance hazard, not proof they presently route normal V2 starts through NFC/QR strategies. The explicit Shortcut duration branch is separately reachable.
- NFC/QR picker sub-options are exclusive, and resolver precedence is specific → same → any. That is factual (`TriggerPickerOptions.swift:52–62`, `:121–131`; resolver `:164–215`). The given ruling establishes independence of **start versus stop**, not necessarily simultaneous contradictory sub-options within one modality. I have not classified all intra-modality exclusivity as a confirmed defect. If the replacement spec intends all stop flags as OR alternatives, that precedence must also change and migration/sync normalization must be specified.
- A deep-link start can switch profiles only after the active profile permits a deep-link stop (`StrategyManager.swift:481–555`). This preserves a single-active-session policy. It should receive F1/F9's independent-stop handling, but the supplied rulings do not themselves abolish profile switching or authorize one profile's start to bypass another's stops.
- Timer-only Stop refusing an immediate manual stop is correct when its timer really exists. Merely making Stop always end the session would violate configured stops and conceal F1.
- The private-account remote timer owner policy is intentional: a mirror adopts the accepted timer deadline rather than independently registering it. This audit does not recommend turning mirrored adoption into a new local start. The missing scan credential issue is specifically F3.

## Why previous passes did not eliminate this

### 1. The V2 intent existed, but its executable contract did not

**Fact:** #30's commit message explicitly promises independent combinations, yet that same commit installs F2 and retains F1/F6/F8. The current source has separate flag models but several conflicting authorities: editor validator, picker option rules, start resolver, `canStop`, Shortcuts predicate, background policy, schedule window helper and legacy callbacks.

**Inference:** Reviews checked local implementations against nearby code rather than one agreed end-to-end V2 conditions contract. I found no single current specification covering every start × stop combination, required stop data, timer establishment, no-scan Same behavior and independent schedule recurrences. This is not a claim that no such discussion ever occurred outside the repository.

### 2. A known implementation gap became specification and then tests

**Fact:** The Shortcuts/Siri spec at `docs/superpowers/specs/2026-09-10-shortcuts-siri-design.md:72–76` says Timer does not count because the current manual path does not arm it, and explicitly forbids fixing that path within its scope. Lines 212–213 call for timer-only/same-tag refusals. The unmerged #493 plan then reuses that predicate unchanged.

**Inference:** Narrowly scoped repairs treated existing behavior as product truth. A symptom-prevention guard became a restriction on V2 combinations, making later implementation “correct to spec” while wrong to the human's V2 model. There is no evidence here about individual reviewers' motives.

### 3. Several tests affirm the leakage; other tests stop before the missing side effect

**Fact:**

- `FoqosTests/TriggerValidatorTests.swift:24–39` expects Same to be unavailable without a matching start; `:77–108` verifies clearing/preservation by start modality.
- `FoqosTests/ShortcutsStatusTests.swift:23–42` explicitly codifies timer rejection, start credentials and the background/schedule veto.
- `FoqosTests/BackgroundStopPolicyTests.swift:89–96` treats scheduled-stop denial as success.
- `FoqosTests/PreActivationReminderSchedulerTests.swift:181–214` expects no separate stop activity for enabled V2 start+stop and accepts legacy start authority. Its start and stop fixtures use the same weekday.
- `FoqosTests/ScheduleWindowValidationTests.swift:46–60` supplies the same day array to both schedules; its tests validate the paired minimum interval rather than different recurrences.
- `FoqosTests/StrategyManagerStopTests.swift:87–147` tests Same with matching/nonmatching typed session tags; its Timer test at `:227–237` only checks a `.cannotStop` UI decision.
- `FoqosTests/SessionTimerEndTests.swift:31–36` enumerates the three legacy timer strategy tags and calls the registration helper; that proves deadline publication, not V2 manual/tag/schedule routing into it.

**Inference:** The tests are often good regression tests for what was implemented, but they cannot serve as the independent product oracle. Green tests can protect the exact behavior now ruled incorrect.

### 4. Previous audit remediation broadened a legacy concept

**Fact:** `docs/handovers/issue-239-deviation-17-still-present-disablebackgroundstop.md:7` says the finding was adversarially verified; `:12–26` recommends scheduled-stop denial. `8c86df2` implements it. The current issue is not an overlooked missing guard: an earlier pass deliberately added the guard under a different interpretation.

**Inference:** “Independent review” did not help where implementer and reviewer shared the same unstated premise. The correction requires reviewing the premise against the human's V2 contract, not adding another reviewer to the same local checklist.

### 5. Migration scaffolding and split processes hide the actual control flow

**Fact:** V1 classes, IDs, blob data, schedules and flags remain in models and sync; V2 code routes around some classes but continues using others. The app and monitor extension create sessions through different paths. The comment at `StrategyManager.swift:880` says all starts converge, but scheduled creation in `SharedData.swift:550` is a separate process/path. A search for Timer finds complete-looking legacy classes and timer tests even though ordinary V2 starts cannot reach them.

**Inference:** Symbol-based audits can mistake the existence of implementation for end-to-end reachability. Read-only status improvements can further make nil deadlines honest without correcting the underlying absent timer.

## What stops recurrence

1. **Write the smallest authoritative V2 conditions contract before rewriting #493.** State the three rulings verbatim. Specify stop-owned required data, Same without a scanned origin, OR semantics/normalization within a modality, automatic expiry versus external background requests, independent weekday recurrences, simultaneous events, and countdown registration failure. Record which prior specs/tests are superseded. No new framework is needed.
2. **Test behavior across start × stop boundaries.** At minimum, manual/NFC/QR/Shortcut-without-duration/deep-link/schedule/catch-up starts with Timer must establish the configured countdown and deadline; every start with specific NFC/QR must be stoppable by the configured stop key independently of the initiating modality. Cover multiple enabled starts, missing scan origin and a same-account mirror. Test all-empty stops before any start/takeover side effect.
3. **Assert effects at the boundary.** A registrar spy must observe a Timer registration, not just a true flag or a status string. A simulated expiry must end the matching session. Cover failed registration, early stop, replacement of the same profile, and stale callbacks. Use real device probes for OS delivery/expiry claims.
4. **Exercise different recurrences and migration edits.** Monday start/Friday stop; equal clocks on different days; short clock gaps separated by days; manual start on a non-stop day; scheduled start registration failure with independently successful stop registration. Migrate a V1 schedule, disable its V2 start, and verify no legacy activity can restart it.
5. **Update the oracle, not just add tests.** Replace the contrary assertions listed above with tests derived from the new contract. Retain OS interval safety checks on internal registrations and legitimate restrictions such as explicit physical keys, matching session identity and existing lock-code edit gates.
6. **Keep migration at a boundary.** Convert V1 once; branch on schema for truly unmigrated profiles. V2 runtime/UI should consume independent V2 data. Reuse the existing small registrar and stop-only activity rather than inventing a second strategy hierarchy or a generic policy engine.
7. **Review combinations adversarially.** For each new guard, ask whether changing only the start choice can hide, erase or disable a configured stop. For each automatic stop, trace configuration → persistence/snapshot → every originating start route → registration → expiry → cleanup/status, including the extension. The reviewer should derive counterexamples from the human contract before reading implementation-specific tests.

## Verification performed and limitations

- Read the pinned tree's models, selectors, validation, Home dispatch, strategy manager, all legacy strategy classes relevant to timers/tags, shared timer activities, schedule helpers, snapshot/wire timing, card/widget presentation and associated tests/specs. Searched production callers of countdown registration and start/stop dispatch; checked ancestry with `git log`, `git show` and `git blame`.
- Executed `/private/tmp/family-foqos-v1-leakage-probe.swift` using `swift -module-cache-path /private/tmp/family-foqos-audit-swift-cache ...`; exit status **0**. It uses the audited pure source functions, removing only the unavailable shared-module import, actor annotation and unrelated strategy factory. It is a diagnostic extraction, not a substitute for the app test suite.
- Seven assertions confirmed: manual start hides Same NFC; start change clears the sole Same NFC stop; manual-origin Same cannot match; Timer is valid but rejected by usability; background flag denies Schedule; Monday-start/Friday-stop catch-up closes on Monday evening; manual→specific-QR remains supported. These last two distinguish actual coupling from claims that all V2 combinations fail.
- No repository changes were present in `git status --short` at the final pre-report check. No simulator fleet slot or implementation worktree was consumed. Herdr socket access required a sandbox escalation; the retry succeeded, so there is no outstanding communication blocker.
- The report is complete for the requested read-only audit. Findings about OS callback timing and failure scenarios are clearly marked where they remain source-derived rather than device-reproduced. Implementing fixes, obtaining the narrow Same/background semantic decisions where needed, and running device acceptance are subsequent work, not completed by this report.

## Follow-up — Tags, QR codes and profile links (2026-10-02)

bobbithy, **the human's distinction is substantially correct, with one correction: NFC uses the chip identifier rendered as hex, not a hashed serial number. QR uses hashed content. A profile link is a separate identity today.** The difference in information delivered by iOS is real; making it a different user-visible stop option is an application design choice, inherited from the old architecture. A common tag model is possible, but current profile-only URLs cannot identify individual NFC chips or distinguish identical printed QR copies.

**Revision:** This follow-up checks `origin/main` at **`8e4ee25e977116c17508ca0af20bfc6636f905f6`**. The intervening commit #501 changes documentation only; `git diff 0fa5f9d origin/main -- Foqos FoqosWidget Packages` is empty. Thus the code line references from the audit remain valid. Facts, platform facts and proposed behavior are distinguished below.

### 1. What each object carries, and what the app reads

| Object / interaction | Identity actually available to current code | Does it identify a profile? | Does it identify an individual physical item? |
|---|---|---|---|
| NFC written with **Write Profile** | One NDEF URI record containing `https://family-foqos.app/profile/<PROFILE-UUID>` | Yes, the UUID in the path | The URL does not. The chip separately has its hardware identifier. |
| QR generated from a profile | That same profile URL encoded as the QR text | Yes, if treated as a link | No unique print/copy ID. Every generated copy for the same profile has the same payload. |
| In-app NFC scan | Hardware identifier bytes rendered as lowercase hexadecimal | No profile is extracted from NDEF; the scan belongs to the current start/stop UI action | Distinguishes supported chips by the identifier they expose; no claim of cryptographic authenticity. |
| In-app QR scan | SHA-256 of normalized scanned text, plus SHA-256 of raw text for compatibility | A profile URL is just text to the current scanner; its path is not dispatched | Identifies content, not paper. Two identical prints match as the same code. |
| iOS opens a written-tag / QR URL | Current app consumes the URL, then extracts the profile UUID | Yes | No tag ID, chip UID, QR digest, or printed-copy ID is extracted. |

**Code evidence:**

- URL construction: `Foqos/Models/BlockedProfiles.swift:586–588`. There is no tag parameter or embedded `SavedTag.id`. The same UUID URL is supplied to the writer at `Foqos/Views/BlockedProfileView.swift:1039–1042` and the QR view at `:739–745`.
- NFC writing: `Foqos/Utils/NFCWriter.swift:167–177` builds `NFCNDEFPayload.wellKnownTypeURIPayload(url:)` and an NDEF message from that URL; it does not append the detected chip's ID. QR generation encodes the supplied string's UTF-8 bytes at `Foqos/Components/Strategy/QRCodeView.swift:87–95`.
- NFC read: `Foqos/Utils/NFCScannerUtil.swift:189–218` reads the MIFARE/ISO15693 identifier, calls `hexEncodedString`, and returns it whether NDEF reading succeeds or fails. The NDEF contents are discarded. `:337–340` implements the hex conversion using `%02x`, with no hashing. `NFCResult` at `:4–7` contains only ID and scan date.
- QR read: `Foqos/Components/Strategy/QRCodeScanner.swift:184–193` hashes `scanResult.string`. `Foqos/Utils/QRCodeHasher.swift:9–32` trims whitespace/newlines, normalizes URL scheme/host case and a bare root slash, then produces SHA-256; the raw digest remains available to match older stored values. NFC/QR sessions retain `nfc:<id>` / `qr:<digest>` in `Foqos/Utils/StrategyManager.swift:1223–1245`.
- **Why “hashed serial” may sound familiar:** `Foqos/Models/SavedTag.swift:14–25` stores the input ID unchanged, but derives its CloudKit record name as `SavedTag_` plus SHA-256 of that ID. That record-name hash is not the NFC comparison key. Tag-list enrollment passes the scanner's ID directly at `Foqos/Views/TagsView.swift:75–78`.
- Incoming links: `Foqos/FoqosApp.swift:177–187` uses `userActivity.webpageURL`, not `ndefMessagePayload`; `Foqos/Utils/NavigationManager.swift:14–25` extracts `/profile/<id>` (execute) or `/navigate/<id>` (navigate). `StrategyManager.toggleSessionFromDeeplink` at `:447–570` resolves that profile; its `url` parameter is not used to derive any tag identity.
- Saved tags are account-wide and can be assigned to multiple profiles (`Foqos/Models/SavedTag.swift:57–61`). “B's tag 1” can mean a saved scan key assigned to B or a chip carrying B's URL; these are separate associations in today's code. Writing B's URL does not automatically create or assign a named tag key.

### 2. Platform constraint versus V1 inheritance

**Platform fact:** Apple's background NFC flow inspects NDEF for a URI, displays a notification, and hands the activity to the associated app after the user accepts it. It is not a silent app-owned hardware scan. An active Core NFC reader session prevents that background scanning flow. Thus “app open versus closed” is only shorthand: a URL can arrive while the app is open, and a dedicated in-app NFC scan is a distinct reader session. [Apple: Background Tag Reading](https://developer.apple.com/documentation/corenfc/adding-support-for-background-tag-reading)

**Platform fact:** “Background NFC gives only the URL” is slightly too strong. Apple exposes the **NDEF message** through `NSUserActivity.ndefMessagePayload`; today's app chooses to retain only `webpageURL`. The documented handoff does not supply the chip's `NFCTag` hardware UID. Do not confuse the writable NDEF **record** identifier with the hardware identifier exposed by `NFCMiFareTag.identifier`. Consequently a chip UID cannot be reconstructed from two identical profile-only NDEF messages. [Apple: ndefMessagePayload](https://developer.apple.com/documentation/foundation/nsuseractivity/ndefmessagepayload), [Apple: MIFARE identifier](https://developer.apple.com/documentation/corenfc/nfcmifaretag/identifier), [Apple: NDEF payload](https://developer.apple.com/documentation/corenfc/nfcndefpayload)

**Platform fact:** Camera/Code Scanner can recognize a QR and open its link when the user selects it. This does not give a print a hardware serial number. [Apple: Scan a QR code](https://support.apple.com/en-gb/102680)

**Repository/history fact:** V1 already had a separate profile-link toggle/switch path, using `ManualBlockingStrategy` and the background-stop flag (`git show 41ff702^:Foqos/Utils/StrategyManager.swift`, lines 484–538 in that historical version). Its direct NFC path used tag IDs; `dba47d6` (2025-12-20) is explicitly titled “updated scanner util to always read the tag ID and not care about the error.” #30 (`41ff702`) removed `NFCResult.url` and retained the split, now exposing `deepLink` as an independent V2 condition alongside physical NFC/QR conditions.

**Conclusion / inference:** The transport and identity distinction is necessary to account for platform capabilities. The current rule “NFC/QR Any/Same/Specific applies only to in-app scans; a link uses a separate Boolean” is not mandated by iOS. It is a preserved application boundary. Calling the entire split merely a V1 bug would miss the real missing-identity problem; calling the current UX unavoidable would also be wrong.

### 3. Can V2 unify the concept?

**Yes, for inputs carrying enough identity. Proposed behavior, not today's implementation:** Have both reader adapters produce the same logical tag/key identity and an optional target profile, then run the same Any/Same/Specific evaluator. Keep the **stop key** separate from the **profile to start**. B's profile UUID answers “what might start next,” not “is A allowed to stop?”

The minimum needed depends on the identity promise:

1. **If content identity is sufficient:** A new logical key ID can be carried in the URL, for example `https://family-foqos.app/profile/<B-UUID>?tag=<KEY-ID>` (illustrative format, not currently implemented). Different keys for B must carry different IDs. In-app NFC must parse that NDEF identity rather than discard it; in-app QR and URL opens must parse the same identity. Reusing a link on NFC and QR can intentionally mean the same logical key if that is the product choice.
2. **If existing NFC chip-specific matching must survive:** During enrollment/writing, map the existing UID to a logical key whose URL includes its ID, or explicitly encode the UID with a type/namespace. The background event can then resolve the same comparison key as the in-app scan. A UID written into a URL is a claim in the payload, not independent hardware verification. An application-issued key ID plus an enrollment mapping avoids mistaking those two sources for equivalent proof.
3. **QR can be bridged more cheaply in some cases:** For an existing generated profile QR, the incoming URL text can be normalized/hashed with the same function to match its saved QR content ID, without reprinting. That cannot distinguish two copies of the same QR. Unique tag 1/tag 2 print identities need different payloads and therefore reprinting. Arbitrary non-URL QR text can still be scanned in-app, but cannot be assumed to launch this app from the system camera.
4. **Old written NFC tags lack the missing information:** If two chips both contain today's B profile URL, no lookup can determine which chip was presented in a background open. Per-chip Same/Specific parity needs rewriting writable tags with individual identity, or a second foreground scan to obtain UID. Read-only tags cannot be rewritten; they remain foreground-only for UID matching or require replacement. A migration must not guess that B's URL means every saved key assigned to B. Existing profile-only links can remain a clearly defined legacy link behavior, but cannot truthfully satisfy a chip-specific condition without more information.
5. **Persist and transport the canonical identity where Same needs it:** Store it when an identified tag starts a session and preserve it across restoration and relevant private-account session sync. Apply the separate no-tag-origin Same decision from F3 to manual/scheduled starts. Merely adding identity to the URL leaves Same broken if session creation still writes `ManualBlockingStrategy` or `remote-sync`.
6. **Use one event decision:** Evaluate A's stop conditions against the presented identity first. If A denies, leave A running and do not start B. If A permits, end A; an eligible B can then start. In-app scanning must preserve the optional profile target if it is to perform the same switch as a URL; current scanner APIs discard it. Existing raw UID/content scans without a target can still stop A without inventing B. Keep actual geofence and other applicable restrictions. The existing `disableBackgroundStops` setting must be given an explicit role: retaining its URL-only veto would deliberately retain different results by transport even after identity matching is unified.

**Important identity limit relevant to this design:** A static key URL can be copied, clicked or re-encoded. Equal URLs mean equal logical keys, not proof of a particular physical chip or sheet of paper. Hashing that URL does not change this. If “Specific” must mean physical NFC presentation verified through the reader, a bare URL cannot supply that guarantee; require a foreground scan for that promise. This is a constraint on the requested unification, not a recommendation to add a cryptographic protocol.

Keep URI parsing/validation at the boundary (recognized scheme/host/path, well-formed identifiers); do not interpret arbitrary text containing a profile path as a trusted key. Adapters and the existing saved-key model can implement this without another start/stop strategy hierarchy.

### 4. A active; user presents B's tag 1

**Assumptions for comparison:** Tag 1 and tag 2 have genuinely different matching identities. A's listed stop is its only relevant tag stop unless the row explicitly adds the link alternative. For today's code, Any/Specific refers to the scanned modality (Any NFC for NFC, Any QR for QR). Geofence permits stopping, background stops are not disabled, and B has an eligible link start and app selection. As requested, this ignores B-start failure. “Unified” below means the proposed transport-neutral rule, with tag 1 successfully resolved to its canonical identity and B target.

| A's stop configuration | Today's in-app stop scan of B's tag 1 | Today's iOS URL open from B's tag 1 | Unified identified-tag event, either route |
|---|---|---|---|
| **Any tag**; separate `deepLink` stop **off** | **A stops.** NFC UID/QR content matches Any. The scan itself does **not start B**: its profile URL is ignored/not parsed. | **A stays active; B does not start.** The event is `.deepLink`, which does not satisfy Any NFC/QR. | **A stops; B may start.** Any accepts tag 1, regardless of the profile named on it. |
| **Specific tag 2**; separate `deepLink` stop **off** | **A stays active; B does not start.** Tag 1 does not match tag 2. | **A stays active; B does not start**, but because the link option is off, not because the app compared tag 1 with tag 2. | **A stays active; B does not start.** The common matcher rejects tag 1 against tag 2. |
| Any tag **plus** `deepLink` stop **on** | A stops through Any; no automatic B start from this scan. | **A stops, then B is started.** The separate link condition allows it. | The separate transport-specific permission is unnecessary for an identified tag; Any produces the same stop decision. |
| Specific tag 2 **plus** `deepLink` stop **on** | Tag 1 fails the physical matcher; A stays active. | **A stops, then B is started, even though this was tag 1.** The link path checks the enabled link alternative, not tag 2. | If the product means **only Specific tag 2**, tag 1 must not stop A. Keeping a separate “any profile link” alternative would intentionally still allow it and is not equivalent to Specific-only. |

**Code proof:** In-app `HomeView.swift:624–627` calls `stopWithNFCTag`; the QR sheet at `:448–451` calls `stopWithQRCode`. `StrategyManager.swift:1255–1272` / `:1286–1303` uses the physical matcher and ends only A; there is no target-B dispatch. The matcher in `StartStopActionResolver.swift:164–215` accepts Any or a matching Specific ID. Its separate `.deepLink` case at `:225–229` checks only `conditions.deepLink`. The URL path checks A's background flag at `StrategyManager.swift:473–480`, evaluates `.deepLink` at `:499–510`, then stops A and starts B at `:540–555`. It does not require B's profile UUID to equal A's or compare the presented chip with A's specific key.

**Two qualifications that matter:**

- If `disableBackgroundStops` is true, today's URL path keeps A running in all four rows, before tag-stop conditions are considered. The in-app physical matcher does not consult that flag. This is not determined simply by whether the app happened to be foregrounded.
- Two QR images generated for the same B profile today are **not distinct tag 1/tag 2 identities**. They have identical content/digests. If A's Specific QR 2 was enrolled from one such print, an in-app scan of the other print will also match and stop A. Two NFC chips with that same B URL do have distinct in-app UIDs, but their background URL events remain identical. Thus the requested Specific-2 rejection requires distinct keys, not merely two physical copies.

### Follow-up verification

Traced current URL generation, NFC read/write, QR hashing, named-key storage, URL delivery/navigation, and both stop/switch routes. Compared V1 history and checked Apple's primary platform documentation. Ran `/private/tmp/family-foqos-tag-link-probe.swift` against the same extracted pure source: exit **0**, with eight added matcher checks confirming Any/Specific physical results and the independent `.deepLink` alternative (the original seven audit checks also passed). No device claim is made and no repository artifact changed. No blocker remains.
