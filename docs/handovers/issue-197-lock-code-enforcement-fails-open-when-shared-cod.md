# Handover: Lock-code enforcement fails open when shared codes cannot be fetched (offline/CloudKit error)

- **GitHub issue:** #197
- **Severity:** critical
- **Domain:** family-lockcode
- **Primary location:** `Foqos/Views/BlockedProfileView.swift:132`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

In child mode, LockCodeManager.canVerifyCode (LockCodeManager.swift:270-273) is !cachedLockCodes.isEmpty, and cachedLockCodes is an in-memory-only array populated solely by fetchSharedLockCodes() during handleModeChange (app launch). It is never persisted. BlockedProfileView.editingDisabled (lines 129-133) and the lock banner (lines 251-253) require `lockCodeManager.canVerifyCode` to be true for the lock to apply, so an empty cache disables the lock entirely. The same fail-open gate protects Leave Family: ParentDashboardView.childNeedsPinCheck (line 81) and ChildSettingsView.hasLockCode (ChildDashboardView.swift:603-605) skip the PIN sheet when no codes are cached. The comment at ParentDashboardView.swift:55 claims "PIN verification uses cached lock codes that work offline" — false, nothing is cached across launches or after a failed fetch.

## Failure scenario

Child force-quits the app, enables Airplane Mode, and relaunches. fetchSharedLockCodes throws a network error, cachedLockCodes stays []. The child opens the managed profile: editingDisabled is false, the save checkmark appears (BlockedProfileView.swift:650), and the child removes all blocked apps and saves — no code required. Same window exists online: any transient CloudKit fetch error (or racing the fetch right after launch) also leaves the cache empty, additionally allowing 'Leave Family' without the PIN check.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Every element of the claim verified against the code and every refutation attempt failed. (1) cachedLockCodes is a plain in-memory property populated only by fetchSharedLockCodes(), which runs only on app-mode-change (effectively app launch); no persistence to UserDefaults/app-group/disk exists anywhere for lock codes. (2) The network layer is itself fail-open: offline, findSharedZoneByName() returns nil and the method returns ([], isConnected:false) WITHOUT throwing, and CKErrors during the record query are swallowed and return empty codes — so the cache ends up empty with error=nil. (3) canVerifyCode is !cachedLockCodes.isEmpty in child mode, and BlockedProfileView.editingDisabled requires canVerifyCode==true for the lock to apply; with an empty cache the save checkmark appears and saveProfile() performs no lock verification, so an offline child can edit/save a managed profile with no code. (4) The same fail-open gate protects Leave Family: ParentDashboardView.childNeedsPinCheck reduces to canVerifyCode in child mode (lockCodes is never populated for children), and ChildSettingsView.hasLockCode reads the in-memory CloudKitManager.sharedLockCodes, so an empty cache skips the PIN sheet entirely. (5) The comment at ParentDashboardView.swift:55 claiming offline-capable cached PIN verification is factually wrong. The only candidate mitigation, AuthorizationVerifier.verifyChildAuthorization(), does not fail closed — on success the flow proceeds to the non-throwing empty fetch; on network error the cache still stays empty. Severity as claimed: a child in Airplane Mode (or racing/failing the launch fetch) gets full edit access to parent-managed profiles and can leave the family without the PIN.

> [real=true, high] Reproduced the failure chain step by step. (1) The child-mode verification cache is in-memory only: LockCodeManager.cachedLockCodes is a plain array populated solely by a successful CloudKit fetch in fetchSharedLockCodes(); repo-wide grep shows no persistence of FamilyLockCode anywhere (only PIN-throttle counters are stored in UserDefaults), and CloudKitManager.sharedLockCodes is likewise a non-persisted @Published []. (2) On an offline cold launch the cache stays empty on every path: a network-failed child authorization leads to verifyIfNeeded(), which bails out because isConnectedToFamily is false at launch (no mode switch, cache []); if authorization succeeds, CloudKitNetworkService.fetchSharedLockCodes() does not throw offline — findSharedZoneByName() nil returns ([], false) and query errors are swallowed returning [] — so cachedLockCodes is set to []. (3) canVerifyCode is !cachedLockCodes.isEmpty in child mode, and BlockedProfileView.editingDisabled requires canVerifyCode for the managed-profile lock to apply, so with no active session editing is enabled and the save checkmark appears (line 650), letting the child strip blocked apps from a parent-managed profile without a code. (4) The same fail-open gate skips the Leave Family PIN: ParentDashboardView.childNeedsPinCheck is false (hasAnyLockCode is always false in child mode since fetchLockCodes guards != .child; canVerifyCode false), and ChildSettingsView.hasLockCode reads the empty in-memory sharedLockCodes and calls showLeaveShareUI() directly. (5) The comment at ParentDashboardView.swift:55 claiming cached codes 'work offline' is false across relaunches. This is a genuine fail-open parental-control bypass triggerable by airplane mode or any failed/raced fetch at launch.

## Suggested fix approach

Persist fetched lock-code hashes (they are already salted SHA-256) to app-group storage so verification works offline, and make the lock apply whenever profile.isManaged && mode == .child — distinguish 'parent cleared the code' (explicit empty fetch success) from 'codes unknown' (fetch failure), failing closed in the latter case.

This is a sketch, not a spec. Re-trace the defect yourself first (use the superpowers systematic-debugging skill), then design the minimal fix. If the fix touches sync, mode logic, or session lifecycle, check the App Modes table in AGENTS.md and `docs/codebase-analysis/deviation-report.md` for recorded design intent before changing behavior.

## Acceptance criteria

- The failure scenario above can no longer be reproduced by code inspection or test.
- A regression test exists in `FoqosTests` covering the scenario (naming: `testGivenX_WhenY_ThenZ`), where the defect is testable at unit level.
- No behavior change outside the defect's scope; all existing tests pass.
- swift-format clean; code review requested before merge (AGENTS.md requirement).

## Project conventions (mandatory — from AGENTS.md)

- Read `AGENTS.md` at the repo root before writing any code. It overrides everything else.
- Work on a feature branch off `main`. NEVER amend or force-push; new commits only. Request code review before merging.
- Views must use `@SafeQuery` (never raw `@Query`); non-query model arrays must be filtered with `.valid`.
- Lock-code restriction checks must use `appModeManager.currentMode == .child` — the pattern `!= .parent` is forbidden (it wrongly blocks Individual mode).
- Use `Log.<level>(_, category:)` instead of `print()`. Never log lock codes or personal identifiers.
- swift-format is enforced by a pre-commit hook (2-space indent, ~100-120 col).
- Tests: name `testGivenX_WhenY_ThenZ()`; pin time — capture one `let now = Date()` per test and inject via `now:` parameters.
- Run tests against an already-booted simulator by UUID (never by device name):
  `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty`

## Architecture context

- SwiftData + a CUSTOM CloudKit sync layer (SwiftData auto CloudKit sync is disabled, `cloudKitDatabase: .none`).
- Profiles sync same-user via `ProfileSyncManager` (private DB); lock codes sync parent->child via `FamilyCommand` (shared DB).
- Blocking is enforced via FamilyControls / ManagedSettings / DeviceActivity across the main app, the `FoqosDeviceMonitor` extension, `FoqosShieldConfig`, and `FoqosWidget`, sharing state through the `FoqosShared` package (app group `SharedData`).
- App modes: Individual / Parent / Child — see the mode table in AGENTS.md before touching any lock or mode logic.
