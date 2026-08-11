# Wrapper-Owned Xcode Formatting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the supported `xcpretty` invocation preserve exact wrapper and `xcodebuild` failures without caller-managed `pipefail`.

**Architecture:** Add a narrow public `--xcpretty` option to `scripts/xcode-stream.sh` and forward it through the existing gate boundary to internal direct-`xcodebuild` execution. The internal Bash process owns the only formatter pipeline and returns the child's exact nonzero status first, falling back to the formatter status only after child success.

**Tech Stack:** Bash 4+, zsh regression harness, `ios-sim-gate`, `xcodebuild`, Bundler, `xcpretty`.

## Global Constraints

- Work only on `fix/379-xcode-stream-xcpretty`, forked from `main@55351b8a731dbcd9ab82b6c0cdd04bb48a0b4005`.
- Preserve the public wrapper's current `exec` into `ios-sim-gate` and every unformatted execution path.
- Accept `--xcpretty` only for a direct `xcodebuild` command and reject invalid use before gate mutation.
- Return the exact child status whenever the child fails; return the formatter status only when the child succeeds.
- Keep clean-build and screenshot commands unformatted and unchanged.
- Update canonical `AGENTS.md` examples in the same PR so callers never own the formatter pipeline.
- Advance all 12 configurations from 2.0.17 (36) to 2.0.18 (37).
- Do not start the upstream `mnbf9rca/ios-sim-gate` issue until the planner confirms this PR merged.
- Do not run implementation tasks in parallel; this repository reserves Xcode and simulator work for one stream at a time.

---

### Task 1: Add RED formatter-status regressions

**Files:**
- Modify: `scripts/test-xcode-stream.sh`
- Test: `scripts/test-xcode-stream.sh`

**Interfaces:**
- Consumes: existing `run_wrapper`, fake gate, fake simulator, and fake `xcodebuild` harnesses.
- Produces: fake `bundle exec xcpretty` behavior controlled by `XCPRETTY_EXIT`, captured formatter input at `XCPRETTY_INPUT_LOG`, and failing acceptance cases for the future public `--xcpretty` option.

- [ ] **Step 1: Extend the fakes without changing production code**

Add controllable output to fake `xcodebuild`:

```bash
[[ -z "${XCODEBUILD_STDOUT:-}" ]] || printf '%s\n' "$XCODEBUILD_STDOUT"
[[ -z "${XCODEBUILD_STDERR:-}" ]] || printf '%s\n' "$XCODEBUILD_STDERR" >&2
exit "${XCODEBUILD_EXIT:-0}"
```

Add a fake formatter at `$TEST_ROOT/bin/bundle` so the wrapper resolves it through the existing
test `PATH`:

```bash
#!/opt/homebrew/bin/bash
set -euo pipefail
[[ "$#" -eq 2 && "$1" == "exec" && "$2" == "xcpretty" ]] || exit 64
cat >"$XCPRETTY_INPUT_LOG"
exit "${XCPRETTY_EXIT:-0}"
```

In `reset_case`, truncate and export `$CASE_ROOT/xcpretty-input.log`, and unset
`XCPRETTY_EXIT`, `XCODEBUILD_STDOUT`, `XCODEBUILD_STDERR`, and `GATE_STATUS_EXIT`. Teach fake gate
`status` to exit `${GATE_STATUS_EXIT:-0}` after its existing status output.

- [ ] **Step 2: Add the fresh-zsh preflight failure test**

Use `zsh -f` so no startup file can enable `pipefail`, request the supported formatter option, and
assert exact status `29`:

```bash
reset_case formatted-preflight-status
set +e
GATE_STATUS_EXIT=29 zsh -f -c '
  PATH=$1:$PATH
  "$2" --agent build2 --session collab --xcpretty -- xcodebuild test
' _ "$TEST_ROOT/bin" "$WRAPPER"
status=$?
set -e
[[ "$status" -eq 29 ]] || fail "expected formatted preflight exit 29, got $status"
[[ ! -s "$XCPRETTY_INPUT_LOG" ]] || fail "formatter ran before gate preflight completed"
```

- [ ] **Step 3: Add exact pipeline-status and merged-output tests**

Reuse one registered fake simulator for each case, call the not-yet-implemented option, and pin:

```bash
XCODEBUILD_EXIT=23 XCPRETTY_EXIT=0 run_wrapper \
  --agent build2 --session collab --xcpretty -- xcodebuild test
# captured status must equal 23

XCODEBUILD_EXIT=0 XCPRETTY_EXIT=17 run_wrapper \
  --agent build2 --session collab --xcpretty -- xcodebuild test
# captured status must equal 17

XCODEBUILD_STDOUT='stdout marker' XCODEBUILD_STDERR='stderr marker' run_wrapper \
  --agent build2 --session collab --xcpretty -- xcodebuild test
assert_contains "$XCPRETTY_INPUT_LOG" "stdout marker"
assert_contains "$XCPRETTY_INPUT_LOG" "stderr marker"
```

