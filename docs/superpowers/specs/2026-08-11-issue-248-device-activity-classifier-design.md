# Issue #248 Device Activity Classifier Design

## Goal

Make the on-screen device-activity diagnostics and copied Markdown classify the same live timer
activities and report profile matches consistently.

## Root cause

`DebugView` and `DeviceActivitiesDebugCard` each implement private copies of the same string
classification logic. The copies have drifted:

- `DebugView` recognizes break, stop-schedule, schedule, and legacy schedule names but omits
  strategy timers.
- `DeviceActivitiesDebugCard` recognizes break, schedule, strategy, and legacy schedule names but
  omits stop-schedule timers.

Both views consume the same `DeviceActivityCenter` names, so the same activity is reported
differently depending on whether the user reads the card or copies Markdown.

## Design

Add an app-level `DeviceActivityClassifier` in `Foqos/Utils`. This is diagnostics presentation
logic, so its display labels should not become public API in `FoqosShared` or affect the device
monitor's timer dispatch.

The classifier returns one `Classification` containing:

- the user-facing type label; and
- the parsed profile UUID, when the name carries a valid UUID.

`Classification.matches(profileId:)` compares the parsed UUID with the requested profile. Both
debug consumers will create one classification per activity and use it for both the type and match
rows.

Recognize the approved formats in this order:

1. `BreakTimerActivity.id:<uuid>` as `Break Timer`;
2. `StopScheduleTimerActivity.id:<uuid>` as `Stop Schedule Timer`;
3. `ScheduleTimerActivity.id:<uuid>` as `Schedule Timer`;
4. `StrategyTimerActivity.id:<uuid>` as `Strategy Timer`;
5. a bare UUID as `Schedule Timer (Legacy)`; and
6. everything else as `Unknown` with no profile match.

Prefix recognition requires the colon delimiter and UUID parsing. This preserves all legitimate
formats while avoiding suffix-based matches on malformed names. Stop-schedule remains before
schedule as required by the issue contract.

Do not classify additional timer/backstop types in this PR, change scheduling, or change any
session lifecycle behavior.

## Verification

Add focused unit tests for all four prefixed formats, the legacy bare UUID, unknown input, and a
different profile. Prove the new tests fail before the classifier exists, then make them pass with
the minimal utility and consumer replacement.

Run the focused classifier tests, the full suite, a Debug build, formatting, repository guards,
log privacy lint, and the strict version gate. Obtain independent review before opening the
undrafted PR.

## Delivery

Ship #248 as one PR from merged `main`, bumping version `2.0.9 (28)` to `2.0.10 (29)` if `main`
does not advance before publication. The planner owns merge and authorizes the next issue only
after this PR lands.
