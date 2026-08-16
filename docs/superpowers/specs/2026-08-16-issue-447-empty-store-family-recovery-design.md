# Issue #447 Empty-Store Family Recovery Design

## Status and scope

This design's engineering received final independent adversarial approval on 2026-08-16. It is
implementation-ready after the maintainer resolved both product decisions directly on 2026-08-16.
Implementation is unfrozen; the recovery notice must inherit the corrected pattern from #449
after the planner supplies its exact merged head.

The recovery guard handles a device whose local family setup may have disappeared while the
current iCloud account still has a `FamilyMember` record. It restores family authority
independently of Device Sync. Profile restoration is offered only when both local state is fresh
and profiles are confirmed in the current account's private `DeviceSync` zone. Diagnosing why
local state disappeared, reconstructing local-only profiles, and merging independently-created
local and remote profiles remain out of scope.

The planned release target is version 2.0.49 build 67, after version 2.0.48 build 66 lands first.

## Maintainer decisions resolved on 2026-08-16

### M1: unbounded offline escape

The maintainer ruled that startup recovery is a recovery mechanic, not a security boundary, and
that new-user experience wins. After an indeterminate result, the UI offers Retry. After the
explicit retry also fails, it offers Continue Setup into normal onboarding. The guard re-arms on
later foreground and connectivity recovery until CloudKit returns a confirmed answer.

There is no grace-session counter, elapsed or launch cap, capability withholding, or durable bound
record. The previously specified bound-enforcement machinery is deleted rather than implemented.
Only the existing durable `recheckPending` signal survives termination so a later confirmed
membership still enters recovery. The maintainer explicitly accepted the possibility that a wiped
Child reinstall kept offline indefinitely remains in normal new-user behavior.

### M2: inconsistency trigger ignores app-group vetoes

The maintainer ruled that the local signals are indications, not cryptographic proof. Missing
onboarding completion plus an empty or absent profile store classifies as `fresh` regardless of
surviving app-group values. CloudKit membership confirmation still gates every recovery surface.

App-group state remains captured and informs recovery. In particular, a surviving Device Sync
consent crumb must be disabled before any role-only release so it cannot cause an automatic merge.
It never vetoes the initial inconsistency check. `membership confirmed + local state present`
remains a first-class outcome for re-arm after onboarding/local writes.

## Design choice

Use a read-only local snapshot, a process-wide startup gate that defaults closed, and a main-actor
`StartupRecoveryCoordinator` state machine. The gate controls both UI/startup composition and
background CloudKit push work.

A check launched from `HomeView.task` can lose the race to onboarding covers and `onAppear` side
effects. Attaching the sync engine before classification creates app-group device identity and can
seed the empty local store, masking the contradiction the guard needs to detect. Gating only the
foreground view is also insufficient because a silent push can launch the process and run the app
delegate before foreground classification.

## Pre-startup local evidence

`FoqosApp` captures immutable local evidence in its first stored-property initialization,
following the ordering proven by the #430 V2 probe. The capture runs before singleton-backed
`@StateObject` properties, `UserDefaultsMigration`, app-group suite construction, the global
`ModelContainer` request, onboarding, CloudKit verification, or
`ProfileSyncManager.attachEngine`.

The capture is read-only:

- The standard defaults domain is read with Core Foundation preferences. The onboarding sentinel
  is present when either the current `family_foqos_has_completed_onboarding` key or its
  pre-migration `hasCompletedOnboarding` predecessor has a persisted value.
- The production SwiftData URL comes from one extracted `AppModelStore` configuration shared by
  the app and inspector. If `default.store` is absent, the profile store is empty. If it exists, a
  WAL-aware read-only SQLite connection checks for `ZBLOCKEDPROFILES` and counts rows. Store
  absent, table absent, and count zero are empty; a positive count is local state present; a read
  failure is indeterminate.
- The app-group preferences domain is copied with Core Foundation preferences without
  constructing `UserDefaults(suiteName:)`. Its values inform recovery handling but do not veto a
  `fresh` classification.

