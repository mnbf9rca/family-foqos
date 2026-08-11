# Script Dependency Preflights Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the remaining shell entrypoints refuse deterministically and name unavailable dependencies before doing work or touching shared state.

**Architecture:** Put command discovery at each script's real dependency boundary and add semantic discovery for Xcode- and Bundler-resolved tools. Keep hermetic tests independent of host `cktool` and `op` installations while proving production refusal ordering through fake-command effect logs.

**Tech Stack:** Bash, `xcrun`, Bundler, Fastlane, `xcpretty`, shell fixture suites.

## Global Constraints

- Work only on `fix/403-script-dependency-preflights`, forked from `main@52e6929b4bb098bd35819ba9715a6334c2ea940e`.
- Use discovery-only semantic probes: `xcrun --find cktool`, `bundle exec fastlane --version`, and `bundle exec xcpretty --version`.
- Do not pin Xcode, Ruby, Homebrew, gem-version, or executable installation paths.
- Missing executables return 127; an undiscoverable bundled tool or unresolved gem returns 1 and names the dependency.
- Run all dependency validation before substantive work or shared-state mutation.
- Preserve hermetic fake `xcrun` and `op` boundaries; the test suites must not require host installations of those tools.
- Preserve exact runtime child statuses through `check-prod-schema.sh` and `xcode-stream.sh`.
- Add exactly five terse Script Safety requirements to `AGENTS.md`.
- Advance all 12 project configurations from 2.0.19 (38) to 2.0.20 (39).
- Do not run a simulator build or test; the approved spec classifies this as a shell-only change.
- Do not amend or force-push. Obtain independent review before the planner merges.

---

### Task 1: Add RED semantic-refusal fixtures

**Files:**
- Modify: `scripts/test-check-prod-schema.sh`
- Modify: `scripts/test-xcode-stream.sh`
- Test: `scripts/test-check-prod-schema.sh`
- Test: `scripts/test-xcode-stream.sh`

**Interfaces:**
- Consumes: the schema suite's fake `xcrun`, the Xcode stream suite's fake `bundle`, and each suite's existing status/log helpers.
- Produces: `FAKE_CKTOOL_AVAILABLE`, `FAKE_XCRUN_LOG`, and `XCPRETTY_PREFLIGHT_EXIT` controls that prove refusal happens before export or simulator-gate access.

- [ ] **Step 1: Make fake `xcrun` distinguish discovery from export**

Replace the schema fixture's unconditional fake with argument-aware behavior:

```bash
cat >"$TEST_ROOT/bin/xcrun" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_XCRUN_LOG"
if [[ "${1:-}" == "--find" && "${2:-}" == "cktool" ]]; then
  [[ "${FAKE_CKTOOL_AVAILABLE:-1}" -eq 1 ]] || exit 1
  printf '/fake/cktool\n'
  exit 0
fi
[[ "${1:-}" == "cktool" && "${2:-}" == "export-schema" ]] || exit 64
if [[ "${FAKE_CKTOOL_EXIT:-0}" -ne 0 ]]; then
  exit "$FAKE_CKTOOL_EXIT"
fi
printf '%s\n' "${FAKE_SCHEMA:-}"
EOF
```

Pass `FAKE_XCRUN_LOG="$TEST_ROOT/xcrun.log"` to the copied production script in `run_gate`.

- [ ] **Step 2: Add the missing-cktool refusal case**

Before schema-success cases, truncate the fake log, set `FAKE_CKTOOL_AVAILABLE=0`, and assert:

```bash
[[ "$GATE_STATUS" -eq 1 ]]
[[ "$GATE_OUTPUT" == *"cktool"* ]]
if grep -F 'cktool export-schema' "$TEST_ROOT/xcrun.log" >/dev/null; then
  echo "FAIL: missing cktool reached schema export"
  exit 1
fi
```

- [ ] **Step 3: Add semantic `xcpretty` behavior to fake Bundler**

Teach `write_fake_xcpretty` to handle the probe independently from formatter execution:

```bash
if [[ "$*" == "exec xcpretty --version" ]]; then
  exit "${XCPRETTY_PREFLIGHT_EXIT:-0}"
fi
[[ "$*" == "exec xcpretty" ]] || exit 64
cat >"$XCPRETTY_INPUT_LOG"
exit "${XCPRETTY_EXIT:-0}"
```

Unset `XCPRETTY_PREFLIGHT_EXIT` in `reset_case`.

- [ ] **Step 4: Add the pre-gate formatter refusal case**

Use a fresh case with no registered simulator, force the semantic probe to return 19, and assert
the wrapper returns nonzero, names `xcpretty`, and leaves `$GATE_LOG` empty:

```bash
reset_case rejected-xcpretty-unavailable
set +e
output=$(XCPRETTY_PREFLIGHT_EXIT=19 run_wrapper \
  --agent build2 --session collab --xcpretty -- xcodebuild test 2>&1)
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *"xcpretty"* ]] ||
  fail "unavailable xcpretty must be named and rejected"
[[ ! -s "$GATE_LOG" ]] || fail "unavailable xcpretty reached the gate"
```

