# Fastlane Bundle Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every Fastlane lane materialize its locked gems into an ignored worktree-local path instead of attempting to write Homebrew's immutable system gem directory.

**Architecture:** `scripts/fastlane.sh` keeps all existing no-side-effect prerequisite checks first, then unconditionally exports `BUNDLE_PATH=<repo>/vendor/bundle` and `BUNDLE_FROZEN=true`. It runs `bundle check`, bootstraps missing locked dependencies with `bundle install`, fails with a named nonzero error when installation fails, and only then enters the existing credential or direct lane route.

**Tech Stack:** Bash, Homebrew Ruby 4, Bundler 4, the existing shell regression harness.

## Global Constraints

- Keep PR #421 on `chore/412-xcbeautify-migration` in `/Users/rob/git/family-foqos/.worktrees/build1-412`.
- Never amend or force-push; the fix is a new signed commit and an ordinary push.
- Keep Homebrew Ruby, lane-specific xcbeautify, and lane-specific 1Password checks before any dependency installation.
- Never install gems into Homebrew or any other system directory.
- Set the shipped path unconditionally so an inherited `BUNDLE_PATH` cannot redirect lane installation.
- Keep credentials excluded from `bundle check` and `bundle install`.
- Honor `Gemfile.lock` with `BUNDLE_FROZEN=true`.
- `vendor/bundle/` remains ignored and no gem payload is committed.
- A failed installation must exit nonzero with a named Fastlane dependency-install diagnostic and must never execute a lane.
- Prove real materialization from an absent `vendor/bundle` before asking planner to rerun `verify_export`.

---

### Task 1: Bootstrap locked Fastlane gems inside the worktree

**Files:**
- Modify: `scripts/test-fastlane-credential-routing.sh`
- Modify: `scripts/fastlane.sh`
- Modify: PR #421 body after proof

**Interfaces:**
- Consumes: `Gemfile.lock`, Homebrew Ruby's `bundle`, lane-specific xcbeautify and `op` prerequisites, and the existing `scripts/fastlane.sh <lane> [arguments]` interface.
- Produces: `BUNDLE_PATH=<repo>/vendor/bundle`, `BUNDLE_FROZEN=true`, automatic locked dependency materialization, and unchanged lane argument/credential routing.

- [ ] **Step 1: Extend the fake Bundler into a behavioral boundary**

Change the fake `bundle` to append its arguments and environment to test logs, return `BUNDLE_CHECK_EXIT` from `bundle check`, return `BUNDLE_INSTALL_EXIT` from `bundle install`, and accept `--version` plus `exec`. Change the fake `op` to append its arguments and environment. Reset both logs once at the start of each `run_wrapper` invocation so one wrapper run preserves the complete call sequence.

Assert that a satisfied non-credential lane performs:

```text
bundle --version
bundle check
bundle exec fastlane lanes argument with spaces
```

Assert that a satisfied credential lane performs the first two bundle calls and then:

```text
op run --env-file <repo>/fastlane/asc.env -- bundle exec fastlane verify_export argument with spaces
```

For every observed bundle/op boundary, require literal environment values:

```text
BUNDLE_PATH=<repo>/vendor/bundle
BUNDLE_FROZEN=true
```

- [ ] **Step 2: Add missing-dependency and failure regressions**

With `BUNDLE_CHECK_EXIT=1`, assert a non-credential lane runs:

```text
bundle --version
bundle check
bundle install
bundle exec fastlane lanes
```

With both `BUNDLE_CHECK_EXIT=1` and `BUNDLE_INSTALL_EXIT=23`, invoke `verify_export` and assert a nonzero status, a diagnostic containing `Fastlane dependencies could not be installed`, and a call log ending after `bundle install` with no `op` or `bundle exec` call.

Retain and adapt the existing cases so a missing/unavailable xcbeautify or missing `op` still produces no bundle invocation. Run the wrapper with an inherited hostile `BUNDLE_PATH` and prove every boundary still receives the exact repo-local path.

- [ ] **Step 3: Run the harness and verify RED**

Run:

```bash
bash scripts/test-fastlane-credential-routing.sh
```

Expected: FAIL because the current wrapper neither exports the repo-local frozen environment nor calls `bundle check`/`bundle install`.

- [ ] **Step 4: Implement the minimal frozen bootstrap**

Compute the repository root once after Homebrew Ruby is selected:

```bash
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
```

After the existing lane-specific xcbeautify and `op` prerequisite checks, add:

```bash
export BUNDLE_PATH="$repo_root/vendor/bundle"
export BUNDLE_FROZEN=true

if ! command -v bundle >/dev/null 2>&1; then
  echo "Bundler is required. Reinstall Homebrew Ruby with: brew reinstall ruby" >&2
  exit 127
fi
if ! bundle --version >/dev/null 2>&1; then
  echo "Bundler is unavailable. Reinstall Homebrew Ruby with: brew reinstall ruby" >&2
  exit 1
fi

if ! bundle check >/dev/null 2>&1; then
  echo "Installing locked Fastlane dependencies in $BUNDLE_PATH" >&2
  if ! bundle install; then
    echo "Fastlane dependencies could not be installed in $BUNDLE_PATH" >&2
    exit 1
  fi
fi
```

Set the two Bundler environment variables before the version probe so every Bundler process is isolated. Preserve the existing final `op run ... bundle exec fastlane` and direct `bundle exec fastlane` routing.

- [ ] **Step 5: Run focused GREEN verification**

Run:

```bash
bash -n scripts/fastlane.sh
bash -n scripts/test-fastlane-credential-routing.sh
bash scripts/test-fastlane-credential-routing.sh
git diff --check
```

Expected: syntax, ordering, environment isolation, bootstrap, failure containment, routing, and diff checks all pass.

- [ ] **Step 6: Prove real empty-vendor materialization**

First confirm `vendor/bundle` is absent. Then run:

```bash
scripts/fastlane.sh lanes
```

Expected: the wrapper announces installation into this worktree's ignored `vendor/bundle`, Bundler installs the exact locked gems without touching Homebrew, and Fastlane lists lanes successfully. Then run the command again and confirm `bundle check` takes the no-install path. `git check-ignore -v vendor/bundle` must identify the existing ignore rule.

- [ ] **Step 7: Commit and verify the new head**

Create a new signed commit:

```bash
git add scripts/fastlane.sh scripts/test-fastlane-credential-routing.sh
git commit -S -m "build: isolate Fastlane bundle installation"
```

Run the complete PR suite, version gate, diff check, signature check, and the gated xcbeautify Debug build. Update the PR body to explain that the wrapper now ships the same isolated Bundler behavior used by the suite.

- [ ] **Step 8: Push and request a new proof run**

Push normally without force, verify PR #421's head OID equals local `HEAD`, and send planner the new signed head plus the unchanged worktree path. Planner reruns `scripts/fastlane.sh verify_export` from that exact head before independent review.