No capture path creates a preferences suite, the main store, or its WAL. A read-only SQLite SHM
artifact is acceptable only if the WAL-aware reader requires it; creation of the main store or WAL
is a hard failure.

The pure local classifier returns `fresh`, `localStatePresent`, or `indeterminate`. Missing
onboarding completion plus an absent, table-missing, or zero-profile store is `fresh`, regardless
of app-group values. Persisted onboarding completion or a positive profile count is
`localStatePresent`; unreadable local evidence is `indeterminate`.

## Process-wide startup and silent-push gate

`StartupRecoveryRuntimeGate` has static stored state whose literal default value is held. Static
storage is lazy, so the design does not claim that a pre-main initializer runs before SwiftUI or
UIKit lifecycle construction. The stronger invariant is that no consumer can observe the gate
unheld unless the coordinator has completed an allowed release transition: whichever consumer
accesses the static first creates it in the held state. The frozen snapshot is registered before
ordinary startup dependencies are allowed through. Release is monotonic for the process and
idempotent.

While held:

- `FoqosApp` constructs only the neutral startup-recovery surface, not `HomeView`;
- `ProfileSyncManager.attachEngine`, migrations, normal foreground refresh, and onboarding side
  effects do not run; and
- `AppDelegate.didReceiveRemoteNotification` completes with `.noData` without invoking account
  verification, membership verification, child shared-data refresh, profile sync, or heartbeat
  refresh.

This is the same structural release gate used before `attachEngine`, so a future change to the
push call graph cannot silently weaken the invariant. The ordering proof observes behavior rather
than asserting initialization order: a test consumer representing `AppDelegate` reaches the gate
before constructing `FoqosApp` and must observe held.

Current code trace motivating the gate:

- `Foqos/FoqosApp.swift:64` captures recovery evidence, while app-group construction and migration
  currently follow at `Foqos/FoqosApp.swift:118-126`; engine attachment is currently released at
  `Foqos/FoqosApp.swift:333-347`.
- The silent-push callback starts at `Foqos/FoqosApp.swift:520-538`. Its task can verify family
  membership and refresh child data at `Foqos/FoqosApp.swift:539-553`, invoke profile sync at
  `Foqos/FoqosApp.swift:557-563`, and refresh parent heartbeats at
  `Foqos/FoqosApp.swift:564-566`.
- Account status alone currently changes only in-memory CloudKit properties
  (`Foqos/CloudKit/CloudKitManager.swift:105-114`), but membership verification can persist app
  mode or run confirmed-revocation cleanup (`Foqos/CloudKit/CloudKitManager.swift:339-374`).
- Child refresh persists lock caches and processes pending commands
  (`Foqos/Utils/LockCodeManager.swift:219-253`, `:264-280`, `:404-466`); a reset-emergency command
  triggers additional persisted and CloudKit side effects. Parent heartbeat refresh saves local
  monitored-device state (`Foqos/Utils/HeartbeatManager.swift:131-142`).

The trace therefore does not prove the callback harmless. The default-closed gate prevents this
entire mutating graph from starting before classification. A push skipped while held is not
replayed directly; the recovery lookup and the normal post-release foreground/sync refresh obtain
authoritative current state.

### Accepted APNs delivery-budget consequence

Completing every held silent push with `.noData` is honest, but iOS may reduce future background
delivery when an app repeatedly reports no data. A device held across several pushes may therefore
receive later lock-code propagation less promptly. This is an accepted correctness-over-promptness
trade-off: the persisted Child lock cache remains fail-closed, and the mandatory post-release or
foreground refresh fetches authoritative membership, lock codes, commands, profiles, and
heartbeats. The product must not promise immediate background propagation after a prolonged hold.

## Share acceptance is a legitimate exit

CloudKit share acceptance remains available while startup recovery is held because a parent's new
invitation is a natural remediation for a wiped child. It is not ordinary work released through
the runtime gate; it is an explicit, mutually exclusive authority transition that can resolve the
hold.

