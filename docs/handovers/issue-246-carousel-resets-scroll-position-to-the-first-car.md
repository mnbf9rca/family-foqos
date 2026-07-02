# Handover: Carousel resets scroll position to the first card whenever the profiles array changes

- **GitHub issue:** #246
- **Severity:** low
- **Domain:** views-primary
- **Primary location:** `Foqos/Components/BlockedProfileCards/BlockedProfileCarousel.swift:200`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

.onChange(of: profiles) { initialSetup() } (lines 200-202) unconditionally recomputes currentProfileId; with no active session and no startingProfileId it falls through to `currentProfileId = validProfiles.first?.id` (line 120), discarding the user's current page. The profiles array membership can change underneath the user at any time via background sync (profile created/deleted on another device) or after creating a profile locally. Additionally, HomeView never clears navigateToProfileId after a widget deep-link (HomeView.swift:257-262), so an old startingProfileId keeps hijacking the reset target.

## Failure scenario

User is browsing card 4 of 5 while a sync pull creates a profile deleted-then-restored from another device; the carousel instantly snaps back to card 1 (or to a profile they deep-linked to days earlier), losing their place mid-interaction.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Both halves of the claim are confirmed by the code. (1) BlockedProfileCarousel.swift:200-202 has `.onChange(of: profiles) { _, _ in initialSetup() }`, and `initialSetup()` (lines 102-121) unconditionally reassigns `currentProfileId`, which is the binding driving `.scrollPosition(id: $currentProfileId)` (line 166). In the browsing scenario the user can only swipe when no session is active (`.scrollDisabled(isBlocking)`, line 167), so priority 1 (activeSessionProfileId) is nil; with no startingProfileId it falls through to `currentProfileId = validProfiles.first?.id` (line 120), snapping the carousel back to card 1 regardless of where the user was. Nothing in initialSetup checks whether the current page is still valid. The trigger is real: BlockedProfiles is a SwiftData @Model (Hashable/Equatable by identity), so any membership change — a profile inserted or deleted by background sync (ProfileSyncManager.pullProfiles → SyncCoordinator.didReceiveSyncedProfiles → context.insert/context.delete + context.save at SyncCoordinator.swift:314/204) or a locally created profile — changes HomeView's @SafeQuery `profiles` array and fires the onChange. (2) The stale deep-link claim is also confirmed: HomeView's local `@State private var navigateToProfileId: UUID? = nil` (HomeView.swift:44) is assigned at line 259 in the onChange of navigationManager.navigateToProfileId and is never set back to nil anywhere (only NavigationManager.clearNavigation() clears the manager's copy, not HomeView's @State). It is passed as `startingProfileId` (line 190), so after any deep link, every subsequent profiles-array change resets the carousel to that old profile via priority 2 (lines 112-117) instead of card 1. No guard elsewhere prevents either behavior. Severity "low" (transient UI annoyance, no data loss) is appropriate.

## Suggested fix approach

In the profiles onChange handler, only correct currentProfileId when it no longer exists in validProfiles (keep the current page otherwise), and clear navigateToProfileId in HomeView after the carousel consumes it.

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
