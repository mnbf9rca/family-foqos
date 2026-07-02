# Handover: Orphaned meaningless 'Supported' key in main app Info.plist — debris from ITSAppUsesNonExemptEncryption removal

- **GitHub issue:** #259
- **Severity:** low
- **Domain:** structural-debt
- **Primary location:** `Foqos/Info.plist:17`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

Foqos/Info.plist lines 17-18 contain `<key>Supported</key><false/>`. Git history shows `ITSAppUsesNonExemptEncryption`/`<false/>` was removed from the plist (it now lives in build settings as INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO, pbxproj lines 850/904) but the adjacent stray 'Supported' key was left behind. 'Supported' is not a recognized Info.plist key; iOS ignores it.

## Failure scenario

No runtime effect today, but the bogus key ships in every build's Info.plist, can trigger App Store validation warnings about unrecognized keys, and misleads anyone auditing the plist into thinking something is deliberately marked unsupported.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] The bogus `Supported`/`<false/>` pair exists at Foqos/Info.plist:17-18, is not a recognized Apple Info.plist key, and is read by no code in the repo (grep for infoDictionary/forInfoDictionaryKey only finds CFBundle version lookups). ITSAppUsesNonExemptEncryption was confirmed moved to build settings (pbxproj:850, :904). One correction to the claim's narrative: git history shows `Supported` was NOT left behind by the encryption-key removal — it was added earlier in commit 5ed7d75 ("added live activity sessions"), apparently a mangled attempt at NSSupportsLiveActivities; the encryption key was added next to it later and then removed. The key is still genuine orphaned debris and the fix (delete the pair) is correct. Severity low is accurate: no runtime effect, only plist hygiene/audit confusion.

## Suggested fix approach

Delete the `<key>Supported</key><false/>` pair from Foqos/Info.plist.

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
