# CI Version Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a tested pull-request check that requires both Xcode version settings to increase strictly from `main`.

**Architecture:** A repository-local Bash script owns extraction, validation, and comparison. A minimal GitHub Actions workflow checks out complete history and invokes the script with the pull request base/head SHAs; a fixture Git repository tests the script without Xcode.

**Tech Stack:** Bash, Git, GitHub Actions YAML, Xcode project text format

## Global Constraints

- Run no Xcode build or test for this zero-Xcode item.
- Require `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` to be unique across all project configurations.
- Require both head values to be strictly greater than their base values.
- Set this pull request uniformly to `MARKETING_VERSION = 2.0.1` and `CURRENT_PROJECT_VERSION = 20`.
- Do not add the optional sync guards or unit suite.
- Leave branch-ruleset configuration to the maintainer and document that follow-up in the PR.

---

### Task 1: Executable version comparison

**Files:**
- Create: `scripts/check-version-increment.sh`
- Create: `scripts/test-check-version-increment.sh`

**Interfaces:**
- Consumes: base Git ref as argument 1 and optional head Git ref as argument 2 (default `HEAD`)
- Produces: exit 0 only when both version settings are valid, uniform, and strictly increased

- [ ] **Step 1: Write the failing fixture test**

Create a temporary repository containing a minimal `FamilyFoqos.xcodeproj/project.pbxproj`, commit
base/head fixtures, invoke the production script, and assert pass/fail for increased, unchanged,
decreased, multi-digit, malformed, and inconsistent values.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash scripts/test-check-version-increment.sh`

Expected: FAIL because `scripts/check-version-increment.sh` does not exist.

- [ ] **Step 3: Implement the minimal comparison script**

Implement helpers with these contracts:

```bash
unique_setting_value <ref> <MARKETING_VERSION|CURRENT_PROJECT_VERSION>
version_is_greater <head-major.minor.patch> <base-major.minor.patch>
```

Read project contents with `git show "$ref:FamilyFoqos.xcodeproj/project.pbxproj"`, reject missing or
non-unique settings, validate formats, and exit nonzero unless both comparisons are strictly greater.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash scripts/test-check-version-increment.sh`

Expected: `PASS: version increment gate cases`

### Task 2: Pull-request workflow

**Files:**
- Create: `.github/workflows/version-gate.yml`
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `github.event.pull_request.base.sha` and `github.event.pull_request.head.sha`
- Produces: GitHub status check named `Version gate`

- [ ] **Step 1: Add the minimal workflow**

Use `pull_request` targeting `main`, `permissions: contents: read`, `actions/checkout@v4` with
`fetch-depth: 0`, and invoke:

```bash
scripts/check-version-increment.sh \
  "${{ github.event.pull_request.base.sha }}" \
      "${{ github.event.pull_request.head.sha }}"
```

- [ ] **Step 2: Increment this pull request's project versions**

Replace every project configuration's `MARKETING_VERSION = 2.0.0` with `2.0.1` and every
`CURRENT_PROJECT_VERSION = 19` with `20`, then verify each setting has exactly one unique value.

- [ ] **Step 3: Validate workflow structure and rerun script tests**

Run:

```bash
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/version-gate.yml")'
bash scripts/test-check-version-increment.sh
```

Expected: both commands exit 0 and the shell test prints its PASS marker.

### Task 3: Review-ready verification

**Files:**
- Verify: `.github/workflows/version-gate.yml`
- Verify: `scripts/check-version-increment.sh`
- Verify: `scripts/test-check-version-increment.sh`

**Interfaces:**
- Consumes: completed Tasks 1-2
- Produces: reviewable commit and draft pull request closing #321

- [ ] **Step 1: Run final zero-Xcode verification**

Run:

```bash
bash -n scripts/check-version-increment.sh scripts/test-check-version-increment.sh
bash scripts/test-check-version-increment.sh
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/version-gate.yml")'
```

Expected: all commands exit 0.

- [ ] **Step 2: Commit without amend/force**

```bash
git add .github/workflows/version-gate.yml scripts/check-version-increment.sh \
  scripts/test-check-version-increment.sh docs/superpowers/specs/2026-08-10-ci-version-gate-design.md \
  docs/superpowers/plans/2026-08-10-ci-version-gate.md
git commit -m "Add CI version increment gate"
```

- [ ] **Step 3: Publish and request review**

Open a draft PR that closes #321 and explicitly notes both the maintainer branch-ruleset follow-up
and the omitted optional rider. Send the PR to `reviewer` via AMQ before any merge.
