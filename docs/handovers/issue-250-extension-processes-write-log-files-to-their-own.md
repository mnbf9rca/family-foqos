# Handover: Extension processes write Log files to their own sandbox containers, so 'Export Logs' never includes extension logs

- **GitHub issue:** #250
- **Severity:** low
- **Domain:** widgets-extensions
- **Primary location:** `Packages/FoqosShared/Sources/FoqosShared/Log.swift:106`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

Log.logDirectory resolves to the current process's .applicationSupportDirectory, not the app-group container. FoqosDeviceMonitor logs extensively through Log (all TimerActivity classes use Log.info for schedule decisions like 'should not be active now'), but those entries land in the extension's private container. The app's Export Logs feature (Log.getLogFileURLs/copyLogFilesToStagingDirectory) reads only the main app's container, so the exact category of logs users need when reporting 'my schedule didn't fire' is silently missing from exported diagnostics.

## Failure scenario

A scheduled profile fails to start on a user's device; support asks for exported logs via Settings -> Diagnostics -> Export Logs; the export contains no .timer entries from the monitor extension (the only process that made the start/skip decision), making the report useless for diagnosing schedule enforcement.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] The claim survives refutation on all three legs. (1) Log file location is per-process: Log.logDirectory resolves via `.applicationSupportDirectory` in the current process's sandbox (Log.swift:106-118), not the app-group container. App extensions (FoqosDeviceMonitor) have their own sandbox containers, so their Log writes land in the extension's private Application Support/Logs directory, unreadable by the main app. The only app-group container usage in FoqosShared is SharedData.swift (`containerURL(forSecurityApplicationGroupIdentifier: "group.com.cynexia.family-foqos")`), which Log does not use. (2) The extension really does log through Log for the exact decisions in the failure scenario: DeviceActivityMonitorExtension.intervalDidStart/intervalDidEnd call TimerActivityUtil.startTimerActivity/stopTimerActivity, and ScheduleTimerActivity logs schedule decisions via Log.info with category .timer (e.g. "should not be active now", "not scheduled for today", "no schedule found" at ScheduleTimerActivity.swift:55-92). The extension's own top-level messages use a raw OSLog Logger, but all the TimerActivity decision logs go through Log and are file-persisted (fileLoggingEnabled = true). (3) Export reads only the main-app process's files: LogExportManager.createLogArchive calls Log.shared.copyLogFilesToStagingDirectory (LogExportManager.swift:42), and _getLogFileURLsUnsafe enumerates only foqos.log/foqos.N.log in the current process's logDirectory (Log.swift:284-301). LogExportManager runs in the main app (@MainActor, uses UIKit), so exported archives can never contain the monitor extension's .timer entries. No guard, sync mechanism, or alternate export path exists anywhere in the repo to bridge extension logs into the export. Severity "low" and the fix sketch (app-group container + per-process file names) are appropriate.

## Suggested fix approach

Base logDirectory on FileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.cynexia.family-foqos") with per-process file names (foqos-app.log, foqos-monitor.log) and have export enumerate all of them.

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
