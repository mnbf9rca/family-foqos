# CloudKit Schema Upgrade Process Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make routine CloudKit schema changes and release-time Production promotion two explicit,
numbered operator workflows, with concise script output that points maintainers to the canonical
runbook and clearly labels expected harness failures.

**Architecture:** Keep `docs/cloudkit-production-schema.md` as the single source of procedural
truth. The checked-in schema checker will emit one documentation pointer only after successful
validation, while the production gate harness will label only the three deliberately surfaced
negative-case lines; neither change alters fail-closed validation or exit-status behavior.

**Tech Stack:** Markdown, Bash, `rg`, `shellcheck`, Xcode project build settings

## Global Constraints

- Keep `docs/cloudkit-production-schema.md` as the one canonical schema workflow document.
- Use exactly two numbered workflows: **Routine Schema Change** and **Release Promotion**.
- Keep record-type and field counts descriptive in `fastlane/required-prod-schema.txt`; do not
  hardcode them into procedural checklist steps.
- Preserve the additive-only Production rule and maintainer-only CloudKit Console deployment.
- Preserve every checker and harness exit status; `[expected-failure]` is presentation-only.
- The successful checked-in schema checker must print exactly:
  `Next: if preparing a release, promote via docs/cloudkit-production-schema.md`
- Prefix only the three deliberate negative-case lines at the end of
  `scripts/test-check-prod-schema.sh`; leave its final `PASS:` line unprefixed.
- Set the app version to `2.0.24` and build number to `43` in every Xcode project build setting.
- Do not run Xcode or iOS Simulator builds: this change touches release/operator documentation,
  standalone shell tooling, and build-setting text only.
- All commits must be signed, must be new commits, and must never amend or force-push history.

---

### Task 1: Point successful schema checks to the canonical workflow

**Files:**
- Modify: `scripts/test-check-cloudkit-schema-export.sh:39-48`
- Modify: `scripts/check-cloudkit-schema-export.sh:67`

**Interfaces:**
- Consumes: `CHECK_OUTPUT` captured from the copied schema checker in the hermetic fixture.
- Produces: a successful checker output containing the existing coverage sentence followed by the
  exact `Next:` line from Global Constraints.

- [ ] **Step 1: Strengthen the successful fixture first**

Replace the matching-schema assertion with an assertion for both success lines:

```bash
if [[ "$CHECK_STATUS" -ne 0 ||
  "$CHECK_OUTPUT" != *"Checked-in CloudKit schema covers every required record type and field."* ||
  "$CHECK_OUTPUT" != *"Next: if preparing a release, promote via docs/cloudkit-production-schema.md"* ]]; then
  echo "FAIL: matching schema with compatibility extras must pass and point to the runbook"
  echo "$CHECK_OUTPUT"
  exit 1
fi
```

- [ ] **Step 2: Run the fixture and observe RED**

Run:

```bash
bash scripts/test-check-cloudkit-schema-export.sh
```

Expected: exit `1` with
`FAIL: matching schema with compatibility extras must pass and point to the runbook`, because the
checker does not yet print the documentation pointer.

- [ ] **Step 3: Add the minimal successful-output pointer**

Immediately after the existing success sentence in `scripts/check-cloudkit-schema-export.sh`, add:

```bash
echo "Next: if preparing a release, promote via docs/cloudkit-production-schema.md"
```

Do not add this line to any error branch.

- [ ] **Step 4: Run focused checks and observe GREEN**

Run:

```bash
bash scripts/test-check-cloudkit-schema-export.sh
bash scripts/check-cloudkit-schema-export.sh
```

Expected: both exit `0`; the fixture ends with
`PASS: checked-in CloudKit schema gate cases`, and the real checker prints the coverage sentence
followed by the exact `Next:` line.

- [ ] **Step 5: Commit the independently tested output contract**

```bash
git add scripts/check-cloudkit-schema-export.sh scripts/test-check-cloudkit-schema-export.sh
git commit -S -m "Point schema checks to promotion runbook"
```

### Task 2: Label deliberate production-gate harness failures

**Files:**
- Modify: `scripts/test-check-prod-schema.sh:118-121`

**Interfaces:**
- Consumes: `EMPTY_OUTPUT`, `EMPTY_STATUS`, and `QUERY_FAILURE_STATUS` captured only after their
  existing assertions have proved the deliberate failure cases behaved correctly.
- Produces: exactly three console lines beginning with `[expected-failure]`, followed by the
  unchanged unprefixed `PASS: production-schema gate cases` line.

- [ ] **Step 1: Run a transient acceptance assertion and observe RED**

Run:

```bash
PROD_OUTPUT=$(bash scripts/test-check-prod-schema.sh)
[[ "$(printf '%s\n' "$PROD_OUTPUT" | grep -c '^\[expected-failure\]')" -eq 3 ]]
```

