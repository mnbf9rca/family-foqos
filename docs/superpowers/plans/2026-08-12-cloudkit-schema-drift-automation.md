# CloudKit Schema Drift Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace routine manual CloudKit searches with one fail-closed, read-only drift reporter
while making coding-agent and maintainer responsibilities explicit and walkthrough-tested.

**Architecture:** Add a standalone Bash reporter and hermetic Bash fixture suite. The reporter owns
five discovery families, compares normalized code to the independent manifest and the manifest to
the `.ckdb`, and suppresses only artifact-annotated intentional extras. The existing checker remains
a separate post-reconciliation gate.

**Tech Stack:** Bash, ripgrep, POSIX awk, `comm`, `sort`, Markdown, Xcode build settings

## Global Constraints

- The manifest stays hand-reconciled; the reporter never writes or regenerates it.
- Existing `check-cloudkit-schema-export.sh` behavior/output stays unchanged.
- Reporter owns source roots/files and patterns; the runbook owns none.
- Missing dependencies exit `127`; invalid report/input exits `2`; drift exits `1`; clean exits `0`.
- Clean output is exactly `OK: no CloudKit schema drift; 2 annotated exceptions suppressed.` for
  the current repository, with the number derived from valid annotations.
- Drift categories are C-locale sorted in fixed order: missing manifest, extra manifest, missing
  checked-in schema, extra checked-in schema, then `CloudKit schema drift detected.`
- Every discovery family has a known-positive removal control and every configured source path has
  a missing-path control.
- Section 1 is coding-agent-owned; section 2 says maintainer-only before its first action.
- Set all 12 Xcode build-setting pairs to version `2.0.25` / build `44`.
- No Xcode/simulator run: these scripts are standalone operator tooling, not build phases.
- New signed commits only. Never amend or force-push.
- Merge requires a verbatim deliberate-failure walkthrough transcript, reviewer READY/handoff, and
  maintainer usability sign-off.

---

### Task 1: Build the reporter and hermetic suite through RED/GREEN cycles

**Files:**
- Create: `scripts/report-cloudkit-schema-drift.sh`
- Create: `scripts/test-report-cloudkit-schema-drift.sh`

**Interfaces:**
- Consumes: configured Swift roots/files, `fastlane/required-prod-schema.txt`, and
  `Foqos/CloudKit/cloudkit-schema.ckdb`.
- Produces: stable stdout plus exit `0`, `1`, `2`, `127`, or an exact unexpected child status.
- Test seam: `CLOUDKIT_SCHEMA_REPO_ROOT` overrides repository root for disposable fixtures.

- [ ] **Step 1: Write the missing-reporter test and observe RED**

Create the harness preflight and cleanup:

```bash
#!/usr/bin/env bash
set -euo pipefail

required_commands=(cat chmod cp dirname mkdir mktemp rm shasum)
for required_command in "${required_commands[@]}"; do
  command -v "$required_command" >/dev/null || {
    echo "FAIL: required command not found: $required_command" >&2
    exit 127
  }
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORTER="$REPO_ROOT/scripts/report-cloudkit-schema-drift.sh"
TEST_ROOT=$(mktemp -d)
cleanup() { rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT

if [[ ! -x "$REPORTER" ]]; then
  echo "FAIL: CloudKit schema drift reporter is missing or not executable"
  exit 1
fi
```

Run `bash scripts/test-report-cloudkit-schema-drift.sh`.
Expected: exit `1` with the exact missing-reporter diagnostic.

- [ ] **Step 2: Add reporter dependency preflight and a missing-`rg` control**

Create the executable reporter with:

```bash
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

required_commands=(awk comm dirname mktemp rg rm sort)
for required_command in "${required_commands[@]}"; do
  command -v "$required_command" >/dev/null || {
    echo "Required command not found: $required_command" >&2
    exit 127
  }
done

REPO_ROOT="${CLOUDKIT_SCHEMA_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
```

Run `chmod +x scripts/report-cloudkit-schema-drift.sh`.

Add a harness case using `PATH=/usr/bin:/bin`; require exit `127` and
`Required command not found: rg`. Run and observe GREEN for this contract.

