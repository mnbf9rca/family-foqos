# Issue #255 Dead Child Authorization View Deletion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the unreachable Child Authorization Required screen and keep the privacy analyzer's
site floor accurate without changing application behavior.

**Architecture:** Remove the single SwiftUI file from the file-system-synchronized main-app source
root. Re-prove that no live symbol, string, target, schema, or persistence edge survives; lower the
privacy site floor by exactly the one preview log call deleted with the file. Do not change share
acceptance, authorization, app-mode, sync, schema, persistence, or session code.

**Tech Stack:** SwiftUI, Xcode file-system-synchronized groups, Ruby privacy analyzer, XCTest.

## Global Constraints

- One PR closes only #255.
- Branch from merged `main` at `e8d6b239e17b91afe2ea364447f7c13cb8addad9`, version 2.0.10 (29).
- Delete `Foqos/Views/Child/ChildAuthorizationRequiredView.swift`; do not edit `project.pbxproj`
  for source membership because the `Foqos` root is file-system synchronized.
- Add no source-layout test and do not refactor the share-role flow; the planner approved deletion
  evidence plus build/test as the regression proof.
- Lower `scripts/log-privacy-baseline.txt` from 503 to 502 in the same commit as the file deletion,
  with an explicit deliberate-removal commit note. Keep the annotation baseline at 0.
- Bump every target to 2.0.11 (30) if live main remains 2.0.10 (29).
- Run all Xcode commands through `scripts/xcode-stream.sh --agent build1 --session collab --` with
  caller `set -o pipefail` and `bundle exec xcpretty`.
- Never amend or force-push; request independent review before merge; planner owns merge.

---

### Task 1: Delete the unreachable view with deletion evidence

**Files:**

- Delete: `Foqos/Views/Child/ChildAuthorizationRequiredView.swift`
- Modify: `scripts/log-privacy-baseline.txt`

**Interfaces:**

- Consumes: Xcode's synchronized `Foqos` root and privacy floor 503.
- Produces: no `ChildAuthorizationRequiredView`/`SetupStepRow` implementation and privacy floor 502.

- [ ] **Step 1: Reconfirm the clean evidence baseline**

```bash
git status --short --branch
wc -l Foqos/Views/Child/ChildAuthorizationRequiredView.swift
ruby scripts/check-log-privacy.rb --root .
```

Expected: clean branch; 146 lines; privacy lint reports 233 files, 503 sites, 0 annotations.

- [ ] **Step 2: Delete the complete SwiftUI file**

Use `apply_patch` with a `Delete File` operation for:

```text
Foqos/Views/Child/ChildAuthorizationRequiredView.swift
```

Do not edit any share-acceptance or authorization file.

- [ ] **Step 3: Prove live symbols, triggers, and stringly paths are absent**

Run each search separately across production, tests, resources, scripts, and the project:

```bash
rg -n "ChildAuthorizationRequiredView|SetupStepRow" \
  Foqos FoqosWidget FoqosDeviceMonitor FoqosShieldConfig \
  Packages/FoqosShared/Sources FoqosTests FoqosUITests

rg -n "childAuthorizationFailed|setChildAuthorizationFailure|childAuthorizationRequired" \
  Foqos FoqosWidget FoqosDeviceMonitor FoqosShieldConfig \
  Packages/FoqosShared/Sources FoqosTests FoqosUITests

rg -n --hidden \
  --glob '*.swift' --glob '*.plist' --glob '*.pbxproj' --glob '*.json' \
  --glob '*.yml' --glob '*.yaml' --glob '*.sh' --glob '*.rb' \
  "ChildAuthorizationRequiredView\\.swift|Family Sharing Setup Required|To accept this invitation, this device must be set up as a child|Apple Family Sharing ensures only verified children" \
  Foqos FoqosWidget FoqosDeviceMonitor FoqosShieldConfig \
  Packages FoqosTests FoqosUITests FamilyFoqos.xcodeproj scripts .github
```

Expected: every search exits 1 with no live match. Documentation is excluded deliberately because
the issue handover, design, and plan preserve historical evidence.

- [ ] **Step 4: Prove the expected privacy-floor RED**

```bash
ruby scripts/check-log-privacy.rb --root .
```

Expected: exit 2 with `coverage shrank from 503 to 502`; totals must report exactly
`files_discovered=232 files_analyzed=232 sites_analyzed=502 annotations=0`. Any different delta must
be investigated before changing the floor.

- [ ] **Step 5: Lower only the deliberate site floor**

Change the sole line of `scripts/log-privacy-baseline.txt`:

```text
502
```

Leave `scripts/log-privacy-annotation-baseline.txt` unchanged at `0`.