The current entry points receive share metadata at `Foqos/FoqosApp.swift:590-641`, detect a role
and stage confirmation at `Foqos/FoqosApp.swift:655-692`, then call
`completeShareAcceptance` from the user's Continue action at `Foqos/FoqosApp.swift:218-229`.
Completion accepts the share and applies the accepted family mode at
`Foqos/FoqosApp.swift:710-725`; registration and Child lock-code refresh follow at
`Foqos/FoqosApp.swift:727-746`.

The coordinator arbitrates recovery and acceptance on the main actor. Durable transitions are
mutually exclusive with acceptance; asynchronous lookups are not. The critical section covers
only local, bounded, fast writes to mode, onboarding, sync consent, coordinator state, and durable
intent. It never spans a CloudKit call, so a hung membership lookup cannot block this remediation
exit.

1. Metadata detection, role detection, and Cancel do not change recovery state.
2. Continue marks `acceptanceInFlight` before `acceptShareDirect` starts. A membership or profile
   lookup may remain in flight, but its generation becomes stale and its completion cannot commit.
   If a recovery durable-write section is already executing, acceptance waits only for that local
   write to finish. Once acceptance is observable, no new recovery durable-write section may open
   until acceptance succeeds or fails.
3. A failed or aborted share acceptance releases only the lease. The runtime gate remains held,
   the durable recovery intent and coordinator state remain byte-for-byte unchanged, and recovery
   may retry.
4. After the share is accepted and `applyAcceptedFamilyMode` completes successfully, the
   coordinator atomically invalidates its account-scoped recovery intent, marks recovery stood
   down, and releases the runtime gate. These operations are one main-actor transition; no stale
   recovery completion may write afterward.
5. Best-effort FamilyMember registration and Child lock-code refresh continue through the
   existing acceptance flow. Their failure does not resurrect the invalidated recovery intent;
   normal activation retries them under the accepted family authority.

This makes successful accepted authority win exactly once. It avoids both blocking remediation
and racing two writers over mode/onboarding state.

## Membership lookup and exact absence semantics

For every candidate requiring membership resolution, a dedicated read-only CloudKit service:

1. Confirms iCloud account availability.
2. Fetches the current iCloud user record ID.
3. Lists shared zones and finds an exact `FamilyPolicies` zone-name match.
4. Fetches that zone's changes from a nil token and finds a `FamilyMember` whose
   `userRecordName` exactly matches the current user record ID.

The result carries account identity: `member(role, userRecordID)`, `confirmedNone(userRecordID)`,
or `indeterminate`.

The #427 evidence boundary applies exactly:

- A successful shared-zone list with no exact `FamilyPolicies` match is `confirmedNone`.
- A successful, complete member-record fetch with no matching record is `confirmedNone`.
- A successful fetch with a matching, valid role is `member`.
- An unavailable account, account-ID failure, zone-list failure, per-record failure, undecodable
  role, zone-fetch failure, or operation failure is `indeterminate`. A thrown `.zoneNotFound`,
  `.userDeletedZone`, or partial failure is still a failed lookup, not confirmed absence. The
  service may convert it to `confirmedNone` only after a new successful zone list proves the exact
  zone absent.

Thus successful absence is authoritative; failed absence is never treated as absence. Reads log
only privacy-safe error categories and never the record ID.

## First-class state-machine outcomes

Local classification and confirmed membership combine into two explicit recovery outcomes:

| Local evidence at decision time | Membership | Outcome |
| --- | --- | --- |
| `fresh` | confirmed member | `freshMember(role, owner)` |
| `localStatePresent` | confirmed member | `localStatePresentMember(role, owner)` |
| either | confirmed none | release the normal new-user path |
| `indeterminate` or membership indeterminate | Retry, then unbounded Continue Setup/re-arm |

`localStatePresentMember` is not a re-arm special case. Every membership-confirmed input with
local state present converges on this same state and copy.