Expected: the harness itself exits `0`, then the assertion exits `1` because no successful-run
console line currently carries the prefix.

- [ ] **Step 2: Prefix only the deliberate failure presentation**

Replace the final four output statements with:

```bash
echo "[expected-failure] $EMPTY_OUTPUT"
echo "[expected-failure] empty-manifest exit: $EMPTY_STATUS"
echo "[expected-failure] forced-cktool exit: $QUERY_FAILURE_STATUS"
echo "PASS: production-schema gate cases"
```

Do not change fixture execution, assertions, captured statuses, or error-branch diagnostics.

- [ ] **Step 3: Run exact output assertions and observe GREEN**

Run:

```bash
PROD_OUTPUT=$(bash scripts/test-check-prod-schema.sh)
[[ "$(printf '%s\n' "$PROD_OUTPUT" | grep -c '^\[expected-failure\]')" -eq 3 ]]
[[ "$PROD_OUTPUT" == *$'\nPASS: production-schema gate cases' ]]
[[ "$PROD_OUTPUT" != *$'\n[expected-failure] PASS: production-schema gate cases' ]]
printf '%s\n' "$PROD_OUTPUT"
```

Expected: exit `0`; the three deliberate lines are prefixed and the final `PASS:` line is not.

- [ ] **Step 4: Commit the independently verified presentation change**

```bash
git add scripts/test-check-prod-schema.sh
git commit -S -m "Label expected production schema failures"
```

### Task 3: Restructure the canonical runbook around operator tasks

**Files:**
- Modify: `docs/cloudkit-production-schema.md:1-51`

**Interfaces:**
- Consumes: the manifest reconciliation commands in `fastlane/required-prod-schema.txt`, the
  checked-in `.ckdb` reference, the two checker commands, CloudKit Console, and the two Fastlane
  wrapper commands.
- Produces: one canonical page with two numbered checklists whose first steps match the
  maintainer's actual triggers.

- [ ] **Step 1: Replace the reference-first layout with a Routine Schema Change checklist**

Keep the title, container identifier, Production behavior, additive-only warning, and Apple
references. Make the first workflow heading `## 1. Routine Schema Change` and introduce it with:

```markdown
Use this checklist whenever a code change adds or changes a CloudKit record type or field.
```

The numbered checklist must direct the operator to:

1. make the code field or record-type change;
2. run all five exact `rg` searches from the header of
   `fastlane/required-prod-schema.txt`;
3. reconcile `fastlane/required-prod-schema.txt`, preserving built-in and deprecated schema
   requirements and updating its reconciliation date/count note without embedding those counts in
   this runbook;
4. reconcile `Foqos/CloudKit/cloudkit-schema.ckdb` with the CloudKit Development schema, preserving
   deployed compatibility declarations;
5. run `bash scripts/check-cloudkit-schema-export.sh` and
   `bash scripts/test-check-cloudkit-schema-export.sh`; and
6. include the code, manifest, `.ckdb`, and successful checker/harness output in the pull request.

Copy these exact searches into the checklist's command block:

```bash
rg -n 'static let recordType\s*=\s*"[^"]+"' Foqos FoqosDeviceMonitor FoqosShieldConfig FoqosWidget
rg -n 'CKRecord\(recordType:\s*"[^"]+"' Foqos FoqosDeviceMonitor FoqosShieldConfig FoqosWidget
rg -n 'static let recordType|enum FieldKey: String|^[[:space:]]+case [[:alnum:]_]+( = "[^"]+")?$' Foqos/CloudKit/SyncModels.swift Foqos/CloudKit/ProfileSessionRecord.swift
rg -n 'static let recordType|enum RecordKey|^[[:space:]]+static let [[:alnum:]_]+ = "[^"]+"' Foqos/Models/DeviceHeartbeat.swift Foqos/Models/FamilyCommand.swift Foqos/Models/FamilyLockCode.swift Foqos/Models/FamilyMember.swift
rg -n 'rootRecord\["[^"]+"\]' Foqos/CloudKit/CloudKitNetworkService.swift Foqos/CloudKit/CloudKitNetworkService+Sharing.swift
```

- [ ] **Step 2: Add a Release Promotion checklist with explicit stop/go gates**

Make the second workflow heading `## 2. Release Promotion` and introduce it with:

```markdown
Use this checklist after the final schema-touching pull request has merged and before the first
TestFlight or App Store build that depends on it.
```

The numbered checklist must direct the maintainer to:

1. run repository preflight with `bash scripts/check-cloudkit-schema-export.sh` and
   `bash scripts/test-check-prod-schema.sh`;
