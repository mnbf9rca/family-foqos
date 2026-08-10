# iOS Simulator Gate Adoption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Execute tasks
> sequentially in this worktree because Family Foqos permits only one build/test stream on this
> machine during adoption.

**Goal:** Make `scripts/xcode-stream.sh` the single Family Foqos entrypoint for simulator builds,
tests, and screenshots, backed by the installed machine-wide `ios-sim-gate`.

**Architecture:** A Bash shim resolves or creates the exact registry-owned CoreSimulator and then
execs the child through `ios-sim-gate run`. Its internal dispatcher enforces direct xcodebuild
arguments and supplies gate state to Fastlane. Fastlane snapshot uses the allocated device by a
lookup-only display name and a process-local `xcrun` adapter scopes snapshot's one global shutdown
to the gate UUID.

**Tech stack:** Bash 4, jq, CoreSimulator `simctl`, `ios-sim-gate` 0.1.0, Ruby/Fastlane 2.237.0,
Xcodebuild.

**Authoritative design:**
`docs/superpowers/specs/2026-08-10-ios-sim-gate-adoption-design.md` at commit `a8f38ac`.

## Global constraints

- Do not alter or reinstall `~/.local/bin/ios-sim-gate`.
- Do not run Xcode or a simulator outside the new shim after it exists.
- Never select registry ownership or cleanup targets by simulator display name.
- The xcrun adapter may rewrite only the exact argv `simctl shutdown booted`; all other argv must
  pass unchanged to `/usr/bin/xcrun`.
- The adapter PATH is local to the screenshot child process tree and must not persist afterward.
- Use simulator UUIDs, never device names, in xcodebuild destinations.
- Run all tasks sequentially; no second build/test process may overlap.
- Never force-push or amend. Request review before merge.

---

### Task 1: Specify shim allocation and xcodebuild enforcement

**Files:**
- Create: `scripts/test-xcode-stream.sh`
- Create later: `scripts/xcode-stream.sh`

**Interfaces:**
- `scripts/xcode-stream.sh --agent NAME [--session NAME] -- COMMAND [ARG ...]`
- Consumes optional `IOS_SIM_GATE_DEVICE_TYPE` and `IOS_SIM_GATE_RUNTIME`.
- Uses `IOS_SIM_GATE_BIN` and test-only command-path overrides only where needed for hermetic tests.

- [ ] Build a temporary fake home, registry, gate, `jq`, `xcrun`, and child recorder. Keep all
  simulator fixtures UUID-shaped so production validation is exercised.
- [ ] Assert an available registry UUID for the exact `(family-foqos, agent, session)` is reused
  and another owner's UUID is ignored.
- [ ] Assert no-session and named-session owners remain distinct.
- [ ] Assert the default allocation asks for iPhone 17 and the newest available iOS runtime; assert
  device/runtime overrides select their exact fixtures.
- [ ] Assert a missing or unavailable owned UUID is deleted only inside a gate run, reconciled,
  replaced, and registered.
- [ ] Assert a registration race deletes only the just-created loser and reuses the winner.
- [ ] In internal xcodebuild mode, assert caller destination/DerivedData/concurrency flags are
  rejected. Assert the wrapper injects the exact gate destination/path and both no-clone flags.
- [ ] Make the fake xcodebuild exit 23 and assert the public wrapper exits 23.
- [ ] Run `bash scripts/test-xcode-stream.sh` and observe RED because the shim is absent.

### Task 2: Implement the minimal registry-first shim

**Files:**
- Create: `scripts/xcode-stream.sh`
- Test: `scripts/test-xcode-stream.sh`

- [ ] Parse and validate public arguments, owner identifiers, command presence, and required
  dependencies. Resolve repository and installed-gate paths absolutely.
- [ ] Initialize/validate gate state, read only the exact owner tuple, and confirm reuse against
  `simctl list devices available --json`.
- [ ] For unusable ownership, run exact deletion under `ios-sim-gate run` and reconcile.
- [ ] Resolve device types and available iOS runtimes by identifier/name/version. Try default
  runtimes newest-first until `simctl create` succeeds; fail an explicit incompatible runtime.
- [ ] Register the new UUID. On owner-race failure, delete only the created UUID, reread the exact
  tuple, and reuse the winner; otherwise return the registration failure.
- [ ] Export lookup-only name/runtime values to the gated child and invoke the gate's `run` command.
- [ ] Implement internal mode validation and direct xcodebuild flag rejection/injection with
  `exec` status propagation.
- [ ] Run `bash -n scripts/xcode-stream.sh` and `bash scripts/test-xcode-stream.sh`; expect GREEN.