- [ ] **Step 3: Add every configured-path fixture/control and observe RED**

The reporter owns these arrays:

```bash
TYPE_SOURCE_ROOTS=(Foqos FoqosDeviceMonitor FoqosShieldConfig FoqosWidget)
FIELD_KEY_FILES=(
  Foqos/CloudKit/SyncModels.swift
  Foqos/CloudKit/ProfileSessionRecord.swift
)
RECORD_KEY_FILES=(
  Foqos/Models/DeviceHeartbeat.swift
  Foqos/Models/FamilyCommand.swift
  Foqos/Models/FamilyLockCode.swift
  Foqos/Models/FamilyMember.swift
)
FAMILY_ROOT_FILES=(
  Foqos/CloudKit/CloudKitNetworkService.swift
  Foqos/CloudKit/CloudKitNetworkService+Sharing.swift
)
```

Harness `reset_fixture` creates all four roots, eight exact files, manifest, and `.ckdb`.
An independent `CONFIGURED_PATHS` lists all 12 paths. Remove each one separately and require exit
`2` plus `Configured CloudKit source path is empty or unreadable: <absolute path>`.

Run before validation. Expected: RED because missing configured paths are not named/rejected.

- [ ] **Step 4: Implement path/artifact validation and observe GREEN**

Before `mktemp`, validate every configured source path as readable. Validate nonempty/readable:

```bash
MANIFEST_FILE="$REPO_ROOT/fastlane/required-prod-schema.txt"
SCHEMA_FILE="$REPO_ROOT/Foqos/CloudKit/cloudkit-schema.ckdb"
```

Artifact failures exit `2` with
`CloudKit schema input is empty or unreadable: <absolute path>`. Add missing/empty cases for both
artifacts and run until all path/input controls pass.

- [ ] **Step 5: Add the full positive discovery fixture and five anti-vacuity cases**

Fixture constructs include exactly one unique positive per family:

```swift
struct RequiredModel {
  static let recordType = "Required"
  enum FieldKey: String {
    case requiredField
  }
}

struct KeyedModel {
  static let recordType = "Keyed"
  enum RecordKey {
    static let keyedField = "keyedField"
  }
}

let literal = CKRecord(recordType: "FamilyRoot", recordID: recordID)
rootRecord["rootField"] = Date()
```

The manifest/schema contain normalized entries for `Required`, `Keyed`, `FamilyRoot`, and their
fields. Remove all constructs matching each family separately and require exit `2` with:

```text
CloudKit discovery family matched no parseable requirements: static-record-types
CloudKit discovery family matched no parseable requirements: literal-record-types
CloudKit discovery family matched no parseable requirements: field-key-cases
CloudKit discovery family matched no parseable requirements: record-key-constants
CloudKit discovery family matched no parseable requirements: family-root-subscript-keys
```

Run before discovery exists. Expected: RED on the first family diagnostic.

- [ ] **Step 6: Implement five discovery normalizers and observe GREEN**

Create a private temp directory after all validation, with an EXIT cleanup trap. Use `rg` with the
spec's exact patterns. Status `1` becomes the named family exit `2`; any `rg` status greater than
`1` propagates unchanged.

Normalize static/literal types directly. Use stateful POSIX `awk` for `FieldKey` and `RecordKey` so
each key associates with its current `recordType`; explicit raw values use the quoted value.
Normalize root subscripts under `FamilyRoot`. Reject discovered nonblank lines that cannot parse.
`sort -u` produces the code requirement set. Run until every anti-vacuity case is GREEN.

- [ ] **Step 7: Add annotation/structure fixtures and observe RED**

Clean fixtures include:

```text
# DRIFT-EXCEPTION manifest-only: RECORD TYPE "cloudkit.share"
RECORD TYPE "cloudkit.share"
```

```text
// DRIFT-EXCEPTION schema-only: RECORD TYPE DeprecatedFixture
RECORD TYPE DeprecatedFixture (
  oldField STRING
);
```

The `.ckdb` also includes the built-in share type, fixture blocks, `___` system fields, and `GRANT`
clauses. Require exact clean output:

```text
OK: no CloudKit schema drift; 2 annotated exceptions suppressed.
```

