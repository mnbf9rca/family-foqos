# iOS Simulator Gate Adoption

**Date:** 2026-08-10
**Issue:** #362
**Status:** Approved by the planner on `adopt/ios-sim-gate`
**Scope:** Family Foqos simulator allocation, Xcode test/build entrypoints, Fastlane screenshots,
DerivedData cleanup, and agent guidance

## Problem

Family Foqos still documents one Xcode implementation stream per machine and exposes raw
`xcodebuild` commands. Its cleanup script deletes every matching DerivedData directory, and the
screenshots lane inventories and deletes XCTestDevices clones by display name. Those conventions
cannot safely support three concurrent Xcode/simulator streams.

The machine-wide `ios-sim-gate` is now installed at `~/.local/bin/ios-sim-gate`. It already owns
the three-slot semaphore, per-simulator locks, the registry, per-owner DerivedData paths, cleanup,
and child exit propagation. The repository must adopt that contract without duplicating the gate.
In particular, the repository still owns selecting or creating the simulator for an exact
`(project, agent, session)` owner and ensuring every simulator-using project command actually
consumes the environment exported by the gate.

This design supersedes the proposed repository-local lock implementation in
`2026-08-09-three-stream-concurrency.md`. That document remains useful historical context, but its
custom Ruby semaphore, coordinator-assigned simulator table, and XCTestDevices clone cleanup are
replaced by the standalone gate and this adoption shim.

## Constraints

- At most three Xcode/simulator streams run concurrently across the machine. The installed gate,
  not this repository, enforces that capacity.
- Every Family Foqos simulator build or test uses one repository entrypoint and one exact UUID.
  Device display names never establish ownership.
- The owner key is exactly `(project, agent, session)`, with project `family-foqos`. Reuse is only
  from the gate registry entry for that exact tuple.
- The default device type is `iPhone 17`; `IOS_SIM_GATE_DEVICE_TYPE` overrides it. The newest
  compatible installed iOS runtime is selected unless `IOS_SIM_GATE_RUNTIME` overrides it.
- Every direct `xcodebuild` receives the gate-exported UUID destination and DerivedData path plus
  `-parallel-testing-enabled NO` and `-disable-concurrent-destination-testing`.
- `scripts/fastlane.sh screenshots` is one gated unit for its entire process tree. Archive and
  upload lanes remain unchanged because they do not boot a simulator.
- Cleanup deletes only exact gate-owned paths or UUIDs. Wildcards and model/name-selected deletion
  are forbidden.
