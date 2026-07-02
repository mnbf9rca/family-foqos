# Handover: Timer duration snap-to-preset can select 1440 minutes, producing a zero-length DeviceActivity interval so the timed session never auto-stops

- **GitHub issue:** #212
- **Severity:** high
- **Domain:** views-secondary
- **Primary location:** `Foqos/Components/Strategy/TimerDurationView.swift:21`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

maxMinutes is deliberately capped at 1439 ('23h 59m', line 16), but snapPoints (line 21) includes 1440 and snapThreshold is 10 (line 22). snapToNearestPreset() (lines 174-184) runs when the user releases the slider and sets durationMinutes to 1440 whenever the slider is within 10 minutes of the max (any value >= 1430). handleConfirm passes 1440 into StrategyTimerData; NFC/QR timer strategies (e.g. NFCTimerBlockingStrategy.swift:54) feed this into DeviceActivityCenterUtil.startStrategyTimerActivity, whose getTimeIntervalStartAndEnd (DeviceActivityCenterUtil.swift:414-426) reduces start/end to hour+minute components. now + 1440 minutes yields the exact same hour:minute as the start, so intervalStart == intervalEnd — a zero-length schedule that violates DeviceActivity's 15-minute-minimum interval. startMonitoring's thrown error is only logged at info level (DeviceActivityCenterUtil.swift:277), so no stop timer is registered.

## Failure scenario

User starts an 'NFC + Timer' profile, drags the duration slider to the far right (displays ~23h55m/24h), releases — the value silently snaps to 1440 — and confirms. The blocking session starts but the strategy stop timer fails to schedule (intervalStart == intervalEnd), so the session never ends at the selected duration; apps stay blocked indefinitely until the user manually scans a tag or uses emergency unblock.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] The claim's reachable trigger and broken outcome are confirmed with concrete code: snapToNearestPreset() sets durationMinutes to 1440 (beyond the deliberate 1439 cap) whenever the slider is released at >= 1430, and that value flows unvalidated through NFC/QR timer strategies into getTimeIntervalStartAndEnd, which collapses now and now+1440min to identical hour/minute DateComponents. One detail of the claimed failure mechanism is inaccurate per empirical testing on the iOS 26.5 simulator: DeviceActivity does NOT treat equal start/end components as a zero-length interval that makes startMonitoring throw intervalTooShort; DeviceActivitySchedule.nextInterval resolves it to a full 24h interval that starts one day in the future. Consequently the stop event (intervalDidEnd -> StrategyTimerActivity.stop) fires roughly 48 hours after session start instead of the selected 24 hours (and intervalDidStart re-activates restrictions at +24h). Since intervalDidEnd is the sole auto-stop mechanism for timer-strategy sessions (no in-app elapsed-time fallback exists), the user-visible defect stands as claimed in substance: a session started with the snapped 1440-minute duration does not end at the selected time and stays blocked ~a day longer, escapable only by manual NFC/QR unlock. The fix sketch (remove 1440 from snapPoints or clamp to maxMinutes) is correct. Real, high-severity wrong-blocking-behavior bug; only the never-stops/throw detail should be amended to stops-a-day-late (behavior could vary across iOS versions, but was verified on iOS 26.5).

> [real=true, high] The defect is real but the claimed internal mechanism is wrong. CONFIRMED steps: (1) snapToNearestPreset can set durationMinutes to 1440, exceeding the deliberate 1439 cap — snapPoints includes 1440, threshold 10, no clamp; slider values >=1430 snap to it; (2) 1440 flows unvalidated through handleConfirm → StrategyTimerData → NFC/QR timer strategies → startStrategyTimerActivity; (3) getTimeIntervalStartAndEnd(1440) produces intervalStart == intervalEnd hour/minute components. REFUTED step: I compiled a probe against the iOS simulator SDK and ran it in a booted simulator — DeviceActivity does NOT treat equal start/end as a zero-length schedule and startMonitoring does NOT throw intervalTooShort (the 5-minute control case DID throw intervalTooShort even without entitlements, proving the length check would have fired). Instead the framework interprets start==end as a 1440-minute interval but DEFERS it: nextInterval begins 24h in the future and ends 48h out, while a 1439-minute schedule begins immediately. ACTUAL failure: the user who snaps to 1440 gets a session whose only auto-stop path (monitor extension intervalDidEnd → StrategyTimerActivity.stop) fires at +48h instead of +24h — apps stay blocked for double the selected duration (not 'indefinitely'; manual NFC/QR unblock still works). Same file/line, same trigger, same fix (remove 1440 from snapPoints or clamp with min(closest, maxMinutes)), same 'wrong blocking behavior' category and high severity, but the description's 'zero-length interval / startMonitoring throws / never auto-stops' mechanism should be corrected to 'interval silently deferred 24h, session auto-stops 24h late'. Note the same 1440 value is also reachable via the Shortcuts intent path (StrategyManager.swift:355 allows duration == 1440), so a clamp in getTimeIntervalStartAndEnd would be the more complete fix.

## Suggested fix approach

Remove 1440 from snapPoints (or clamp snap results with min(closest, maxMinutes)); optionally validate in getTimeIntervalStartAndEnd that the computed interval is non-zero and log at error level when startMonitoring throws.

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
