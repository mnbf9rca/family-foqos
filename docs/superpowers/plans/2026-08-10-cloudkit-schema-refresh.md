# CloudKit Schema Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reconcile the checked-in CloudKit schema with current code and the required Production manifest, with a terse maintainer deployment runbook and a zero-Xcode drift check.

**Architecture:** A small repository check treats `fastlane/required-prod-schema.txt` as the required record-type set and verifies that the `.ckdb` contains every declaration while permitting deprecated extras. The `.ckdb` fields are refreshed from current `CKRecord` encoders, and a separate runbook keeps the irreversible Production promotion explicitly maintainer-owned.

**Tech Stack:** Bash, CloudKit Schema Language, Markdown

## Global Constraints

- No CloudKit Console mutation or `cktool` install/deploy.
- No GitHub Actions or other CI wiring.
- No Xcode build or simulator test.
- Preserve deprecated compatibility record types in the `.ckdb`.
- If #321 lands first, add a new version-bump commit against updated `main`; never amend or force-push.

---

### Task 1: Local schema-manifest drift check

**Files:**
- Create: `scripts/check-cloudkit-schema-export.sh`
- Create: `scripts/test-check-cloudkit-schema-export.sh`

**Interfaces:**
- Consumes: `fastlane/required-prod-schema.txt` and `Foqos/CloudKit/cloudkit-schema.ckdb`
- Produces: exit 0 when every non-comment manifest declaration exists exactly in the `.ckdb`; exit 1 for missing types; exit 2 for empty/unreadable inputs

- [ ] **Step 1: Write the failing fixture test**

Create a disposable repository-shaped directory, copy the production checker into `scripts/`, and
exercise these literal fixtures:

```text
# matching manifest (extra compatibility type is allowed)
RECORD TYPE Required
RECORD TYPE "cloudkit.share"

# matching schema
RECORD TYPE Required (
RECORD TYPE "cloudkit.share" (
RECORD TYPE DeprecatedExtra (
```

The test must also assert that a missing `Required`, a prefix-only `RequiredExtra`, and a
comment-only manifest fail with the intended exit class.

- [ ] **Step 2: Run the fixture test and observe RED**

Run: `bash scripts/test-check-cloudkit-schema-export.sh`

Expected: exit 1 with `FAIL: CloudKit schema export checker is missing`.

- [ ] **Step 3: Implement the minimal checker**

Use the same exact-declaration rule as the Production gate:

```bash
while IFS= read -r requirement; do
  [[ -z "$requirement" || "$requirement" == \#* ]] && continue
  if ! grep -qF "$requirement (" "$SCHEMA_FILE"; then
    echo "MISSING from checked-in CloudKit schema: $requirement"
    missing=1
  fi
done <"$REQUIRED_FILE"
```

Validate both files are readable and non-empty, require at least one non-comment manifest entry,
and print `Checked-in CloudKit schema covers every required record type.` on success.

- [ ] **Step 4: Run the fixture test and observe GREEN**

Run: `bash scripts/test-check-cloudkit-schema-export.sh`

Expected: `PASS: checked-in CloudKit schema gate cases`.

- [ ] **Step 5: Run the checker against the current stale repository and observe RED**

Run: `bash scripts/check-cloudkit-schema-export.sh`

Expected: exit 1 listing exactly these missing declarations:

```text
RECORD TYPE DeviceHeartbeat
RECORD TYPE EmergencyResetEpoch
RECORD TYPE EmergencySettings
RECORD TYPE EmergencyUnblockEvent
RECORD TYPE SyncEstablishment
```

### Task 2: Refresh schema artifact and maintainer runbook

**Files:**
- Modify: `Foqos/CloudKit/cloudkit-schema.ckdb`
- Create: `docs/cloudkit-production-schema.md`

**Interfaces:**
- Consumes: current record encoders in `SyncModels.swift` and `DeviceHeartbeat.swift`
- Produces: a checked-in schema covering all 15 manifest types and a maintainer-only Production promotion checklist

- [ ] **Step 1: Add the shared-family record declaration**

Add `DeviceHeartbeat` after `FamilyCommand`, with the standard six system fields, shared-family
grants, and these application fields:

```text
childUserRecordName STRING,
deviceIdentifier   STRING,
deviceName         STRING,
lastHeartbeatAt    TIMESTAMP,
authorizationStatus STRING
```

- [ ] **Step 2: Bring existing DeviceSync declarations current**

Add exactly this non-indexed field to both existing record declarations:

```text
generation INT64,
```

Place it with sync metadata on `SyncedProfile` and before `lastModified` on `SyncedLocation`.

- [ ] **Step 3: Add current emergency and establishment declarations**

Add the standard six system fields and creator-only grants to each record type, with these exact
application fields:

```text
RECORD TYPE EmergencySettings (
  unblocksRemaining INT64,
  resetPeriodInDays INT64,
  lastResetDate TIMESTAMP,
  settingsLocked INT64,
  version INT64,
  lastModified TIMESTAMP,
  originDeviceId STRING
);

RECORD TYPE EmergencyResetEpoch (
  epoch INT64,
  generation INT64
);

RECORD TYPE SyncEstablishment (
  generation INT64,
  establishedAt TIMESTAMP
);

RECORD TYPE EmergencyUnblockEvent (
  id STRING,
  deviceId STRING,
  consumedAt TIMESTAMP,
  resetEpoch INT64,
  generation INT64
);
```