Add exit-`2` cases for malformed, duplicate, mismatched, and stale annotations; duplicate/malformed
manifest requirements; and unterminated schema blocks. Run before parsers exist and observe RED.

- [ ] **Step 8: Implement strict parsers/exceptions and observe GREEN**

Manifest parsing is a line-state machine. An exact manifest-only annotation must immediately
precede the identical unique requirement. Other content must be a unique normalized requirement.

Schema parsing emits record type/application fields, structurally skipping `___`, `GRANT`, comments,
and blanks while accepting the exact top-level `DEFINE SCHEMA` declaration. A schema-only annotation
must immediately precede its matching record block and records that block's full normalized set.
Unterminated or otherwise unexpected content outside record blocks exits `2`.

Require manifest exceptions to be present in raw `manifest - code`; require each schema exception's
record type in raw `schema - manifest`. Stale exceptions exit `2`. Count annotation records, not
suppressed block fields. Run until annotation/structure cases are GREEN.

- [ ] **Step 9: Add all four exact drift-direction tests and observe RED**

Require these independent exit-`1` outputs:

```text
MISSING from manifest: RECORD TYPE Required.newField
EXTRA in manifest: RECORD TYPE Required.removedField
MISSING from checked-in schema: RECORD TYPE Required.requiredField
EXTRA in checked-in schema: RECORD TYPE Required.unrequiredField
```

Each prints its line plus `CloudKit schema drift detected.`, never the clean summary. A mixed,
unsorted fixture requires fixed category ordering and C-locale sorting. Run and observe RED.

- [ ] **Step 10: Implement symmetric comparison/output and observe GREEN**

Use sorted `comm` sets:

```text
code - manifest    => MISSING from manifest
manifest - code    => raw EXTRA in manifest
manifest - schema  => MISSING from checked-in schema
schema - manifest  => raw EXTRA in checked-in schema
```

Subtract only validated exception entries/blocks from raw extras. Print nonempty categories in the
fixed order and exit `1`; otherwise print the one-line summary using the derived annotation count.

- [ ] **Step 11: Prove child status, input byte identity, cleanup, syntax, and lint**

Add a fake `rg` returning `42` and require exit `42`. Capture `shasum` for every fixture input before
clean/drift runs and prove identical hashes afterward. Prove no new file appears under the fixture.

Run:

```bash
bash scripts/test-report-cloudkit-schema-drift.sh
bash -n scripts/report-cloudkit-schema-drift.sh scripts/test-report-cloudkit-schema-drift.sh
shellcheck scripts/report-cloudkit-schema-drift.sh scripts/test-report-cloudkit-schema-drift.sh
git diff --check
```

Expected: all exit `0`; harness ends `PASS: CloudKit schema drift reporter cases`.

- [ ] **Step 12: Commit the reporter vertical slice**

```bash
git add scripts/report-cloudkit-schema-drift.sh scripts/test-report-cloudkit-schema-drift.sh
git commit -S -m "Automate CloudKit schema drift reporting"
```

### Task 2: Integrate the real manifest and `.ckdb` exceptions

**Files:**
- Modify: `fastlane/required-prod-schema.txt:1-12,125`
- Modify: `Foqos/CloudKit/cloudkit-schema.ckdb:22-23`
- Verify: reporter, new suite, existing checker/suite

**Interfaces:**
- Consumes: Task 1 annotation grammar.
- Produces: a real clean baseline with two exercised annotations and unchanged inventory.

- [ ] **Step 1: Run the reporter against the unannotated repository and observe RED**

Run `bash scripts/report-cloudkit-schema-drift.sh`.
Expected: exit `1` for built-in share as extra manifest intent and deprecated `FamilyPolicy` as
extra checked-in schema intent. This proves exceptions are artifact policy, not reporter names.

- [ ] **Step 2: Add the two exact annotations**

Before the share requirement:

```text
# DRIFT-EXCEPTION manifest-only: RECORD TYPE "cloudkit.share"
```

Before the deprecated FamilyPolicy block, beside its human comment:

```text
// DRIFT-EXCEPTION schema-only: RECORD TYPE FamilyPolicy
```