- [ ] **Step 6: Prove privacy GREEN and deletion-only source scope**

```bash
ruby scripts/check-log-privacy.rb --root .
git diff --check
git diff --stat
git diff --name-status
```

Expected: privacy lint passes at 232 files / 502 sites / 0 annotations. The source delta is one
deleted Swift file; the only other implementation artifact is the one-line privacy floor change.
No `project.pbxproj`, schema, migration, persistence, share-flow, or authorization file is changed.

- [ ] **Step 7: Commit the deliberate deletion and floor change**

```bash
git add Foqos/Views/Child/ChildAuthorizationRequiredView.swift \
  scripts/log-privacy-baseline.txt
git commit -m "Delete dead child authorization view for #255" \
  -m "Deliberately lower the log-privacy site floor from 503 to 502 because the deleted preview contained one Log.debug call."
```

### Task 2: Apply the strict version bump

**Files:**

- Modify: `FamilyFoqos.xcodeproj/project.pbxproj`

**Interfaces:**

- Consumes: the current live-main marketing/build version.
- Produces: one consistent version above live main across every target configuration.

- [ ] **Step 1: Refresh main and confirm the version floor**

```bash
git fetch origin main
git show origin/main:FamilyFoqos.xcodeproj/project.pbxproj \
  | rg "MARKETING_VERSION =|CURRENT_PROJECT_VERSION =" \
  | sort -u
```

If main remains 2.0.10 (29), set every configuration to 2.0.11 (30). If main advanced, rebase and
choose both values strictly above the new floor before editing. Never amend prior commits.

- [ ] **Step 2: Update every target configuration mechanically**

Replace all occurrences:

```text
CURRENT_PROJECT_VERSION = 29;  -> CURRENT_PROJECT_VERSION = 30;
MARKETING_VERSION = 2.0.10;   -> MARKETING_VERSION = 2.0.11;
```

- [ ] **Step 3: Verify and commit the version bump**

```bash
rg -n "CURRENT_PROJECT_VERSION|MARKETING_VERSION" FamilyFoqos.xcodeproj/project.pbxproj
git diff --check
git add FamilyFoqos.xcodeproj/project.pbxproj
git commit -m "Bump version for #255 dead-code deletion"
scripts/check-version-increment.sh origin/main HEAD
```

Expected: every configuration is 2.0.11 (30), and the ref-based gate passes from 2.0.10 (29).

### Task 3: Verify, independently review, and publish

**Files:** none

**Interfaces:**

- Consumes: the complete #255 branch.
- Produces: a deletion-reviewed, undrafted, green PR handed to the planner.

- [ ] **Step 1: Repeat the deletion-evidence searches**

Repeat Task 1 Step 3 against the committed tree. Record that every live-code/resource/project search
exits 1 with no match and that only documentation retains the historical names.

- [ ] **Step 2: Run all static repository gates**

```bash
swift-format lint --recursive .
git diff --check origin/main...HEAD
scripts/check-version-increment.sh origin/main HEAD
scripts/check-c2-guards.sh
scripts/check-sync-guards.sh
ruby scripts/check-log-privacy.rb --root .
```

Expected: every command exits zero; privacy totals are exactly 232 files / 502 sites / 0
annotations.

- [ ] **Step 3: Run the full test suite**

```bash
set -o pipefail
scripts/xcode-stream.sh --agent build1 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  2>&1 | bundle exec xcpretty
```

Expected: all 1,223 tests pass with zero failures.

- [ ] **Step 4: Run the Debug build**

```bash
set -o pipefail
scripts/xcode-stream.sh --agent build1 --session collab -- \
  xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -configuration Debug build 2>&1 | bundle exec xcpretty
```

Expected: `Build Succeeded` with exit zero, proving synchronized source membership and all target
dependencies remain valid after physical deletion.

- [ ] **Step 5: Request deletion-focused independent review**

Send the reviewer the base/head SHAs, approved design, plan, historical trigger-removal diff at
`210ba4f`, all live-search results, five-root/test sweep, synchronized-target evidence,
V1/schema/persistence analysis, privacy RED/GREEN totals, exact diff, full tests, build, and static
gates. Review is read-only and must not run Xcode. Resolve every Critical or Important finding in
new commits and rerun affected checks.

- [ ] **Step 6: Publish and hand off**

Refresh `origin/main` immediately before push and revalidate ancestry/version. Push
`fix/255-delete-child-authorization-view`, open an undrafted PR that closes only #255, and explain
why no unit test was added. Wait for all CI checks to pass, then send the exact reviewed green head
to the planner. Do not merge and do not start #256 until the planner confirms #255 merged.