Wrap the expected failures with the suite's existing `set +e`/capture/`set -e` pattern. Reset the
case between status pairs so logs and registry state cannot leak.

- [ ] **Step 4: Add the invalid-scope regression**

Assert `--xcpretty -- /usr/bin/true` exits nonzero, identifies the direct-`xcodebuild` requirement,
and records no `register` or `run` gate mutation.

- [ ] **Step 5: Run the shell suite and verify RED for the intended reason**

Run:

```bash
scripts/test-xcode-stream.sh
```

Expected: FAIL at the first `--xcpretty` case because the current public parser treats the new
option as invalid usage. Existing pre-option cases must reach that point successfully.

- [ ] **Step 6: Commit the RED tests**

```bash
git add scripts/test-xcode-stream.sh
git commit -m "Add failing formatter status tests for #379"
```

### Task 2: Implement wrapper-owned formatting

**Files:**
- Modify: `scripts/xcode-stream.sh`
- Test: `scripts/test-xcode-stream.sh`

**Interfaces:**
- Consumes: public `--xcpretty`, the existing `__execute` private mode, and direct `xcodebuild` argument injection.
- Produces: an internal `run_xcodebuild_with_xcpretty` path that returns child status first and formatter status second.

- [ ] **Step 1: Parse and validate the public option**

Add `--xcpretty` beside `--agent` and `--session`, update usage, and store a boolean. After capturing
the child command but before `gate status`, require `${command[0]##*/}` to equal `xcodebuild` when
the boolean is set:

```bash
[[ "$use_xcpretty" != true || "${command[0]##*/}" == "xcodebuild" ]] ||
  die "--xcpretty requires xcodebuild immediately after --"
```

- [ ] **Step 2: Forward a private formatting marker through the gate**

Build the internal child vector explicitly so the public wrapper still ends with `exec`:

```bash
internal_command=("$BASH4_BIN" "$SELF" __execute)
[[ "$use_xcpretty" != true ]] || internal_command+=(--xcpretty)
internal_command+=(-- "${command[@]}")

exec "$BASH4_BIN" "$GATE_BIN" run "${owner_args[@]}" --udid "$owned_uuid" -- \
  "${internal_command[@]}"
```

Update private dispatch to consume only that optional marker before the required `--` and pass a
boolean to `execute_internal`.

- [ ] **Step 3: Own the formatted direct-xcodebuild pipeline**

Keep existing validation and injected arguments, then branch at the final execution point. The
formatted branch disables `errexit` only around the pipeline, captures `PIPESTATUS` immediately,
restores `errexit`, and exits deterministically:

```bash
set +e
"$@" \
  -destination "$IOS_SIM_GATE_DESTINATION" \
  -derivedDataPath "$IOS_SIM_GATE_DERIVED_DATA_PATH" \
  -parallel-testing-enabled NO \
  -disable-concurrent-destination-testing \
  2>&1 | bundle exec xcpretty
statuses=("${PIPESTATUS[@]}")
set -e

((statuses[0] == 0)) || exit "${statuses[0]}"
exit "${statuses[1]}"
```

The unformatted branch retains the current `exec "$@" ...` statement byte-for-byte.

- [ ] **Step 4: Run targeted GREEN verification**

Run:

```bash
bash -n scripts/xcode-stream.sh scripts/test-xcode-stream.sh
scripts/test-xcode-stream.sh
```

Expected: syntax checks return zero and the suite ends with its PASS banner; the new exact status,
fresh-zsh, merged-output, invalid-scope, and policy cases all pass.

- [ ] **Step 5: Commit the implementation**

```bash
git add scripts/xcode-stream.sh
git commit -m "Own xcpretty status propagation for #379"
```

### Task 3: Canonicalize documentation and advance the version

**Files:**
- Modify: `AGENTS.md`
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj`
- Test: `scripts/test-check-version-increment.sh`

**Interfaces:**
- Consumes: the public `--xcpretty` syntax from Task 2.
- Produces: one safe documented formatted invocation and release 2.0.18 (37) in every configuration.

- [ ] **Step 1: Replace both canonical formatted examples**

Use this shape in Build & Test Commands and Build Output:

```bash
scripts/xcode-stream.sh --agent <agent> --session <session> --xcpretty -- \
  xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -configuration Debug build