- [ ] **Step 5: Run both suites and verify RED for intended reasons**

Run:

```bash
bash scripts/test-check-prod-schema.sh
bash scripts/test-xcode-stream.sh
```

Expected: the schema suite fails because production never calls `xcrun --find cktool`; the Xcode
stream suite fails because production reaches the gate instead of invoking the semantic formatter
probe. Earlier cases must reach each new assertion.

- [ ] **Step 6: Commit the RED fixtures**

```bash
git add scripts/test-check-prod-schema.sh scripts/test-xcode-stream.sh
git commit -S -m "test: expose missing script dependency preflights"
```

### Task 2: Preflight schema and Fastlane dependencies

**Files:**
- Modify: `scripts/check-prod-schema.sh`
- Modify: `scripts/test-check-prod-schema.sh`
- Modify: `scripts/test-fastlane-credential-routing.sh`
- Modify: `scripts/test-fastlane-gates.sh`
- Test: all three modified shell test suites

**Interfaces:**
- Consumes: external-command names actually invoked by each script and the production `fastlane.sh` missing-`op` contract.
- Produces: established `required_commands` loops, semantic `cktool`/Fastlane probes, and effect-based refusal assertions.

- [ ] **Step 1: Add each command loop before setup work**

Use the established comment, array, `command -v` loop, named diagnostic, and exit 127. Lists:

```bash
# scripts/check-prod-schema.sh
required_commands=(dirname grep xcrun)

# scripts/test-check-prod-schema.sh
required_commands=(cat chmod cp dirname grep mkdir mktemp rm)

# scripts/test-fastlane-credential-routing.sh
required_commands=(cat chmod cp dirname mkdir mktemp rm sed)

# scripts/test-fastlane-gates.sh
required_commands=(bundle cat chmod dirname mkdir mktemp rm sed)
```

Keep each future-dependency comment immediately above its array.

- [ ] **Step 2: Add production `cktool` semantic discovery**

After command discovery and before resolving or reading the manifest:

```bash
if ! xcrun --find cktool >/dev/null 2>&1; then
  echo "Required Xcode tool not found: cktool" >&2
  exit 1
fi
```

Leave the existing `SCHEMA=$(xcrun cktool export-schema ...)` command substitution unchanged so
an export failure still returns its exact status.

- [ ] **Step 3: Strengthen the existing missing-`op` effect assertion**

Delete the prior command log before the missing-`op` case and assert it remains absent afterward.
This proves `scripts/fastlane.sh` refuses before invoking `bundle`, without requiring a host `op`.

- [ ] **Step 4: Add semantic Fastlane resolution before fixture creation**

After resolving `REPO_ROOT` but before `mktemp`, run the probe in the repository root:

```bash
if ! (cd "$REPO_ROOT" && bundle exec fastlane --version >/dev/null 2>&1); then
  echo "FAIL: required bundled executable unavailable: fastlane" >&2
  exit 1
fi
```

Run the later `bundle exec fastlane gates` call from `$REPO_ROOT` as well so discovery and use
share the same Bundler context.

- [ ] **Step 5: Run focused GREEN verification**

Run:

```bash
bash -n scripts/check-prod-schema.sh scripts/test-check-prod-schema.sh \
  scripts/test-fastlane-credential-routing.sh scripts/test-fastlane-gates.sh
bash scripts/test-check-prod-schema.sh
bash scripts/test-fastlane-credential-routing.sh
bash scripts/test-fastlane-gates.sh
```

Expected: syntax checks and suites return zero. The schema suite reports the retained distinct
export status; the credential suite proves no Bundler effect on missing `op`; the gate suite first
resolves Fastlane and then passes all lane cases.

- [ ] **Step 6: Commit schema and Fastlane preflights**

```bash
git add scripts/check-prod-schema.sh scripts/test-check-prod-schema.sh \
  scripts/test-fastlane-credential-routing.sh scripts/test-fastlane-gates.sh
git commit -S -m "fix: preflight schema and Fastlane dependencies"
```

### Task 3: Refuse unavailable `xcpretty` before simulator-gate access

**Files:**
- Modify: `scripts/xcode-stream.sh`
- Test: `scripts/test-xcode-stream.sh`

**Interfaces:**
- Consumes: public `--xcpretty`, Bundler command discovery, and the fake semantic probe from Task 1.
- Produces: exit 127 for missing `bundle`, exit 1 for unresolved `xcpretty`, and no gate effect for either refusal.

- [ ] **Step 1: Preserve the missing-Bundler distinction**

Replace the current generic `die` expression with an explicit named 127 failure before
`owner_args` and `gate status`:

```bash
command -v bundle >/dev/null || {
  echo "xcode-stream: bundle not found; --xcpretty requires bundle exec xcpretty" >&2
  exit 127
}
```

- [ ] **Step 2: Add semantic formatter resolution in the same pre-gate block**