2. sign in to CloudKit Console, select `iCloud.com.cynexia.family-foqos`, choose the correct
   CloudKit Database and environment, and compare the Development schema with the checked-in
   `.ckdb`;
3. review pending additive changes, choose **Deploy Schema Changes**, and confirm completion;
4. run authenticated postflight with `bash scripts/check-prod-schema.sh` and require
   `Production schema OK.`;
5. close the release's schema tracking issue; and
6. only then run `scripts/fastlane.sh beta` for TestFlight or
   `scripts/fastlane.sh release` for App Store submission.

Keep an adjacent note stating that the Console deployment is maintainer-only and agents must not
perform it.

- [ ] **Step 3: Validate workflow structure and command fidelity**

Run:

```bash
rg -n '^## [12]\. (Routine Schema Change|Release Promotion)$|Deploy Schema Changes|scripts/fastlane\.sh (beta|release)|bash scripts/check-(cloudkit-schema-export|prod-schema)\.sh' docs/cloudkit-production-schema.md
for command in \
  "static let recordType\\s*=\\s*\"[^\"]+\"" \
  "CKRecord\\(recordType:\\s*\"[^\"]+\"" \
  "enum FieldKey: String" \
  "enum RecordKey" \
  "rootRecord\\[\"[^\"]+\"\\]"; do
  grep -F "$command" docs/cloudkit-production-schema.md >/dev/null
done
```

Expected: the first command shows both workflow headings, both schema checker commands, the
Console action, and both Fastlane commands; the loop exits `0`, proving every manifest-header
search family appears in the runbook.

- [ ] **Step 4: Commit the canonical operator workflow**

```bash
git add docs/cloudkit-production-schema.md
git commit -S -m "Document CloudKit schema upgrade workflows"
```

### Task 4: Bump version and run the complete verification gate

**Files:**
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj:706-1146`
- Verify: `docs/cloudkit-production-schema.md`
- Verify: `scripts/check-cloudkit-schema-export.sh`
- Verify: `scripts/test-check-cloudkit-schema-export.sh`
- Verify: `scripts/test-check-prod-schema.sh`

**Interfaces:**
- Consumes: all completed documentation and script changes from Tasks 1-3.
- Produces: version `2.0.24` / build `43`, complete static and focused-test evidence, and a clean
  branch ready for independent review.

- [ ] **Step 1: Update every Xcode build setting**

Change every `MARKETING_VERSION = 2.0.23;` to `MARKETING_VERSION = 2.0.24;` and every
`CURRENT_PROJECT_VERSION = 42;` to `CURRENT_PROJECT_VERSION = 43;` in
`FamilyFoqos.xcodeproj/project.pbxproj`.

- [ ] **Step 2: Verify the version matrix before committing**

Run:

```bash
! rg -n 'MARKETING_VERSION = 2\.0\.23|CURRENT_PROJECT_VERSION = 42' FamilyFoqos.xcodeproj/project.pbxproj
rg -c 'MARKETING_VERSION = 2\.0\.24;' FamilyFoqos.xcodeproj/project.pbxproj
rg -c 'CURRENT_PROJECT_VERSION = 43;' FamilyFoqos.xcodeproj/project.pbxproj
```

Expected: the first command has no matches; the two counts are equal and nonzero.

- [ ] **Step 3: Commit the version bump**

```bash
git add FamilyFoqos.xcodeproj/project.pbxproj
git commit -S -m "Bump version for schema process update"
```

- [ ] **Step 4: Run all focused behavior and static checks**

Run:

```bash
bash scripts/test-check-cloudkit-schema-export.sh
bash scripts/check-cloudkit-schema-export.sh
bash scripts/test-check-prod-schema.sh
bash -n scripts/check-cloudkit-schema-export.sh scripts/test-check-cloudkit-schema-export.sh scripts/test-check-prod-schema.sh
shellcheck scripts/check-cloudkit-schema-export.sh scripts/test-check-cloudkit-schema-export.sh scripts/test-check-prod-schema.sh
git diff --check origin/main...HEAD
git status --short
```

Expected: all commands exit `0`; checker and harness success markers are present; exactly three
successful-run production harness lines begin with `[expected-failure]`; `git diff --check` is
silent; and `git status --short` is empty. No Xcode build or simulator is required by Global
Constraints.

- [ ] **Step 5: Verify signed history and request independent AMQ review**

Run:

```bash
git log --show-signature --format='%h %G? %s' origin/main..HEAD
```

Expected: every commit displays a good signature. Send the approved spec, this plan, the complete
diff, and verification evidence to the planner/reviewer through AMQ. Address all actionable review
feedback with new signed commits, rerun Step 4, request re-review, then create an undrafted pull
request only after approval. Do not merge; send the approved PR URL to the planner for the required
merge step.
