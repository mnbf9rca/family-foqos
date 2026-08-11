# XCTestDevices Growth Census Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect XCTestDevices growth around every gated child, fail when a new clone is attributable to the run's owned simulator, and warn on concurrent unattributed growth.

**Architecture:** The outer `xcode-stream.sh` process will stop `exec`-replacing itself with the gate and instead own a before/after census lifecycle. A validated `simctl --set <root> list devices --json` snapshot is captured before launch; EXIT, INT, and TERM traps always capture the second snapshot, compare newly observed UUIDs, and preserve the child status unless attributable growth or census failure requires a hard failure.

**Tech Stack:** Bash 4+, `xcrun simctl`, jq, the existing fake gate/simctl/xcodebuild shell harness.

## Global Constraints

- Run only one implementation/build/test stream on this machine.
- Preserve the exact child exit status when both censuses succeed and no owned clone appears.
- Run the after-census for success, failure, INT, and TERM exits.
- Fail loudly if the XCTestDevices root is missing, simctl fails, or census JSON is malformed.
- Match the full owned simulator display name as the terminal `of <owner>` chain segment so nested clones remain attributable without blaming a longer, prefixed session name.
- Warn, but do not blame or fail, when another stream causes only unattributed growth.
- Unit tests must use a fake XCTestDevices root and fake simctl inventory; they must not create real clones.
- Increment MARKETING_VERSION from 2.0.19 to 2.0.20 and CURRENT_PROJECT_VERSION from 38 to 39.

---

### Task 1: Add fail-closed XCTestDevices census fixtures

**Files:**
- Modify: `scripts/test-xcode-stream.sh`

**Interfaces:**
- Consumes: the existing fake `simctl`, fake `xcodebuild`, `reset_case`, `add_device`, and `run_wrapper` harness.
- Produces: fake `--set ROOT list devices --json` support and RED cases for owned, nested, unattributed, failed-child, interrupted-child, missing-root, simctl-error, and malformed-census behavior.

- [ ] **Step 1: Extend the fake device set**

Create `$CASE_ROOT/xctest-devices`, initialize `$CASE_ROOT/xctest-devices.json` to `{"devices":{}}`, and export:

```bash
IOS_SIM_GATE_XCTEST_DEVICES_ROOT="$CASE_ROOT/xctest-devices"
XCTEST_DEVICES_JSON="$CASE_ROOT/xctest-devices.json"
XCTEST_CENSUS_CALLS_FILE="$CASE_ROOT/xctest-census-calls"
```

Teach fake simctl to answer `--set "$IOS_SIM_GATE_XCTEST_DEVICES_ROOT" list devices --json`, increment the call counter, optionally fail on the requested call, and otherwise emit `$XCTEST_DEVICES_JSON`.

- [ ] **Step 2: Let the fake child create test-only clone records**

Before fake xcodebuild exits, when `XCODEBUILD_XCTEST_DEVICE_NAME` is set, append a record with `XCODEBUILD_XCTEST_DEVICE_UUID` and that name to `$XCTEST_DEVICES_JSON`. When `XCODEBUILD_INTERRUPT_PARENT=1`, send INT to `$PPID` after the record is written.

- [ ] **Step 3: Write the RED attribution cases**

Add cases asserting:

```bash
XCODEBUILD_XCTEST_DEVICE_NAME="Clone 1 of Family Foqos build2" \
  run_wrapper --agent build2 -- xcodebuild test
```

fails with an owned-clone diagnostic, and that `Clone 2 of Clone 1 of Family Foqos build2` is also classified as owned.

- [ ] **Step 4: Write RED failure and interrupt cases**

Force the child to add an owned clone and exit 23; assert the wrapper still emits the census diagnostic and exits nonzero. Force the child to add the clone and signal INT to its parent; assert the same diagnostic appears. Add a no-growth INT case that preserves status 130 and records exactly two censuses, proving the INT path performed the after-census.

- [ ] **Step 5: Write RED unattributed-growth and status-preservation cases**

Add `Clone 1 of Another Stream` during a successful child; assert status 0 and a loud warning. Also run a child that exits 23 without growth; assert status 23 remains unchanged.

- [ ] **Step 6: Write RED fail-loud census cases**

Assert a missing fake set root, malformed before JSON, and a fake simctl error on the second census all return nonzero with a census failure diagnostic. For preflight failures, assert the gate log is empty.

- [ ] **Step 7: Run the focused suite and record RED**

Run:

```bash
bash scripts/test-xcode-stream.sh
```

