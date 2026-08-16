# Issue #447 Empty-Store Family Recovery Design

## Status and scope

This design implements the release-blocking recovery guard approved by the planner on 2026-08-16. It handles a device whose local onboarding, SwiftData profile store, and app-group state are all fresh or empty while the current iCloud account still has a `FamilyMember` record. The guard restores the family role independently of Device Sync and offers restoration only for profiles confirmed in the private `DeviceSync` zone.

The change ships in version 2.0.47 build 65. Version 2.0.46 remains burned by the never-merged #430 diagnostic build. Diagnosing why local state disappeared and reconstructing local-only profiles remain out of scope.

## Design choice

Use a pre-startup local snapshot plus a main-actor `StartupRecoveryCoordinator` state machine.

The alternatives do not preserve the required ordering. A check launched from `HomeView.task` can lose the race to its onboarding covers and `onAppear` side effects. Attaching the sync engine before classification creates app-group device identity and can seed the empty local store, masking the contradiction the guard needs to detect.

## Pre-startup local evidence

`FoqosApp` captures immutable local evidence in its first stored-property initialization, following the ordering proven by the #430 V2 probe. The capture runs before singleton-backed `@StateObject` properties, `UserDefaultsMigration`, the global `ModelContainer` request, onboarding, CloudKit verification, or `ProfileSyncManager.attachEngine`.

The capture is read-only:

- The standard defaults domain is read with Core Foundation preferences. The onboarding sentinel is present when `family_foqos_has_completed_onboarding` has a persisted value.
- The production SwiftData URL comes from one extracted `AppModelStore` configuration shared by the app and inspector. If `default.store` is absent, the profile store is empty. If it exists, a WAL-aware read-only SQLite connection checks for `ZBLOCKEDPROFILES` and counts rows. Store absent, table absent, and count zero are empty; a positive count is existing state; a read failure is indeterminate.
- The app-group preferences domain is copied with Core Foundation preferences without constructing `UserDefaults(suiteName:)`. Any persisted app-group value counts as existing state, including Device Sync consent, device identity, snapshots, or schedule/session data.

No capture path creates a preferences suite, the main store, or its WAL. The expected read-only SQLite SHM artifact remains acceptable only if the WAL-aware reader requires it; creation of the main store or WAL is a hard failure.

The pure classifier returns:

- `existing`: any onboarding, positive-profile, or app-group sentinel exists. Release normal startup immediately and keep the guard invisible.
- `fresh`: onboarding is absent, profiles are confirmed empty, and the app-group domain is empty. Hold onboarding and sync attachment while checking CloudKit.
- `indeterminate`: local evidence could not be read reliably. Show the same retryable checking state used for indeterminate CloudKit results.

## Startup and membership state machine

While classification is unresolved, `FoqosApp` shows a neutral checking view instead of constructing `HomeView`. This prevents its onboarding covers and startup cleanup from running. `ProfileSyncManager.attachEngine` is also withheld, so no Device Sync identity, zone, seed, or write can occur before the guard decides.

For a fresh candidate, a dedicated read-only CloudKit service performs this sequence:

1. Confirm iCloud account availability.
2. Find the shared `FamilyPolicies` zone.
3. Fetch the current user record ID.
4. Query the shared zone for that user's `FamilyMember` record and decode its role.

The lookup returns one of three semantic outcomes:

- `member(role)`: enter recovery.
- `confirmedNone`: release normal startup and current onboarding without showing recovery UI.
- `indeterminate`: show an honest retry state and do not claim either membership or absence.

An indeterminate result is not an infinite hold. The UI first offers Retry. After an explicit retry also fails, it additionally offers Continue Setup. Continue Setup releases current onboarding and re-arms the membership check on every later foreground and relevant connectivity recovery until CloudKit returns `member(role)` or `confirmedNone`. This deliberately allows a wiped child device launched offline to remain temporarily in the pre-existing Individual behavior until connectivity returns; permanently blocking a genuinely new offline user is the worse failure. A later confirmed membership immediately enters recovery and closes the temporary unrestricted window.

## Family-role recovery and durability

On `member(role)`, the coordinator first persists the recovery intent, then restores the role through `AppModeManager.selectMode`, marks onboarding completed, and suppresses both onboarding screens. These writes are recovery actions made only after the pre-startup evidence is frozen and membership is confirmed.