```bash
bundle exec xcpretty --version >/dev/null 2>&1 ||
  die "xcpretty unavailable; run bundle install before using --xcpretty"
```

Do not move, call, or mutate `gate`, `REGISTRY`, simulator inventories, or owner state before these
checks.

- [ ] **Step 3: Run targeted GREEN verification**

Run:

```bash
bash -n scripts/xcode-stream.sh scripts/test-xcode-stream.sh
bash scripts/test-xcode-stream.sh
```

Expected: the suite's new semantic-refusal case passes with an empty gate log; existing exact
23/0 and 0/17 child/formatter status cases remain green.

- [ ] **Step 4: Commit the Xcode wrapper preflight**

```bash
git add scripts/xcode-stream.sh
git commit -S -m "fix: preflight xcpretty before simulator access"
```

### Task 4: Record policy and advance release metadata

**Files:**
- Modify: `AGENTS.md`
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj`
- Test: `scripts/test-check-version-increment.sh`

**Interfaces:**
- Consumes: maintainer principle and the approved five mechanical requirements.
- Produces: a terse Script Safety policy and release 2.0.20 (39) in every project configuration.

- [ ] **Step 1: Add the five-bullet Script Safety subsection**

State that scripts should be safe and deterministic, then require new or modified scripts to:

1. validate external dependencies preflight with `command -v` and a named nonzero failure before work or shared-state access;
2. fail closed when a check cannot run, input is unreadable, or output is unparseable;
3. propagate exact child exit status through pipelines and wrappers;
4. verify effects, not text forms, when an invariant matters; and
5. keep guards in build phases or scripts, never only Git hooks because API commits bypass hooks.

- [ ] **Step 2: Bump all project configurations**

Change every `MARKETING_VERSION = 2.0.19;` to `2.0.20` and every
`CURRENT_PROJECT_VERSION = 38;` to `39`. Do not change other project settings.

- [ ] **Step 3: Verify policy shape and version consistency**

Run:

```bash
scripts/test-check-version-increment.sh
rg -n "^## Script Safety|command -v|fail closed|exact child|verify effects|API commits" AGENTS.md
git diff --check
```

Expected: the version gate reports 2.0.19 to 2.0.20 and 38 to 39; the policy audit identifies one
heading and all five rules; the diff check is clean.

- [ ] **Step 4: Commit policy and version**

```bash
git add AGENTS.md FamilyFoqos.xcodeproj/project.pbxproj
git commit -S -m "docs: require safe deterministic scripts"
```

### Task 5: Verify, review, publish, and hand off

**Files:**
- Verify only: all files changed from `origin/main`.

**Interfaces:**
- Consumes: the exact committed head from Tasks 1–4.
- Produces: evidence for independent review, one non-draft green PR closing #403, and an urgent planner merge handoff.

- [ ] **Step 1: Run exact-head verification**

Run:

```bash
bash -n scripts/check-prod-schema.sh scripts/test-check-prod-schema.sh \
  scripts/test-fastlane-credential-routing.sh scripts/test-fastlane-gates.sh \
  scripts/xcode-stream.sh scripts/test-xcode-stream.sh
bash scripts/test-check-prod-schema.sh
bash scripts/test-fastlane-credential-routing.sh
bash scripts/test-fastlane-gates.sh
bash scripts/test-xcode-stream.sh
scripts/test-check-version-increment.sh
scripts/check-c2-guards.sh
scripts/check-sync-guards.sh
bundle exec ruby scripts/check-log-privacy.rb
git diff --check origin/main...HEAD
```

Expected: every command returns zero. No Xcode or simulator command runs.

- [ ] **Step 2: Freeze git and behavior evidence**

Record `HEAD`, `origin/main`, merge-base ancestry, commit list, clean status, diff stat, the
missing-cktool no-export proof, the missing-`op` no-Bundler proof, the unavailable-`xcpretty`
empty-gate proof, and the exact child-status regression results.

- [ ] **Step 3: Request independent read-only AMQ review**

Send the reviewer base/head SHAs, issue/spec/plan paths, RED/GREEN evidence, all verification
results, exit-code contract, version, and diff scope. Ask for Critical/Important/Minor findings and
READY yes/no. The reviewer must not mutate the shared files or run Xcode.

- [ ] **Step 4: Address findings with new commits**

Fix all Critical and Important findings without amending, rerun proportionate verification, and
request review of the new exact head. Do not merge.

- [ ] **Step 5: Push and open one ready PR**

Refresh `origin/main`, confirm it remains the reviewed ancestor, push
`fix/403-script-dependency-preflights`, and open a non-draft PR titled
`Preflight remaining script dependencies (#403)`. Include `Closes #403`, the 127/1 refusal split,
effect-order proofs, test evidence, and version 2.0.20 (39).

- [ ] **Step 6: Require green GitHub checks and hand off**

Verify the PR is OPEN, non-draft, MERGEABLE, based on `main`, pinned to the reviewed head, and has
no failing or pending required checks. Send an urgent AMQ todo with the PR URL and evidence to the
planner for merge. Never merge it locally.