```

Remove the preceding `set -o pipefail`, trailing `2>&1 | bundle exec xcpretty`, and wording that
assigns status preservation to the caller.

- [ ] **Step 2: Remove the obsolete policy-text expectation**

Delete `bundle exec xcpretty` from `scripts/test-xcode-stream.sh`'s `policy_requirements`. Do not
replace it with a `--xcpretty` source-text assertion: the behavioral regressions in Tasks 1 and 2
prove safe formatting, while human and independent review verify the documentation examples.

- [ ] **Step 3: Bump every target configuration**

Change all 12 `MARKETING_VERSION = 2.0.17;` entries to `2.0.18` and all 12
`CURRENT_PROJECT_VERSION = 36;` entries to `37`. Do not change any other project setting.

- [ ] **Step 4: Run documentation and version gates**

Run:

```bash
scripts/test-xcode-stream.sh
scripts/test-check-version-increment.sh
rg -n 'set -o pipefail|2>&1 \| bundle exec xcpretty' AGENTS.md
```

Expected: both scripts return zero; the version gate reports 2.0.17 to 2.0.18 and 36 to 37; the
`rg` audit finds no obsolete caller-owned formatting instruction and therefore returns 1 with no
matches.

- [ ] **Step 5: Commit docs and version**

```bash
git add AGENTS.md FamilyFoqos.xcodeproj/project.pbxproj scripts/test-xcode-stream.sh
git commit -m "Document safe formatted builds for #379"
```

### Task 4: Verify the exact committed head

**Files:**
- Verify only: all changed files

**Interfaces:**
- Consumes: Tasks 1–3 exact committed head.
- Produces: local evidence packet for independent review and PR publication.

- [ ] **Step 1: Run static and shell verification**

Run:

```bash
bash -n scripts/xcode-stream.sh scripts/test-xcode-stream.sh
shellcheck scripts/xcode-stream.sh scripts/test-xcode-stream.sh
for test_script in scripts/test-*.sh; do "$test_script"; done
swift-format lint --recursive .
scripts/check-c2-guards.sh
scripts/check-sync-guards.sh
scripts/check-version-increment.sh
bundle exec ruby scripts/check-log-privacy.rb
git diff --check origin/main...HEAD
```

Expected: every command returns zero. Record privacy file/site/annotation counts and confirm they
match the live baseline rather than changing any baseline file.

- [ ] **Step 2: Prove the real supported formatted build**

Run through the serialized gate with no outer pipeline and no caller `pipefail`:

```bash
scripts/xcode-stream.sh --agent build1 --session collab --xcpretty -- \
  xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -configuration Debug clean build
```

Expected: clean and build succeed; the generated app reports 2.0.18 (37).

- [ ] **Step 3: Run the full gated tests through the supported form**

```bash
scripts/xcode-stream.sh --agent build1 --session collab --xcpretty -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos
```

Expected: the complete current suite passes with zero failures.

- [ ] **Step 4: Freeze exact git evidence**

Record `HEAD`, `origin/main`, ancestry, commit list, status, diff check, and diff stat. The worktree
must be clean and `origin/main` must remain an ancestor.

### Task 5: Review, publish, and hand off

**Files:**
- No source changes unless review finds an issue.

**Interfaces:**
- Consumes: exact verified head and its evidence packet.
- Produces: one non-draft green PR closing #379 and an urgent planner merge handoff.

- [ ] **Step 1: Request independent read-only AMQ review**

Send the reviewer exact base/head SHAs, approved spec and plan paths, RED/GREEN evidence, exact
status-pair results, static gates, real build/test results, version, and diff scope. Ask for
Critical/Important/Minor findings and READY yes/no. The reviewer must not mutate files or run Xcode
concurrently.

- [ ] **Step 2: Address findings in new commits**

Fix every Critical or Important finding, do not amend or force-push, rerun proportionate
verification, and request review of the new exact head.

- [ ] **Step 3: Push and open the ready PR**

Refresh `origin/main`, confirm ancestry, push `fix/379-xcode-stream-xcpretty`, and open one
non-draft PR titled `Preserve formatted Xcode failures (#379)`. Include `Closes #379`, the exact
status contract, verification evidence, and version 2.0.18 (37).

- [ ] **Step 4: Wait for GitHub checks and hand off**

Require every check to complete successfully and verify the PR is OPEN, non-draft, MERGEABLE, and
pinned to the reviewed head/base. Send an urgent AMQ todo to the planner with the PR URL and exact
evidence. Do not merge it.

### Task 6: Share the settled design upstream after merge

**Files:**
- No local changes.

**Interfaces:**
- Consumes: planner confirmation that the Family Foqos PR merged and its final PR URL.
- Produces: exactly one issue on `mnbf9rca/ios-sim-gate`; no upstream code change or demand.

- [ ] **Step 1: Wait for planner merge confirmation**

Do not draft, preview, or file the upstream issue while the Family Foqos PR is open.

- [ ] **Step 2: File one terse upstream issue**

Use plain product language to describe how adopter-owned `| xcpretty` pipelines can mask a gate or
build failure in shells without `pipefail`, summarize the adopted wrapper-owned formatter and
exact-status rule, and link the merged Family Foqos PR as a reusable reference for adopters such
as making-tracks. State that adoption is the gate repository's decision.

- [ ] **Step 3: Report the upstream issue URL to the planner**

Send one AMQ status message with the issue URL and confirm no other upstream action was taken.