Child recovery completes role persistence before authorization verification and refreshes shared lock-code caches. Parent recovery restores Parent equivalently. Family-role restoration never depends on the Device Sync setting or the presence of synced profiles.

A durable `StartupRecoveryNoticeStore`, modeled on the #446 one-shot notice store, records that the recovery offer is pending. It is set before the restored onboarding state can make the next launch look non-fresh. Startup checks this flag before the local fresh-state classifier, reconstructs the recovery screen after termination, and clears the flag only after the user explicitly chooses Restore, Not Now, or Continue for the no-profile result. A crash at any point before a decision therefore cannot lose the offer.

The durable record stores only non-sensitive recovery state: the restored role and the last confirmed synced-profile count. It stores no name, CloudKit record identifier, profile fields, or lock code.

## Synced-profile discovery

After membership restoration and before any Device Sync enablement, the coordinator reads the current private `DeviceSync` zone with `CKFetchRecordZoneChangesOperation` starting from a nil change token. It never uses `CKQuery`, preserving the private-sync I5 invariant.

The reader follows `moreComing` pages and folds `SyncedProfile` modifications and deletions into a set of current record IDs. A missing or empty zone is a confirmed count of zero. Transient CloudKit errors are indeterminate and return to the retry screen; the app does not guess that profiles are absent. The lookup performs no save, zone creation, subscription creation, engine attachment, or sync-state mutation.

## User experience and copy

Recovery UI appears only after CloudKit confirms membership, preventing false alarms for new users.

Title:

> We found your family

Introductory message:

> This device no longer has its previous local data, but this iCloud account is still part of a Family Foqos family. Your family role has been restored.

When the confirmed count is one:

> We found 1 synced profile. Restore it to this device?

When the confirmed count is greater than one:

> We found N synced profiles. Restore them to this device?

Restore explicitly enables Device Sync and only then attaches/starts the existing engine so it can fetch the profiles. Not Now leaves Device Sync disabled. Either decision clears the durable pending offer and continues into the restored family mode.

When the confirmed count is zero:

> We couldn't find any profiles saved with Device Sync. Profiles that existed only on this device can't be recovered.

Continue clears the durable pending offer and enters the restored family mode. The copy never promises recovery of local-only data.

## Existing startup integration

The current migration, schedule refresh, account verification, authorization verification, lock-code refresh, and sync composition run once after one of these release points:

- local evidence is existing;
- CloudKit confirms no membership;
- the user chooses Continue Setup after the required retry;
- the user completes the recovery decision.

When Continue Setup re-arms the guard, later membership checks run before the existing foreground child-authorization sequence. If membership is later confirmed, recovery role persistence happens before authorization verification and HomeView is replaced by the durable recovery offer.

## Testing and verification

Implementation follows strict RED-GREEN-REFACTOR cycles. Tests cover:

1. The full local classifier matrix, including absent/table-missing/zero/positive/read-failed store states and any app-group value.
2. Read-only physical effects: no defaults suite, main store, or WAL creation; WAL visibility and SHM classification.
3. Startup ordering: preflight capture precedes migrations/container/singletons, HomeView is withheld, and sync attachment cannot occur before resolution.
4. Membership outcomes: confirmed member roles, confirmed none, signed-out/transient indeterminate results, retry, Continue Setup, and foreground/connectivity re-arm.
5. Durable offer recovery across termination and clearing only on explicit decisions.
6. Child fail-closed ordering: role and onboarding persistence precede authorization checks; shared lock-code refresh occurs.
7. Private-zone profile counting across pages, modifications/deletions, missing/empty zones, and transient errors without `CKQuery` or writes.
8. Exact user copy, singular/plural count text, Restore, Not Now, zero-profile Continue, and invisibility for normal existing/new-user paths.
9. All 12 target configurations at marketing version 2.0.47 and build 65.

Final verification includes the focused tests, full suite through build2's stable simulator stream, Debug build, recursive Swift formatting lint, log privacy lint, sync guards, version checks, and `git diff --check`. An independent reviewer must approve the exact signed head before the planner merges. The attended beta upload occurs only after merge.
