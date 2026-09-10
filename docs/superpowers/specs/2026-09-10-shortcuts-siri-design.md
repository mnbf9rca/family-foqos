# Shortcuts start policy and Siri phrases

Issues: [#485](https://github.com/mnbf9rca/family-foqos/issues/485), [#486](https://github.com/mnbf9rca/family-foqos/issues/486). Baseline: `91893b8825b908b4144e3caaf5c1312e79f275f9` (`main`). Write-up only; the reviewed spec PR stays open for a build stream to inherit and lands with implementation.

## Accepted inputs and boundaries

The human accepted build2's reviewer-approved research, `docs/superpowers/research/2026-09-10-app-intents-ios27.md`, available in `/Users/rob/git/family-foqos/.worktrees/build2-app-intents-research`. This design uses that research; it does not repeat the Apple research or adopt new iOS 27 features. Retain the iOS 18.6 deployment target and the four existing intent identities.

The human chose an explicit per-profile Siri/Shortcuts start trigger, one device-wide unlock setting covering both start and stop, and exactly three spoken actions: start a named profile, stop a named profile, and current blocking status. No ad hoc app selection, Clock schema, breaks, emergency escape, voice editing, or family remote control; closed issues #487–#491 stay closed. Profiles, sessions, tags, and locations remain private to the owning account. Existing same-account session sync is unchanged.

**Migration clarification from the orchestrator:** an absent start-permission field defaults from `manual`. Tag-only profiles do not retain their existing Shortcuts bypass. An authorized editor can enable the new trigger alongside tags; there is no legacy exception. This supersedes the contradictory “tag-only profiles keep working” phrase still present in #485.

## Decision

Add `ProfileStartTriggers.shortcuts` and enforce it inside `StrategyManager.startSessionFromBackground`, where saved identifiers and Siri requests converge. Require valid stop conditions and a stop route usable without a scanned start tag. Reuse the existing manual session lifecycle after those gates pass; retire the optional duration override with an explicit error instead of creating a second ad hoc timer feature.

Add one “Require Device Unlock” toggle under Settings → Siri & Shortcuts, default **on**, applying equally to start and stop. With one switch, the default must account for stopping as well as starting: an unattended voice request must not stop even a voluntarily stoppable block by default. Turning it off permits both eligible operations while locked, subject to system availability and all profile rules. This trades some phone-down convenience for deliberate initial behavior; users who want unattended automations can opt out.

Package `StartProfileIntent`, `StopProfileIntent`, and `CheckSessionActiveIntent` in one `AppShortcutsProvider`. Keep `CheckProfileStatusIntent` available to existing automations without a packaged phrase. No new action catalogue, dependency, indexing service, or natural-language parser.

## Code evidence

| Boundary | Current behavior and consequence |
| --- | --- |
| `StartProfileIntent.perform` → `StrategyManager.startSessionFromBackground` | Resolves the UUID, rejects an active session and `needsAppSelection`, then starts with `forceStart: true`. It checks neither `startTriggers` nor `stopConditions`. A supplied duration writes `strategyData`, `updatedAt`, the app-group profile snapshot, and the model context before starting. |
| `HomeView.handleStartTap` → `StartStopActionResolver.determineStartAction` | Refuses `!stopConditions.isValid`, then offers only configured manual/NFC/QR choices or explains schedule/deep-link-only operation. This is the required existing stop-validity check. |
| `ProfileStartTriggers`, `TriggerConfigurationModel`, `StartTriggerSelector` | Triggers are Codable inside `BlockedProfiles.startTriggersData`, copied through clone and private-account `SyncedProfile.startTriggersData`. The form has independent trigger controls and an existing disabled/edit-code path; `BlockedProfileView.saveProfile` checks `editingDisabled` at entry. |
| `StartStopActionResolver.canStop`, `TriggerValidator` | “Same NFC/QR” needs the actual session's scanned tag. Having an NFC/QR start option enabled does not supply that credential to a Shortcut. Specific tags take precedence over same-tag, which takes precedence over any-tag within a modality. |
| `ShortcutTimerBlockingStrategy`, `StrategyTimerActivity` | The timer ends the session independently of the configured stop flags. Supplying a duration therefore adds a stop route, not just a display label. The current registrar logs registration failure without throwing. |
| `ManualBlockingStrategy`, `BlockedProfileSession.createSession`, `activateSession` | Creation publishes shared state and inserts a session without an explicit save; activation performs UI/timer/schedule/sync work. Stop logs a failed save and continues. Intents cannot treat a void strategy return as proof of durable success. |
| `stopSessionFromBackground` | Checks matching profile, `disableBackgroundStops`, geofence, and `BackgroundStopPolicy` with `.shortcut`, which requires manual stop. It retains the pre-await session reference across the location check and needs a final identity/policy check. |
| `BlockedProfilesQuery` | Resolves UUIDs and lists suggestions, but defaults to the alphabetically first profile. That default is inappropriate for a missing mutation target; there is no string query for phrases naming a profile. |
| `CheckSessionActiveIntent`, `StrategyManager.isBlocking` | The Boolean means an active session, including a break. The spoken question needs a more precise dialog while keeping existing Boolean automation semantics. |
| `SettingsView`, installed AppIntents SDK interface | Settings already uses device-local `@AppStorage`. AppIntent exposes type-level `authenticationPolicy`, including `requiresLocalDeviceAuthentication`; whether a computed preference is honored for each invocation requires device verification. `ForegroundContinuableIntent` is a runtime fallback on the deployment range. |

## 1. Profile permission and compatibility

Use the wire key `shortcuts` inside the existing trigger blob; no family-share or new CloudKit field. The UI label is “Siri and Shortcuts”, with one explanatory line: “Allow Siri and Shortcuts to start this profile.” It is independent of tap, tag, schedule, and deep-link permission and does not grant manual or Shortcut stop. Include it in `ProfileStartTriggers.isValid`.

Add an explicit `ProfileStartTriggers.init(from:)`: decode the existing keys as today, then decode `shortcuts` with `decodeIfPresent(Bool.self, forKey: .shortcuts) ?? manual`. The encoder always writes the Boolean. Adding a stored default without this decoder is insufficient: synthesized Codable would reject legacy blobs, and the profile getter would replace all their triggers with false. Test a real v3 JSON fixture without the new key. A present wrong-type value must fail decoding, not grant permission.

Preserve explicit true/false across save, reopen, cloning, and private-account sync. Do not keep recomputing it when manual changes after decoding. A new empty trigger configuration remains all false; the user selects its triggers explicitly. For v1 profiles, use the existing strategy migration first and initialize the new choice from the resulting manual trigger. No new schema migration is needed.

Keep profile schema 3 and the existing trigger blob. An older editor can omit the new key when it re-saves, resetting the choice on the updated reader to the manual-derived default; document that limitation and ask users to update their devices/recheck the switch. A schema bump would make whole profiles read-only on older devices while leaving their existing Shortcut bypass intact. This change does not claim to repair old binaries or enforce the new permission account-wide. Retain the existing unsupported-newer-profile refusal where applicable.

The new control inherits the editor's disabled state, temporary code unlock, and save-entry gate. A Child cannot change it on a locked profile without the existing code-authorized editor; a permitted start of that locked profile requires no extra parent-code prompt. Individual and Parent are not blocked by Child lock rules. Do not add a permission setter to an intent.

A profile with only this new start trigger is valid but tapping Start must not start it manually. Add a resolver explanation such as “Start this profile with Siri or Shortcuts.” Extend the exhaustive `StartAction` switches in HomeView without adding a new launch intent or a manual picker option. Mixed trigger profiles keep their existing in-app options.

## 2. Start execution and duration

Keep the existing intent type, profile parameter identifier, UUID entity identity, and optional `durationInMinutes` parameter identifier so saved shortcuts can still load. Mark the duration description as unsupported and omit it from the normal parameter summary. **Any non-nil duration is refused at the shared helper's entry, before migration or session reconciliation**, with “Shortcut duration overrides are no longer supported. Remove Duration from this shortcut and use the profile's configured stop conditions.” Never silently ignore it, substitute a default, write it into a clone, or apply it to locked or unlocked profiles. Remove the override branch and its saved-profile writes; remove obsolete bounds handling only where no caller remains. Timer strategies used elsewhere remain.

At the shared background-start boundary, re-fetch the profile and active session and check all of the following before creating a session or applying restrictions:

1. The current invocation has passed the app-wide unlock policy; cancellation returns without mutation.
2. Profile exists and its trigger format is supported; supplied duration is absent; no session is active. A repeated start does not toggle, restart, extend, or replace a session. A failed active-session fetch refuses the request.
3. Screen Time authorization is approved and the profile has device-local selection (`needsAppSelection == false`). Reuse the app's approved-status interpretation; do not run a new authorization flow silently or synthesize app-selection tokens.
4. `profile.startTriggers.shortcuts` is true. A saved UUID, a matching name, another enabled trigger, or an unlocked phone cannot override it.
5. `profile.stopConditions.isValid` is true, using the same primitive as the Start button. Additionally there is a configured stop route that does not require a start credential this invocation cannot supply.

For check 5, use one small predicate beside the existing resolver. Count manual stop; NFC/QR specific or any stop where that modality does not require the same start tag; and enabled scheduled/deep-link stop when background stops are allowed. Follow the existing specific → same → any priority within each scan modality; saved specific IDs and schedule data retain their existing form validation. Do not build a second configuration validator or fetch location during this predicate.

Two selected flags cannot by themselves count as an exit for this action: `sameNFC`/`sameQR`, because no tag was scanned, and `timer`, because the ordinary V2 manual-start path never arms `StrategyTimerActivity`. This is checkable in `ManualBlockingStrategy.startBlocking` and `StrategyManager.activateSession`, which registers only scheduled stops. A timer-only or same-tag-only profile is refused unless another permitted route exists. Refusal explains “Use the configured start method, or add a stop condition that works with Siri and Shortcuts.” Do not add timer setup, saved-duration reuse, registrar changes, or a duration editor here. A timer plus a usable alternative follows the same behavior as a tapped start; this PR makes no new timer guarantee. Repairing the general timer-trigger path is separate work.

This predicate is scoped to Shortcuts/Siri. A tapped V2 start with timer-only stop, or scheduled-only stop with background stops disabled, already has the same missing-exit problem. Do not silently expand #485 into a tap-path fix; changing the tap policy is separate work requiring a human scope decision. The new shortcuts-only Start-button explanation above is the only tap-routing change needed here.

Once those checks pass, use the same `ManualBlockingStrategy` lifecycle as a tapped start, with a nonphysical session tag and ordinary `forceStart: false`. Keep its activation, scheduled-stop handling, reminders, widgets, shared state, and same-account sync; do not call the universal-link toggle, legacy scanner UI, or the UI toggle that could stop an existing session. The action must propagate errors this lifecycle reports, including the existing scheduled-registration warning, and name the profile reloaded at execution time. A registration warning after activation must say the session started but its scheduled stop could not be registered; it must not say nothing changed.

This PR does not add a second transactional start or fix the common lifecycle's persistence ordering. `createSession` inserts/publishes without an explicit save, and the manual strategy's stop currently logs a save failure. Those pre-existing lifecycle limits apply to tap and Shortcut operation alike; do not claim this spec makes every start/stop durable before its dialog. Avoid success after an error the shared path actually reports, without creating parallel session/rollback machinery for Siri.

Preserve the optional start-geofence warning behavior rather than turn it into a hard stop restriction. If the existing warning setting is on and a start needs confirmation, continue in the foreground and use the existing warning flow before committing the start; cancellation has no effect. If location permission is absent, retain the current start-warning policy, which permits starting. After any authentication, warning, or location await, re-read active session and profile eligibility before starting.

Return the successfully resolved current profile name to the intent for its dialog. A renamed entity must not cause a stale success name. A successful response describes the configured session, not a duration parameter that was removed. Same-account sync failures retain the established local-session behavior and must not be described as cross-device completion.

## 3. One device-wide unlock setting

Store one Boolean in the same device-local UserDefaults used by Settings, with a shared key/default accessible to both mutation intents. Suggested key: `family_foqos_shortcuts_require_device_unlock`; absent means **true**. Do not sync it with profiles or place it on the family share. No per-profile override and no separate start/stop switches.

Settings → Siri & Shortcuts:

- Toggle: “Require Device Unlock”.
- Explanation: “Require this device to be unlocked before Siri or Shortcuts starts or stops a profile. Turn off to allow eligible actions while locked. Profile start and stop rules still apply.”

This ordinary device preference is available in every mode; it edits no locked profile or emergency setting. Turning it off cannot enable a profile's start trigger or relax its stop method, background-stop restriction, or geofence. Device authentication is not the parent's code or proof of a scan.

First use one computed static `authenticationPolicy` on each mutation intent, reading the shared preference: on maps to `.requiresLocalDeviceAuthentication`, off to `.alwaysAllowed`. Use local-device authentication because the ruling is about the phone that executes the action, not authentication on a paired device. Do not force the app to open merely because unlock is enabled.

The first implementation verification is a physical-device probe of this computed policy on the supported deployment range: change the preference on → off → on without restarting the app or rebuilding the shortcut, and invoke both actions locked/unlocked through Siri and Shortcuts. Confirm the policy is honored at invocation time and requires the executing phone's authentication. The accepted research establishes the policy API, not whether settings-dependent static metadata is refreshed; record the actual result in the implementation PR. A unit test of the getter is not evidence of system enforcement.

If the system caches the policy or does not honor changes, use the supported runtime fallback: `.alwaysAllowed` plus `ForegroundContinuableIntent` requesting system foreground continuation when the preference is on. Continue only after that succeeds; cancellation refuses the operation. Document that this fallback opens the app and requires interaction when the preference is on; it is not the preferred authentication-only experience. A build using this fallback must report that behavior to the orchestrator in its review handoff. Do not invent a LocalAuthentication wrapper or infer unlock from protected-file availability. If neither native route can enforce the setting, stop at the implementation gate and report the evidence instead of shipping an ineffective switch.

Read the preference for each invocation. If it becomes more restrictive while the operation awaits location or confirmation, refuse and ask the user to retry under the new policy. Authentication permits an invocation; it never waives the profile checks.

Status remains read-only and does not consult this setting. Do not add a fourth spoken action to expose or modify it.

## 4. Stop and status

Keep `StopProfileIntent` profile-specific. Preserve `BackgroundStopPolicy.evaluate(channel: .shortcut)`, matching active profile, `disableBackgroundStops`, manual stop, and the required stop geofence. The new start permission has no bearing on stop permission. A locked Child profile with permitted manual stop can still stop without a parent code; tag-only, timer-only, and scheduled-only stops remain refused through Siri.

After the geofence await, re-resolve the active **session ID** and refuse if it differs from the original or has ended. Use the current manual-stop and background-stop flags in the existing policy evaluation rather than passing the earlier hardcoded assumptions. Do not re-evaluate the geofence or introduce a new location transaction. Perform the final identity/policy check and stop on MainActor without another await between them; a late stop must not clear a replacement session's restrictions. Reuse the current stop lifecycle and its reported errors; no emergency fallback or separate persistence transaction.

For `CheckSessionActiveIntent`, keep its Boolean meaning: true while a session exists, including during breaks. Reconcile live state as today, then give a precise dialog for the spoken question:

| Current state | Dialog |
| --- | --- |
| No active session | “No, you are not blocking right now.” |
| Active with no temporary unblock | “Yes, blocking is active.” |
| Active break | “Your session is active, but blocking is paused for a break.” |
| Active one-more-minute grant | “Your session is active, but blocking is temporarily paused.” |
| Cannot read state | Throw a descriptive error; do not answer no. |

Do not add time-remaining, profile-history, app-list, tag, location, or family details to this status surface. Preserve `CheckProfileStatusIntent`'s existing Boolean output and action identity without adding a packaged phrase.

## 5. Phrase packaging and identity

One AppShortcutsProvider exposes exactly these entries, using the application-name token and at most the profile parameter in any phrase:

| Intent | Short title | Proposed phrase |
| --- | --- | --- |
| `StartProfileIntent` | Start Profile | “Start \(profile) in \(applicationName)” |
| `StopProfileIntent` | Stop Profile | “Stop \(profile) in \(applicationName)” |
| `CheckSessionActiveIntent` | Blocking Status | “Am I blocking right now in \(applicationName)” |

The notation above denotes AppShortcut interpolation, not literal speech. Use the framework's supported phrase syntax and stable system images. No duration phrase, Siri schema, Spotlight indexing, custom snippet, donation pipeline, or minimum-OS increase. The provider and start fix ship together.

Use the existing profile entity and dependency container. Add `EntityStringQuery` matching against current profile names for the start/stop phrases; return all matching candidates for system disambiguation, including duplicate names, instead of selecting the first. Remove `defaultResult`'s first-profile behavior. An omitted profile prompts for selection; no match or a deleted saved UUID returns an error. Suggested entities may remain name-sorted, and identifier lookup must remain compatible with existing saved shortcuts. Perform-time checks are authoritative; picker filtering is not a security gate.

No separate no-parameter “stop whatever is running” intent, no voice toggle, and no navigation/scanner intent. A refusal can tell the user to open the app and use the required method without adding a fourth phrase.

## Implementation acceptance

1. Extend existing trigger tests with an actual v3 blob: all original flags survive, missing shortcuts follows manual, tag-only defaults off, explicit false survives a manual change and private-sync round trip, and a wrong-type value grants nothing. Cover the existing v1 migration's derived default, new empty configuration, shortcuts-only resolver explanation, and clone preservation. No schema bump or migration-chain rewrite.
2. Extend `StrategyManagerBackgroundTests` using actual UUID lookup: manual-derived allowed, explicit disabled, tag/QR/schedule-only disabled, authorized opt-in alongside tags, empty stop conditions, same-tag-only and timer-only refusal, usable alternatives, scan precedence, background-stop restrictions, missing selection, denied Screen Time, active/repeated request, and stale/deleted entity. Test Child locked permitted start separately from forbidden configuration edits; Individual and Parent still work. Refusals leave session/configuration unchanged.
3. For supplied Duration in every mode, compare saved profile fields, `strategyData`, `updatedAt`, profile snapshot, and session count before/after refusal. Nil duration reaches the same lifecycle as tap only after eligibility passes. Diff-review removal of the duration writes and `forceStart: true`; no new timer strategy branch, registrar API, or session-transaction abstraction. Preserve warnings already reported by the common lifecycle without asserting atomic rollback or guaranteed persistence it does not provide.
4. Retain `BackgroundStopPolicyTests`. Extend background-stop coverage for a session replaced during the geofence await and current manual/background flags; no stale callback may clear another session. Keep existing geofence success/failure behavior and ordinary stop semantics.
5. Test the shared preference getter with absent/on/off values; both mutation intents use the same key and status does not. If fallback is needed, canceled foreground continuation must never reach the mutation closure. Test the status Boolean and each dialog state after reconciliation, including expired grants and read failure.
6. Build with App Intents metadata extraction and verify exactly three provider entries, their application-name/profile interpolations, preserved intent/parameter identifiers, and no default mutation target. Test string lookup with unique, duplicate, renamed, and deleted profiles. Use existing XCTest and small testable decisions; no new intent-testing framework is required.
7. Before implementation is declared ready, complete the native-authentication device probe above, then use real Shortcuts/Siri for cold/warm process, locked/unlocked device, cancellation, selected/missing profile, duplicate names, and unsupported duration. Confirm restrictions and unchanged configuration, not just speech. Exercise physical/geofence stop refusal and distinguish session/break status. Record exact OS/build, utterance, and result. If hardware is unavailable, report that gate to the orchestrator rather than claim it passed.

Use the repository's simulator wrapper and focused XCTest classes for implementation checks. Run relevant existing private-sync payload tests because the trigger blob changes; no schema or family-share test expansion. The spec PR itself requires prose/diff checks and adversarial design approval, not an Xcode run.

## Release-note requirements

Existing tag/QR/schedule-only shortcuts now refuse until an authorized editor enables Siri and Shortcuts for that profile. Existing shortcuts supplying Duration must remove it; timer-only and same-tag-only stops require a compatible alternative or the original configured start method. Start and stop require device authentication by default; the one Settings switch opts into unattended operation for both. If the runtime foreground fallback is needed, release notes must say enabling the setting opens the app. Editing a profile on an older app version resets its Siri and Shortcuts switch to match Tap to start, and old binaries retain their existing bypass. State these changes plainly when #485/#486 ship.