Every async entry point—cold start, Retry, connectivity recovery, foreground re-arm, count
refresh, and user action—coalesces into one coordinator-owned task. The coordinator uses a
monotonic generation token: only the current generation may commit state, stale completions are
ignored, and repeated triggers await the same in-flight operation. Durable transitions compare
the expected owner and state before writing, so role restoration, notice creation, offer clearing,
and gate release are idempotent.

## Re-arm must reclassify local state

After Continue Setup releases normal onboarding without a bound, every later membership re-arm
first captures and classifies local evidence again. It must not reuse the cold-launch `fresh`
result.

If membership is later confirmed and local state is now present, route to
`localStatePresentMember`. Restore only family role/authority. Do not enumerate remote profiles,
offer restoration, attach/start the sync engine, seed, or merge. Persist Device Sync disabled
before releasing normal startup, so an earlier app-group consent crumb cannot cause an automatic
merge.

The role-only notice uses distinct copy:

> **Your family role was restored**
>
> This device already has local setup or profiles, so Family Foqos restored only its family role.
> Device Sync is off to avoid merging profiles automatically. You can review Device Sync in
> Settings.

For a recovered Child, role persistence completes before authorization verification and shared
lock-code refresh. The role-only notice is durable and account-scoped under the same rules as the
fresh-profile offer.

## Fresh-member family-role recovery and durability

On `freshMember`, the coordinator persists an account-scoped recovery intent before restoring the
role through `AppModeManager.selectMode`, marking onboarding complete, and suppressing both
onboarding screens. Child recovery persists the Child role before authorization verification and
refreshes the fail-closed shared lock-code cache. Parent recovery restores Parent equivalently.
Role restoration never depends on Device Sync or synced-profile presence.

The durable record contains:

- the owning iCloud `userRecordID`;
- the recovered role;
- the recovery path (`freshMember` or `localStatePresentMember`);
- an optional synced-profile count hint and the time it was confirmed; and
- enough origin state to roll back a stale recovery safely if account ownership changes.

The record stores no name, profile field, lock code, or CloudKit error. The account identifier is
required security context, not user-facing copy, and is never logged.

Before reconstructing or acting on any durable notice, the coordinator fetches the current
account identity. On a mismatch it must not surface the stale role, count, or action. It holds the
startup gate, invalidates the old-account intent, and reruns membership for the current account.
If the new account is a member, it replaces the intent with the new owner and result. If a
successful lookup confirms no membership, it rolls back the recovery-only role/onboarding writes
recorded by the intent and releases the normal new-user path. If the lookup is indeterminate, it
holds and retries; it never exposes Home under stale recovered authority.

The intent is cleared only after the account-validated decision completes. A crash before that
point reconstructs the same state without duplicating side effects.

## Synced-profile discovery and consent boundary

Only `freshMember` performs profile discovery. The coordinator reads the current account's
private `DeviceSync` zone with `CKFetchRecordZoneChangesOperation` from a nil change token. It
follows all pages and folds `SyncedProfile` modifications and deletions into the current set.
It never uses `CKQuery` and performs no save, zone creation, subscription creation, engine
attachment, or sync-state mutation.

A successful complete fetch yields the confirmed count, including zero. A successful zone list
that proves the private zone absent also confirms zero. Record, zone, or operation failure is
indeterminate; a thrown missing-zone error must be rechecked by successful zone listing before it
can become confirmed zero.

This CloudKit read intentionally occurs **before Device Sync consent**. The app reads only record
identifiers and types to tell the user whether restoration is available; it does not download
profile fields or mutate sync state. The recovery UI must disclose this pre-consent availability
check in its privacy/accessibility copy. Restore remains the only action that enables Device Sync.

The stored count is only a hint. Before presenting a resumed offer, the coordinator validates the
account and re-fetches the count. Immediately before acting on Restore, Not Now, or zero-profile
Continue, it validates the account and count again. If the count changed, it updates the copy and
requires a new explicit tap; it never acts on a stale number or on a count belonging to another
account.