### Task 3: Specify and implement the exact-only xcrun adapter

**Files:**
- Extend: `scripts/test-xcode-stream.sh`
- Create: `scripts/ios-sim-gate-bin/xcrun`
- Modify: `scripts/xcode-stream.sh`

- [ ] Add RED cases with a recording real-xcrun substitute. Pin exactly one rewrite from
  `simctl shutdown booted` to `simctl shutdown $IOS_SIM_GATE_UDID`.
- [ ] Pin untouched negative cases: `simctl shutdown <other-uuid>`, `simctl list devices`, global
  flags preceding `simctl`, and arguments containing spaces.
- [ ] Pin failure when the gate UUID is missing.
- [ ] Pin screenshot dispatch prepends the adapter directory only in the lane child. Record the
  caller PATH before/after and assert byte equality.
- [ ] Implement the adapter with an overridable absolute real-xcrun path for tests and
  `/usr/bin/xcrun` in production. Use `exec` for both rewrite and pass-through.
- [ ] In shim internal mode, recognize only the repo's `scripts/fastlane.sh screenshots` command
  as the screenshot lane and prepend the adapter directory in that process environment.
- [ ] Run the shim test and shell syntax checks; expect GREEN.

### Task 4: Replace wildcard DerivedData cleanup

**Files:**
- Create: `scripts/test-clean-build.sh`
- Modify: `scripts/clean-build.sh`

- [ ] Write RED tests that create two fake owner directories. Assert the script deletes exactly
  `IOS_SIM_GATE_DERIVED_DATA_PATH` and preserves the sibling.
- [ ] Assert unset, relative, root-level, wrong-project, and traversal-like paths fail without
  deleting anything.
- [ ] Implement canonical absolute-prefix validation under
  `~/Library/Caches/ios-sim-gate/DerivedData/family-foqos/<agent>/<session>` and exact deletion.
- [ ] Run `bash scripts/test-clean-build.sh` and `bash -n scripts/clean-build.sh`; expect GREEN.

### Task 5: Wire Fastlane snapshot to the gate contract

**Files:**
- Create: `scripts/test-fastlane-sim-gate.sh`
- Modify: `fastlane/Snapfile`
- Modify: `fastlane/Fastfile`
- Verify: `scripts/test-fastlane-credential-routing.sh`

- [ ] Write a structural/behavioral RED test that loads the snapshot configuration with fake gate
  environment. Assert device name/runtime, DerivedData, and both no-clone xcargs come from the gate.
- [ ] Assert the screenshots lane fails closed without the gate contract and verifies Fastlane's
  name/runtime lookup resolves to `IOS_SIM_GATE_UDID`.
- [ ] Assert the old XCTestDevices inventory, model matching, and deletion loop are absent.
- [ ] Replace the fixed Snapfile device with required gate environment values. Add
  `derived_data_path`, `ios_version`, and exact no-clone `xcargs`.
- [ ] Replace the screenshot cleanup loop with a small gate-contract assertion before `snapshot`.
  Leave framing/output behavior unchanged.
- [ ] Run the new Fastlane gate test, credential routing test, `ruby -c fastlane/Fastfile`, and
  RuboCop on the modified Ruby file; expect GREEN.

### Task 6: Make agent policy and examples wrapper-only

**Files:**
- Extend: `scripts/test-xcode-stream.sh`
- Modify: `AGENTS.md`

- [ ] Add RED structural assertions for: three streams, wrapper-only simulator builds/tests,
  UUID-only destinations, mandatory no-clone flags, gated screenshots, scoped clean-build, and
  read-only work not consuming a slot.
- [ ] Replace the stale no-parallel rule. Preserve the one-implementation-stream restriction only
  for the current adoption session if necessary; the steady-state rule is gate capacity three.
- [ ] Replace direct build/test examples with `scripts/xcode-stream.sh --agent ...` invocations,
  including full-suite and single-test examples. Keep archive/upload lanes documented as unchanged.
- [ ] Run the shim test and `git diff --check`; expect GREEN.

### Task 7: Run all local verification before the real simulator smoke

**Files:** none expected

- [ ] Run all shell tests sequentially:

  ```bash
  scripts/test-check-prod-schema.sh
  scripts/test-fastlane-credential-routing.sh
  scripts/test-fastlane-gates.sh
  scripts/test-xcode-stream.sh
  scripts/test-clean-build.sh
  scripts/test-fastlane-sim-gate.sh
  ```