Remove the five discovery-command comments from the manifest header. Retain its independent-oracle,
date, and descriptive-count comments. Do not change a record/field requirement.

- [ ] **Step 3: Run real integration checks and observe GREEN**

```bash
bash scripts/report-cloudkit-schema-drift.sh
bash scripts/test-report-cloudkit-schema-drift.sh
bash scripts/check-cloudkit-schema-export.sh
bash scripts/test-check-cloudkit-schema-export.sh
```

Expected: exact two-suppression summary; existing checker output remains unchanged; suites pass.

- [ ] **Step 4: Prove requirement inventories are unchanged and commit**

Normalize noncomment manifest requirements and `.ckdb` record/application fields before/after the
change; require identical sorted sets. Then:

```bash
git add fastlane/required-prod-schema.txt Foqos/CloudKit/cloudkit-schema.ckdb
git commit -S -m "Annotate intentional CloudKit schema exceptions"
```

### Task 3: Replace the manual runbook and bump release metadata

**Files:**
- Modify: `docs/cloudkit-production-schema.md:10-76`
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj:706-1215`

**Interfaces:**
- Consumes: reporter/checker from Tasks 1-2.
- Produces: five-step agent workflow, upfront maintainer workflow, version `2.0.25` / build `44`.

- [ ] **Step 1: Rewrite section 1 with exactly five agent actions**

Heading:

```markdown
## 1. Routine Schema Change — Coding Agents
```

State that coding agents normally execute this inside the schema-changing PR and humans do not run
discovery searches. Steps: change code; run reporter and stop on nonzero; hand-reconcile only
reported manifest/`.ckdb` differences until reporter says OK; run existing checker; include changes
and successful outputs in PR. Remove every source filename, regex, count, and ripgrep command.

- [ ] **Step 2: Label section 2 maintainer-only and add reporter preflight**

Heading:

```markdown
## 2. Release Promotion — Maintainer Only
```

First sentence says only the maintainer executes it. Add reporter before the existing checker and
production harness. Preserve Console **Deploy Schema Changes**, authenticated
`Production schema OK.`, tracking issue, and Fastlane beta/release stop conditions.

- [ ] **Step 3: Validate audience/command structure and absence of hardcoding**

Assert headings, reporter/checker, Console action, postflight, and Fastlane commands. Require this
search to return no matches:

```bash
rg -n 'static let recordType|CKRecord\(recordType|enum FieldKey|enum RecordKey|rootRecord|SyncModels\.swift|ProfileSessionRecord\.swift|DeviceHeartbeat\.swift|[0-9]+ active types|[0-9]+ fields' docs/cloudkit-production-schema.md
```

- [ ] **Step 4: Update/validate every version pair**

Change `2.0.24` to `2.0.25` and build `43` to `44` everywhere in the pbxproj. Run:

```bash
! rg -n 'MARKETING_VERSION = 2\.0\.24|CURRENT_PROJECT_VERSION = 43' FamilyFoqos.xcodeproj/project.pbxproj
test "$(rg -c 'MARKETING_VERSION = 2\.0\.25;' FamilyFoqos.xcodeproj/project.pbxproj)" -eq 12
test "$(rg -c 'CURRENT_PROJECT_VERSION = 44;' FamilyFoqos.xcodeproj/project.pbxproj)" -eq 12
```

- [ ] **Step 5: Run focused gates and commit**

Run reporter/new suite, real checker/existing suites, Bash syntax, ShellCheck, doc assertions,
version matrix, and `git diff --check`. Then:

```bash
git add docs/cloudkit-production-schema.md FamilyFoqos.xcodeproj/project.pbxproj
git commit -S -m "Clarify CloudKit schema workflow ownership"
```

### Task 4: Verify, walkthrough literally, review, and publish

**Files:**
- Verify: all Task 1-3 files
- Temporary only: scratch worktree/branch with `SyncedProfile.walkthroughSchemaField`
- PR body: complete labeled command/output transcript

**Interfaces:**
- Consumes: final feature head and exact section 1.
- Produces: fresh verification, deliberate-failure transcript, reviewer handoff, maintainer sign-off,
  and non-draft PR for planner merge.

- [ ] **Step 1: Run the fresh full gate**

```bash
bash scripts/test-report-cloudkit-schema-drift.sh
bash scripts/report-cloudkit-schema-drift.sh
bash scripts/test-check-cloudkit-schema-export.sh
bash scripts/check-cloudkit-schema-export.sh
bash scripts/test-check-prod-schema.sh
bash -n scripts/report-cloudkit-schema-drift.sh scripts/test-report-cloudkit-schema-drift.sh \
  scripts/check-cloudkit-schema-export.sh scripts/test-check-cloudkit-schema-export.sh \
  scripts/test-check-prod-schema.sh