Expected: FAIL at the first owned-clone fixture because the current wrapper does not census XCTestDevices.

### Task 2: Implement the trapped census lifecycle

**Files:**
- Modify: `scripts/xcode-stream.sh`

**Interfaces:**
- Consumes: `IOS_SIM_GATE_XCTEST_DEVICES_ROOT`, `IOS_SIM_GATE_DEVICE_NAME`, the existing `simctl` adapter, and `$JQ_BIN`.
- Produces: `xctest_devices_census`, `new_xctest_devices`, and `finish_xctest_devices_census`, with the final gate invocation running under EXIT/INT/TERM traps.

- [ ] **Step 1: Add the configurable device-set root**

Define:

```bash
XCTEST_DEVICES_ROOT="${IOS_SIM_GATE_XCTEST_DEVICES_ROOT:-$HOME/Library/Developer/XCTestDevices}"
```

- [ ] **Step 2: Implement a validated census**

`xctest_devices_census` must require the root directory, call:

```bash
simctl --set "$XCTEST_DEVICES_ROOT" list devices --json
```

and use jq to reject anything except an object containing a `.devices` object whose values are arrays of records with string `udid` and `name` fields. Return a compact, UUID-sorted JSON array of `{udid,name}` records.

- [ ] **Step 3: Implement UUID-based growth comparison**

`new_xctest_devices BEFORE AFTER` must emit only after-records whose UUID did not occur in BEFORE. It must parse both snapshots using `--argjson` so malformed internal state fails rather than becoming an empty set.

- [ ] **Step 4: Implement the exit finalizer**

`finish_xctest_devices_census` must capture `$?` first, remove EXIT/INT/TERM traps, disable errexit for explicit handling, and obtain the after snapshot. It must classify an exact name or any clone chain ending in `of <full owner name>` as owned, while treating a longer prefixed session name as unrelated. It must:

```text
census failure -> print ERROR and exit 1
unattributed growth -> print WARNING and preserve child status
owned-name substring anywhere in new name -> print ERROR and exit 1
no growth -> preserve child status
```

Every jq failure during comparison or classification must print a detector failure and exit 1.

- [ ] **Step 5: Replace the final exec with trapped execution**

Take the before snapshot immediately before the gate child, then install:

```bash
trap 'exit 130' INT
trap 'exit 143' TERM
trap finish_xctest_devices_census EXIT
```

Run the gate without `exec`, with errexit disabled around it, capture its status, restore errexit, and `exit "$child_status"` so the EXIT finalizer always runs.

- [ ] **Step 6: Run the focused suite and record GREEN**

Run:

```bash
bash scripts/test-xcode-stream.sh
```

Expected: PASS, including owned/nested attribution, warning, failure, interrupt, and fail-loud census cases.

- [ ] **Step 7: Run static shell verification**

Run:

```bash
shellcheck scripts/xcode-stream.sh scripts/test-xcode-stream.sh
bash -n scripts/xcode-stream.sh scripts/test-xcode-stream.sh
git diff --check
```

Expected: all exit 0 with no diagnostics.

### Task 3: Version, review, and publish

**Files:**
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj`
- Modify: `docs/superpowers/plans/2026-08-11-issue-400-xctestdevices-census.md` only to mark executed checkboxes if useful during handoff.

**Interfaces:**
- Consumes: the tested census implementation and origin/main at merge `52e6929`.
- Produces: a signed, reviewed, merge-ready PR that closes #400.

- [ ] **Step 1: Apply the required version increment**

Replace every project setting value consistently:

```text
MARKETING_VERSION = 2.0.19 -> 2.0.20
CURRENT_PROJECT_VERSION = 38 -> 39
```

- [ ] **Step 2: Re-run fresh verification**

Run the focused suite, shellcheck, Bash syntax check, `git diff --check`, and:

```bash
scripts/check-version-increment.sh origin/main HEAD
```

after the signed commit exists. Expected version-gate output: 2.0.19 -> 2.0.20 and 38 -> 39.

- [ ] **Step 3: Request independent review**

Provide the reviewer base `52e6929`, head commit, this plan, the RED/GREEN evidence, and explicit attention points: EXIT/INT/TERM behavior, fail-closed errors, nested-name attribution, unrelated concurrent growth, and exact child-status preservation. Do not run Xcode builds in the reviewer stream.

- [ ] **Step 4: Publish merge-ready and close the issue through the PR**

Push the reviewed branch and open a ready PR whose body explains the effect-based invariant and includes `Closes #400`. Confirm all required GitHub checks pass, then hand the clean PR to the planner for merge.