- [ ] Run `shellcheck` on every modified shell script and `bundle exec rubocop fastlane/Fastfile`.
- [ ] Run `ruby -c fastlane/Fastfile`, `git diff --check`, and inspect the complete diff.
- [ ] Confirm the fake exit-23 case, exact adapter negatives, and caller-PATH equality are visibly
  reported by the tests.

### Task 8: Run the required real FoqosTests smoke through the shim

**Files:** none expected

- [ ] Capture `ios-sim-gate status`, the registry entry, normal simulator inventory, testing-device
  inventory, and caller PATH before the run.
- [ ] Run the full test suite sequentially through the new entrypoint, for example:

  ```bash
  scripts/xcode-stream.sh --agent build2 --session adoption-tests -- \
    xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos
  ```

- [ ] Capture the wrapper exit code and post-run status/inventories. Confirm the owner maps to the
  used UUID, all gate slots are free, and no new `Clone N of ...` testing device exists.

### Task 9: Run the required real screenshots smoke through the shim

**Files:** screenshot output may be regenerated but should remain within existing repository rules

- [ ] With no overlapping Xcode process, capture the same gate/inventory/PATH baseline.
- [ ] Run:

  ```bash
  scripts/xcode-stream.sh --agent build2 --session adoption-screenshots -- \
    scripts/fastlane.sh screenshots
  ```

- [ ] Confirm exit zero, exact registry ownership, released slot, no new clone, and caller PATH
  byte equality. Confirm logs show snapshot used the allocated UUID and scoped DerivedData.
- [ ] If the xcrun adapter needs any behavior beyond the approved one rewrite, stop and report
  instead of broadening it.

### Task 10: Publish a ready PR and request review

**Files:** none expected

- [ ] Commit implementation as new signed commits; never amend.
- [ ] Verify commit signatures and clean branch status.
- [ ] Push `feat/362-sim-gate-adoption` and open a ready-for-review PR. The body must include
  `Closes #362`, smoke evidence, and an explicit note that #363 is not included.
- [ ] Request code review through AMQ thread `adopt/ios-sim-gate-review` before merge.
- [ ] Reply to planner thread `adopt/ios-sim-gate` with PR number and exact smoke evidence.

### Task 11: Close PR #378 simulator-isolation review findings

**Files:**
- Modify: `scripts/test-xcode-stream.sh`
- Modify: `scripts/xcode-stream.sh`
- Modify: `scripts/test-fastlane-sim-gate.sh`
- Modify: `fastlane/simulator_gate.rb`
- Modify: `scripts/test-clean-build.sh`
- Modify: `scripts/clean-build.sh`
- Modify: `AGENTS.md`

- [ ] Add behavioral tests proving every internal child receives the scoped xcrun adapter PATH,
  including a `bundle exec`-style command, while screenshot-only environment assertions remain
  scoped to `scripts/fastlane.sh screenshots`. Run the test and observe the current conditional
  adapter installation fail.
- [ ] Install the adapter PATH unconditionally immediately after validating the internal gate
  contract. Keep the exact three-argument adapter rewrite unchanged, then rerun the focused test.
- [ ] Add a Fastlane test with two simulators sharing the configured name/runtime and observe that
  the current first-match lookup accepts ambiguity. Require exactly one name/runtime match and
  require its UUID to equal the gate UUID, then rerun the focused test.
- [ ] Add a wrapper test with an unregistered simulator whose display name equals the exact planned
  owner name and observe a second simulator being created. Refuse allocation before `simctl create`
  when any simulator already has that display name, without deleting the orphan, then rerun the
  focused test.
- [ ] Add direct-mode tests for a later exact `xcodebuild` token, `OBJROOT=`, `SYMROOT=`,
  `BUILD_DIR=`, and `-xcconfig`; observe acceptance, extend the existing rejection loop, and rerun
  the focused test. Document that xcodebuild must be argv[0] after `--`, never mediated by
  `xcrun`, `env`, or a shell.
- [ ] Add a clean-build test whose cache root is supplied through `IOS_SIM_GATE_CACHE_HOME` and
  differs from `$HOME/Library/Caches/ios-sim-gate`; observe refusal, derive the trusted project root
  from that variable with the gate's existing default, and rerun the focused test.
- [ ] Run all shell and Ruby verification, then sequentially rerun the full FoqosTests gate smoke
  and screenshots gate smoke. Confirm exact exit status, released slots, unchanged XCTestDevices
  clone inventory, and caller PATH equality.
- [ ] Create a new signed commit, push without amend or force, request delta review on
  `adopt/ios-sim-gate-review`, and reply on `adopt/ios-sim-gate` with the new head SHA and evidence.