shellcheck scripts/report-cloudkit-schema-drift.sh scripts/test-report-cloudkit-schema-drift.sh \
  scripts/check-cloudkit-schema-export.sh scripts/test-check-cloudkit-schema-export.sh \
  scripts/test-check-prod-schema.sh
git diff --check origin/main...HEAD
test -z "$(git status --short)"
git log --show-signature --format='%h %G? %s' origin/main..HEAD
```

Expected: all exit `0`, real reporter shows two exceptions, worktree clean, good signatures.

- [ ] **Step 2: Create a validated throwaway walkthrough worktree**

From outside the feature worktree:

```bash
WALKTHROUGH_PARENT=$(mktemp -d)
WALKTHROUGH_PATH="$WALKTHROUGH_PARENT/schema-walkthrough"
WALKTHROUGH_BRANCH="scratch/cloudkit-schema-walkthrough-$(date -u +%Y%m%dT%H%M%SZ)"
git worktree add "$WALKTHROUGH_PATH" -b "$WALKTHROUGH_BRANCH" HEAD
```

Do not commit/push the scratch field or run Xcode.

- [ ] **Step 3: Execute section 1 word for word and record the failure loop**

1. Add `case walkthroughSchemaField` to `SyncedProfile.FieldKey`.
2. Run reporter. Capture exit `1` and label **DELIBERATE FAILURE DEMONSTRATION**. It must print
   `MISSING from manifest: RECORD TYPE SyncedProfile.walkthroughSchemaField`. Stop.
3. Add only that manifest requirement; rerun. It must print
   `MISSING from checked-in schema: RECORD TYPE SyncedProfile.walkthroughSchemaField`. Stop.
4. Add `walkthroughSchemaField STRING,` to `SyncedProfile` in `.ckdb`; rerun. It must print the exact
   clean summary.
5. Run the existing checker; it must exit `0` with unchanged success lines.

Capture every command, output, and status. Any undocumented deviation is a defect: discard scratch,
fix docs/tooling in a new signed commit, rerun full gate, and restart from a fresh scratch branch.

- [ ] **Step 4: Discard only authorized scratch state and prove feature identity**

Validate `WALKTHROUGH_PATH` is the recorded child of `WALKTHROUGH_PARENT`, then from outside it:

```bash
git worktree remove --force "$WALKTHROUGH_PATH"
git branch -D "$WALKTHROUGH_BRANCH"
rmdir "$WALKTHROUGH_PARENT"
```

Require feature HEAD unchanged/clean and absence of the scratch field in code, manifest, and `.ckdb`.

- [ ] **Step 5: Obtain reviewer READY and handoff**

Send reviewer spec, plan, `origin/main..HEAD`, full evidence, and complete transcript. Fix all
actionable findings with new signed commits; after tooling/runbook changes rerun full gate and a
fresh walkthrough; request delta re-review. Require explicit READY/handoff on final head.

- [ ] **Step 6: Push and open the non-draft PR with transcript**

PR body covers #410's rejected manual workflow, reporter/oracle/annotations, verification,
complete labeled walkthrough transcript, and reviewer READY head. Preserve worktree. Do not merge.

- [ ] **Step 7: Raise the maintainer usability gate and wait**

Send AMQ to `user` on `gate/cloudkit-schema-runbook-usability`, kind `question`, subject
`APPROVAL: CloudKit schema runbook usability`, with PR URL and request to read section 1 as its real
user. Notify planner merge is held. Only after explicit maintainer acceptance and green GitHub
checks send planner the approval evidence for their merge. Section 2's Console/Production stop
conditions remain maintainer-exercised during the actual release.
