# Verify UI Changes in the Simulator

Agents drive and inspect UI themselves using temporary, uncommitted tests. Run affected checks per PR and the full UI pass on both release-candidate simulator runtimes under [Agent Acceptance](development-workflow.md#agent-acceptance-runbooks).

## Prepare and Drive the UI

1. Start from a clean implementation head in your assigned feature worktree. Record `git rev-parse HEAD`, Xcode version, `IOS_SIM_GATE_RUNTIME_VERSION` from inside the gate, the checklist, and the simulator UUID. Use your stable `<agent>/collab` owner for every simulator operation; follow [Simulator Ownership](development-workflow.md#simulator-ownership).

2. Save byte-for-byte copies of every file you will temporarily edit outside the repository, alongside the driver and evidence. Add a throwaway, uncommitted `FoqosUITests/Manual<issue>Tests.swift`; use `XCUIApplication` to tap, hold, scroll, Save, reopen, and Duplicate through real views. Leave the existing screenshot tests and their five App Store captures intact. Assert the expected result, including rejected actions preserving state, rather than treating a successful tap as a pass.

3. Launch with `--screenshot-demo --demo-scenario <scenario>` using [ScreenshotTests.swift](../FoqosUITests/ScreenshotTests.swift) as the starting example. Existing scenarios include `profile-editor`, `home-active`, `parent-dashboard`, and `child-locked`. The demo uses an in-memory model store and synthetic selections; Save/reopen in one process proves that editor flow, not disk persistence or real Screen Time token preservation. For extra fixtures, temporarily edit `ScreenshotDemoSeeder`; runtime checks may need narrow changes in `FoqosApp`, `StrategyManager`, or the relevant callback surface. Put every temporary production hook inside `#if DEBUG` and behind `ScreenshotDemoMode.isActive` plus a dedicated launch argument. Enable only the path under test, retaining isolation from real CloudKit, restrictions, and monitoring. Record each bypass and restore every hook before committing.

Persistent V1 → V2 checks are the exception to demo seeding: use the [upgrade runbook](v1-v2-upgrade-runbook.md), its external UI runner and real disk containers. Never use `--screenshot-demo`, reseed V2, invoke migration/start/stop directly from tests, or dismiss an unexpected error to obtain a pass. Its dedicated Debug argument gates only documented unavailable boundaries.

4. Skip onboarding for an offline UI check through the demo seeder's existing preferences: `family_foqos_has_completed_onboarding = true`, `family_foqos_show_intro_screen = false`, and `family_foqos_show_mode_selection = false`. For an empty-Home/widget check, stage those preferences without profiles. Normal onboarding can fail its iCloud preflight in the simulator; bypassing it establishes no iCloud or authorization success. A locked Child fixture does not grant Child Screen Time authorization.

5. Establish preferences on every launch: the in-memory store does not reset `UserDefaults`. In #528/#530, hiding the habit tracker persisted into later runs; a missing `Hide` button or activity legend could be stale `family_foqos_show_habit_tracker`, not a layout bug. Set the required value in the temporary fixture or explicitly restore Show/Hide through the UI, assert the precondition, and restore any preferences the driver changes. Derive weekday order from `Calendar.current.firstWeekday` in the simulator test runner, matching the app's locale; do not assume the host's weekday order or hard-code a UK/US expectation. Record locale/timezone and derive clock expectations from the same settings.

## Run and Inspect

Use the UI scheme and select only your driver; substitute your owner/class and a new result-bundle path for each run. Keep `xcodebuild` immediately after `--`, supply no destination or DerivedData override, and save the wrapper's actual exit status with the log.

```bash
scripts/xcode-stream.sh --agent <agent> --session collab --xcbeautify -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FoqosScreenshots \
  -only-testing:FoqosUITests/ManualIssueTests \
  -resultBundlePath /private/tmp/ui-check-unique.xcresult
```

For deliberate red runs, add `-collect-test-diagnostics never` to avoid lengthy failure diagnostics; retain assertion output and screenshots. If collection has already stalled, use the ownership checks in [Test](development-workflow.md#test); completed XCTest output does not replace the command's exit status.

Wait for named elements with bounded `waitForExistence`/hittability checks and capture `app.debugDescription` on failure. Distinguish a wrong selector, off-screen control, or stale preference from an app failure. “Timed out waiting for AX loaded” before usable UI is infrastructure evidence, not a passed check; preserve it and rerun after owner-only recovery below. Do not silently skip a failing checklist row.

Attach screenshots with `XCTAttachment(screenshot: app.screenshot())` and `.keepAlways`, then export them:

```bash
xcrun xcresulttool export attachments \
  --path /private/tmp/ui-check-unique.xcresult \
  --output-path /private/tmp/ui-check-attachments
```

Open the exported images and inspect each claimed state, preferably with an independent screenshot review. Check visible wording, clipping, overlap, enabled controls, and full popover access at normal, largest, and smallest text sizes where relevant. Accessibility existence or a full label alone cannot prove visibility; compare frames against the scroll viewport intersected with the window and actually scroll to hidden content. Label evidence by checklist row and retain failed targeting runs separately from product regressions.

## Recover Only Your Simulator

Let your previous gated command exit first. For an AX-loaded timeout, run this reboot inside the same owner gate; replace `<agent>` with your assigned name. It checks tools and owner before changing state, uses only the gate-provided UUID, and stops on any failure. Never erase or reboot another stream's simulator, use the `booted` alias, or run these simulator commands outside the wrapper; if ownership or recovery fails, report the blocker to the orchestrator.

If shutdown reports that the device is already shut down after a failed recovery, remove only the shutdown line and rerun boot and bootstatus inside the same owner-gated snippet, or report the blocker; do not ignore unexpected errors.

```bash
ui_agent='<agent>'
scripts/xcode-stream.sh --agent "$ui_agent" --session collab -- /bin/bash -c '
  set -euo pipefail
  command -v xcrun >/dev/null || { echo "xcrun is required" >&2; exit 127; }
  [[ "${IOS_SIM_GATE_AGENT:-}" == "$1" && "${IOS_SIM_GATE_SESSION:-}" == collab ]] \
    || { echo "Simulator owner mismatch" >&2; exit 1; }
  : "${IOS_SIM_GATE_UDID:?Missing gate simulator UUID}"
  xcrun simctl shutdown "$IOS_SIM_GATE_UDID"
  xcrun simctl boot "$IOS_SIM_GATE_UDID"
  xcrun simctl bootstatus "$IOS_SIM_GATE_UDID" -b
' ui-reboot "$ui_agent"
```

## Restore and Report

Restore all temporary production files byte-for-byte from the saved copies, remove the throwaway UI source, and use `cmp` against each saved file plus `git diff --exit-code HEAD -- <all temporarily edited tracked paths>` before any commit. Inspect `git status --short` for untracked drivers and `git diff --check` for the intended change. Rerun the production Debug build and the change's required tests with the fixtures removed; stage only intended paths, never a blanket add. If the implementation head changes, rerun affected UI checks or state exactly which earlier head the evidence covers.

Send the orchestrator the tested head, simulator UUID/runtime/locale, checklist outcomes, wrapper exit status/test counts, result bundle and inspected screenshots, temporary bypasses and restoration proof, and exact remaining device rows. Simulator UI or injected callbacks cannot establish real Child authorization/shields, OS countdown/schedule delivery, physical NFC/system QR cold/warm routing, or two-device sync; retain genuinely device-only rows for the human’s one iOS 27 release-candidate TestFlight pass after all work merges, never per PR/slice, in [#506](https://github.com/mnbf9rca/family-foqos/issues/506), the [#509 RC checklist](https://github.com/mnbf9rca/family-foqos/issues/509#issuecomment-5968985898), [#515 schedule checks](https://github.com/mnbf9rca/family-foqos/issues/515), and [#536 route matrix](https://github.com/mnbf9rca/family-foqos/pull/536). Spoken purpose labels also do not prove VoiceOver activation; record [#529](https://github.com/mnbf9rca/family-foqos/issues/529) as a known unresolved failure, rather than another human test. Only the orchestrator can apply a human ruling that accepts a limitation.
