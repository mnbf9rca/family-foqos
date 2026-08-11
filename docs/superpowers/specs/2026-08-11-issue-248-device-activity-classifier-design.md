# Issue #248 Device Activity Classifier Design

## Goal

Make the on-screen device-activity diagnostics and copied Markdown classify the same live timer
activities and report profile matches consistently.

## Root cause

`DebugView` and `DeviceActivitiesDebugCard` each implement private copies of the same string
classification logic. The copies have drifted:

- `DebugView` recognizes break, stop-schedule, and bare-UUID schedule names but omits
  strategy timers.
- `DeviceActivitiesDebugCard` recognizes break, bare-UUID schedule, and strategy names but
  omits stop-schedule timers.

Both views consume the same `DeviceActivityCenter` names, so the same activity is reported
differently depending on whether the user reads the card or copies Markdown.

## Design

Add an app-level `DeviceActivityClassifier` in `Foqos/Utils`. This is diagnostics presentation
logic, so its display labels should not become public API in `FoqosShared` or affect the device
monitor's timer dispatch. `TimerActivityUtil` remains the runtime source of truth. The classifier
aligns with its seven-kind switch by referencing the same public activity ID constants instead of
duplicating identifier strings. A shared parser was considered and rejected for this hygiene PR
because it would widen `FoqosShared`'s public API across four targets solely for diagnostics.

The classifier returns one `Classification` containing:

- the user-facing type label; and
- the parsed profile UUID, when the name carries a valid UUID.

`Classification.matches(profileId:)` compares the parsed UUID with the requested profile. Both
debug consumers will create one classification per activity and use it for both the type and match
rows.

Recognize every activity kind dispatched by `TimerActivityUtil`:

1. `BreakDeadlineBackstopActivity.id:<uuid>` as `Break Deadline Backstop`;
2. `BreakTimerActivity.id:<uuid>` as `Break Timer`;
3. `OneMoreMinuteDeadlineBackstopActivity.id:<uuid>` as
   `One More Minute Deadline Backstop`;
4. `OneMoreMinuteTimerActivity.id:<uuid>` as `One More Minute Timer`;
5. `StopScheduleTimerActivity.id:<uuid>` as `Stop Schedule Timer`;
6. `StrategyTimerActivity.id:<uuid>` as `Strategy Timer`;
7. a bare UUID as `Schedule Timer`; and
8. everything else as `Unknown` with no profile match.

Prefix recognition requires the colon delimiter. A known prefix with an invalid UUID keeps its
known type label but has no parsed profile and cannot match any profile. This preserves useful
diagnostic information while making matching fail safe. A bare name must parse as a UUID to be a
schedule timer. A prefixed `ScheduleTimerActivity.id:<uuid>` branch is intentionally absent because
the current schedule registration format is the bare profile UUID.

Do not change scheduling, runtime dispatch, sync, or session lifecycle behavior.

## Verification

Add a focused table test covering every activity ID in `TimerActivityUtil`'s switch with its actual
registered name format and proving none classifies as unknown, plus unknown input, malformed known
input, and a different profile. Prove behavior changes fail before implementation, then make them
pass with the minimal utility and consumer replacement.

Run the focused classifier tests, the full suite, a Debug build, formatting, repository guards,
log privacy lint, and the strict version gate. Obtain independent review before opening the
undrafted PR.

## Delivery

Ship #248 as one PR from merged `main`, bumping version `2.0.9 (28)` to `2.0.10 (29)` if `main`
does not advance before publication. The planner owns merge and authorizes the next issue only
after this PR lands.