- Read-only work and read-only discovery do not consume a slot.
- The adoption must preserve the child command's exact exit status.
- The real acceptance run includes both the full `FoqosTests` suite and the screenshots lane.
- Session Credential Warm-up (#363) is deliberately outside this change.

## Options Considered

### 1. One generic admission wrapper plus a thin Fastlane bridge — selected

A shell entrypoint owns registry lookup/allocation and delegates the process tree to
`ios-sim-gate run`. Its internal dispatcher enforces direct `xcodebuild` arguments and supplies
the gate environment to the screenshot lane. This provides one documented path and one allocator
without rebuilding the machine-wide lock implementation.

Fastlane snapshot accepts an exact DerivedData path and xcodebuild arguments, but looks up a
simulator by display name and unconditionally invokes `xcrun simctl shutdown booted`. The bridge
therefore supplies a deterministic display name and exact runtime only as lookup keys. A tiny,
process-local `xcrun` adapter rewrites exactly:

```text
simctl shutdown booted
```

to:

```text
simctl shutdown <IOS_SIM_GATE_UDID>
```

Every other argument vector is passed to `/usr/bin/xcrun` unchanged. The adapter directory is
prepended to `PATH` only for the gated screenshot lane's process tree, so the caller's environment
is unchanged when the wrapper exits. If the adapter needs any second rewrite, implementation stops
for design review.

### 2. Separate test and screenshot wrappers

This makes each dispatcher smaller but duplicates registry resolution, allocation races, runtime
selection, and stale-device replacement. The duplicated lifecycle is more dangerous than the
small amount of command dispatch in option 1.

### 3. Keep Fastlane independent and only document raw gate commands

This produces the smallest diff, but it does not enforce one entrypoint, cannot guarantee snapshot
uses gate-owned DerivedData or no-clone flags, and leaves the global `shutdown booted` hazard.

## Design

### Public entrypoint

Add `scripts/xcode-stream.sh` with this interface:

```bash
scripts/xcode-stream.sh --agent <agent> [--session <session>] -- <command> [args...]
```

The wrapper uses absolute repository paths, a fixed project key of `family-foqos`, and Bash 4 to
invoke the installed gate. `--agent`, optional `--session`, device/runtime overrides, and the child
argument vector are validated before mutation. The public mode never accepts a caller-supplied
UUID; ownership and reuse come from the registry.

After resolution, public mode executes:

```text
ios-sim-gate run --project family-foqos --agent <agent> [--session <session>] \
  --udid <resolved-uuid> -- scripts/xcode-stream.sh __execute -- <command> [args...]
```

The gate exports `IOS_SIM_GATE_UDID`, `IOS_SIM_GATE_DESTINATION`,
`IOS_SIM_GATE_DERIVED_DATA_PATH`, `IOS_SIM_GATE_PROJECT`, `IOS_SIM_GATE_AGENT`, and optional
`IOS_SIM_GATE_SESSION`. The internal mode refuses to run without that complete contract.

For a direct `xcodebuild`, internal mode rejects any caller-provided `-destination`,
`-derivedDataPath`, `-parallel-testing-enabled`, or
`-disable-concurrent-destination-testing` argument. It then appends the exact gate values and both
no-clone flags and uses `exec`, preserving the xcodebuild status.

For `scripts/fastlane.sh screenshots`, internal mode exports the resolved simulator display name
and runtime version, prepends the committed adapter directory to that child's `PATH`, and execs the
lane. Other commands inherit the gate environment but receive no simulator-specific rewriting.
The documented simulator-using commands are direct xcodebuild and the screenshots lane.

### Registry-first allocation

The wrapper asks the gate to initialize and validate state, then reads the registry under the
gate's published registry format. It searches only for the exact project/agent/session tuple:

1. If that tuple owns an available CoreSimulator UUID, reuse it.
2. If it owns a missing or unavailable UUID, run exact-UUID deletion through
   `ios-sim-gate run`, then call `ios-sim-gate reconcile` to prune the registry entry. This waits
   for the simulator lock and cannot delete a sibling's device.
3. If the tuple has no usable UUID, resolve the requested device type and installed iOS runtime,
   create one simulator, and register its exact UUID.

Default runtime selection considers available iOS runtimes newest first and selects the first one
compatible with the requested device type. An explicit override resolves by exact identifier,
name, or version and fails closed if unavailable or incompatible.

Creation and registration are race-aware. If another invocation registers the same owner after
this invocation's lookup, the loser deletes only the UUID it just created, rereads the registry,
and reuses the winner. Any other registration failure also deletes only the newly created UUID and
returns nonzero. Display names are deterministic for diagnostics and Fastlane lookup, but no
ownership or cleanup decision reads the name.

### Fastlane screenshots

`Snapfile` and the screenshots lane fail closed unless the gate variables are present. They select
the wrapper-resolved display name/runtime, set snapshot DerivedData to
`IOS_SIM_GATE_DERIVED_DATA_PATH`, and pass both no-clone flags through `xcargs`. Snapshot's generated
destination resolves to the registered UUID; the lane checks that lookup before the test starts.

The old before/after XCTestDevices inventory and model-name deletion loop is removed. A compliant
screenshot run must create no `Clone N of ...` testing device, so there is nothing for the
repository to clean. Snapshot's one global `shutdown booted` call is constrained by the adapter to
the gate UUID. Tests pin both the one allowed rewrite and a negative case such as
`simctl shutdown <other-uuid>` passing through unchanged.

### Scoped DerivedData cleanup

`scripts/clean-build.sh` consumes `IOS_SIM_GATE_DERIVED_DATA_PATH`. It refuses an unset path, a
relative path, the gate DerivedData root itself, and any path outside the Family Foqos subtree:

```text
~/Library/Caches/ios-sim-gate/DerivedData/family-foqos/<agent>/<session>
```

It removes exactly that validated path. It has no wildcard and cannot reach another owner's
DerivedData.

### Agent guidance

`AGENTS.md` replaces the single-stream ban with these operational rules:

- up to three simulator/Xcode streams may run, subject to the machine-wide gate;
- all simulator builds/tests use `scripts/xcode-stream.sh` and UUID destinations;
- the no-clone flags are mandatory and injected by the wrapper;
- the screenshots lane uses the same wrapper around `scripts/fastlane.sh screenshots`;
- archive/upload lanes remain outside the simulator gate;
- read-only work is unrestricted, while writing streams still use disjoint worktrees/files; and
- clean-build is called only inside a gate-owned process with its exact DerivedData environment.

The Running Tests examples use the wrapper for the full suite and `-only-testing` selections.

## Testing and Acceptance

Shell tests use fake `ios-sim-gate`, `xcrun`, `xcodebuild`, and Fastlane commands to pin:

- exact-tuple reuse and no cross-owner borrowing;
- default and overridden device/runtime allocation;
- stale/unavailable replacement through the gate;
- registration-race cleanup of only the invocation-created UUID;
- rejection and injection of direct xcodebuild arguments;
- exact child status propagation;
- exact-match-only xcrun rewriting, including untouched negative cases;
- screenshot-only PATH scoping and Fastlane environment wiring; and
- exact-path clean-build validation.

Fastlane-focused tests verify the screenshot lane consumes the gate values and that the old clone
cleanup is absent. Existing script tests, `shellcheck`, RuboCop, and `git diff --check` remain green.

The real smoke records normal and XCTestDevices inventories before and after each run, then:

1. runs all `FoqosTests` once through `scripts/xcode-stream.sh`;
2. runs `scripts/fastlane.sh screenshots` once through the same entrypoint;
3. confirms both commands return zero and a synthetic nonzero harness proves exact status
   pass-through;
4. confirms the registry maps the exact owner tuple to the used UUID;
5. confirms the acquired slot is free after each process exits;
6. confirms no new `Clone N of ...` simulator exists; and
7. confirms the caller's `PATH` is byte-identical before and after the screenshot wrapper.

The PR is ready for review, says `Closes #362`, and explicitly notes that #363 is not included.
Review is requested through the AMQ thread `adopt/ios-sim-gate-review` before merge.