- [ ] **Step 4: Add the maintainer-only runbook**

Create `docs/cloudkit-production-schema.md` with:

```text
Container: iCloud.com.cynexia.family-foqos
Preflight: bash scripts/check-cloudkit-schema-export.sh
Promotion owner: maintainer only, after the final schema-touching PR and before TestFlight
Promotion tool: CloudKit Console, Development schema -> Deploy to Production
Postflight: bash scripts/check-prod-schema.sh
Safety: Production changes are additive-only; agents never perform the Console keystroke
```

Link Apple’s `Integrating a Text-Based Schema into Your Workflow` and
`Deploying an iCloud Container’s Schema` documentation.

- [ ] **Step 5: Run the real checker and existing gate tests**

Run:

```bash
bash scripts/check-cloudkit-schema-export.sh
bash scripts/test-check-cloudkit-schema-export.sh
bash scripts/test-check-prod-schema.sh
```

Expected: all exit 0 with their PASS/success markers.

### Task 2A: Guard declared application fields

**Files:**
- Modify: `fastlane/required-prod-schema.txt`
- Modify: `scripts/check-cloudkit-schema-export.sh`
- Modify: `scripts/test-check-cloudkit-schema-export.sh`
- Modify: `docs/cloudkit-production-schema.md`

**Interfaces:**
- Consumes: hand-reconciled `RECORD TYPE X` and `RECORD TYPE X.field` manifest entries plus matching
  record blocks in `cloudkit-schema.ckdb`
- Produces: exit 1 with `MISSING from checked-in CloudKit schema: RECORD TYPE X.field` when any
  manifest field is absent; success identifying exactly 101 fields across 13 active types

- [ ] **Step 1: Add the failing field fixture first**

Add `RECORD TYPE Required.requiredField` to the disposable manifest and `requiredField STRING` to
the matching schema. Add a second schema fixture that retains `Required` but removes
`requiredField`, and require exit 1 with the exact missing manifest entry.

- [ ] **Step 2: Run the fixture test and observe RED**

Run: `bash scripts/test-check-cloudkit-schema-export.sh`

Expected: exit 1 because the existing type-only checker treats `Required.requiredField` as a record
type and rejects the otherwise matching schema.

- [ ] **Step 3: Normalize schema records and fields**

Use one small `awk` pass over the `.ckdb` to emit exact normalized entries:

```text
RECORD TYPE Required
RECORD TYPE Required.requiredField
```

Keep the existing fixed-string manifest loop, changing it to exact-line matching against the
normalized entries. This scopes every field to its record block and still permits extra schema
fields and record types.

- [ ] **Step 4: Add the hand-reconciled field inventory**

Extend `fastlane/required-prod-schema.txt` with the reviewer-verified 101 fields across 13 active
types and update its reconciliation date and commands. Update the runbook to state precisely that
the checker proves `.ckdb` coverage of the manifest, while manifest-to-code alignment remains a
documented hand review.

- [ ] **Step 5: Run the fixture and production checks GREEN**

Run:

```bash
bash scripts/test-check-cloudkit-schema-export.sh
bash scripts/check-cloudkit-schema-export.sh
```

Expected:

```text
PASS: checked-in CloudKit schema gate cases
Checked-in CloudKit schema covers every required record type and field.
```

- [ ] **Step 6: Commit without amend**

```bash
git add fastlane/required-prod-schema.txt scripts/check-cloudkit-schema-export.sh \
  scripts/test-check-cloudkit-schema-export.sh docs/cloudkit-production-schema.md \
  docs/superpowers/specs/2026-08-10-cloudkit-schema-refresh-design.md \
  docs/superpowers/plans/2026-08-10-cloudkit-schema-refresh.md
git commit -m "Guard CloudKit schema fields"
```

### Task 3: Review-ready verification and publication

**Files:**
- Verify: `Foqos/CloudKit/cloudkit-schema.ckdb`
- Verify: `fastlane/required-prod-schema.txt`
- Verify: `scripts/check-cloudkit-schema-export.sh`
- Verify: `scripts/test-check-cloudkit-schema-export.sh`
- Verify: `docs/cloudkit-production-schema.md`

**Interfaces:**
- Consumes: completed Tasks 1-2
- Produces: reviewed draft PR closing #346's repository-owned portion without claiming Production deployment

- [ ] **Step 1: Run final zero-Xcode verification**

Run:

```bash
bash -n scripts/check-cloudkit-schema-export.sh scripts/test-check-cloudkit-schema-export.sh
shellcheck scripts/check-cloudkit-schema-export.sh scripts/test-check-cloudkit-schema-export.sh
bash scripts/check-cloudkit-schema-export.sh
bash scripts/test-check-cloudkit-schema-export.sh
bash scripts/test-check-prod-schema.sh
git diff --check
```

Expected: every command exits 0.

- [ ] **Step 2: Commit without amend or force**

```bash
git add Foqos/CloudKit/cloudkit-schema.ckdb docs/cloudkit-production-schema.md \
  scripts/check-cloudkit-schema-export.sh scripts/test-check-cloudkit-schema-export.sh \
  docs/superpowers/plans/2026-08-10-cloudkit-schema-refresh.md
git commit -m "Refresh CloudKit schema reference"
```

- [ ] **Step 3: Publish and request review**

Open a draft PR describing the maintainer-only Production deployment boundary. Send the PR and the
exact base/head range to `reviewer` via AMQ before merge. Report the PR on `milestone/4-then-2`.