## Fresh-member user experience and copy

After current-account membership and profile count are confirmed, show:

> **We found your family**
>
> This device doesn't have local Family Foqos data, but this iCloud account is part of a Family
> Foqos family. Your family role has been restored.

The view also states that Family Foqos checked the account's Device Sync storage without enabling
Device Sync.

For one profile:

> We found 1 synced profile. Restore it to this device?

For more than one:

> We found N synced profiles. Restore them to this device?

Restore enables Device Sync only after the final account/count validation, then releases the gate
and attaches the existing engine. Not Now persists Device Sync disabled, clears the validated
offer, and releases into the restored family mode.

For a confirmed zero count:

> We couldn't find any profiles saved with Device Sync. Profiles that existed only on this device
> can't be recovered.

Continue clears the validated offer and enters the restored family mode with Device Sync off. No
copy promises recovery of local-only data or claims that existing local and remote profiles were
merged.

## Normal startup integration

Migration, schedule refresh, account verification, authorization verification, lock-code refresh,
and sync composition run once after an allowed release point. The process-wide gate is released
only after the applicable durable transition and account validation finish.

After one explicit Retry also returns indeterminate, Continue Setup is the unbounded indeterminate
release point and durably re-arms the check. Existing local state that does not meet the concrete
M2 trigger releases normal startup immediately. Confirmed membership with local state present
goes through the role-only notice and sync-disabled release, never the fresh-member restoration
offer.

## Testing and verification

Implementation resumes with strict RED-GREEN-REFACTOR cycles only after maintainer rulings and
reviewer approval. Tests must cover:

1. The full local classifier matrix, including app-group-only crumbs remaining `fresh`, persisted
   onboarding or positive profiles producing `localStatePresent`, and read failure remaining
   indeterminate.
2. Read-only physical effects: no defaults suite, main store, or WAL creation; WAL visibility and
   SHM classification.
3. A consumer-first gate proof: an `AppDelegate`-representing consumer accesses the static before
   `FoqosApp` construction and observes held; only an allowed coordinator transition can make a
   later observation unheld.
4. Silent pushes while held invoking none of membership verification, command processing, sync,
   heartbeat refresh, or app-group writes; pushes resume after monotonic release.
5. Repeated held pushes honestly returning `.noData`, foreground repair, and no correctness
   dependence on immediate post-hold APNs delivery.
6. Share metadata detection and Cancel leaving recovery untouched; acceptance acquiring exclusive
   ownership; concurrent recovery commits being impossible; failure preserving the held gate and
   exact durable state; and successful mode application atomically invalidating intent and
   releasing exactly once.
7. Exact #427 absence mapping, including every failed missing-zone form remaining indeterminate.
8. `freshMember` and first-class `localStatePresentMember` outcomes from cold start and re-arm.
9. Re-arm reclassification after local writes, role-only copy, Device Sync forced off, no profile
   count, no engine attach, and no merge.
10. Single-flight coalescing, stale-generation suppression, and idempotent durable transitions
   under repeated foreground/connectivity/retry/action events.
11. Account-scoped durable recovery across termination, account mismatch, rollback on confirmed
   none, and indeterminate fail-closed handling.
12. Count re-confirmation before every surface and action, including changed-count retap.
13. Private-zone counting across pages and deletions, read-before-consent disclosure, and zero
    confirmed only by successful evidence.
14. Child fail-closed ordering, exact copy, privacy logging, unbounded Continue Setup, durable
    re-arm across termination, and absence of grace/cap/capability-bound state.
15. All 12 target configurations at marketing version 2.0.49 and build 67.

Final verification includes focused tests, the full suite through build2's stable simulator
stream, Debug build, recursive Swift formatting lint, log privacy lint, sync guards, version
checks, and `git diff --check`. An independent reviewer must approve the exact signed head before
the planner merges. The release is one attended beta upload of v2.0.49 build 67 from verified
merged main; there is no V1 or diagnostic-experiment upload leg.
