# CloudKit Schema Upgrade Process Design

## Context

The repository has a technically accurate CloudKit Production schema runbook, but it begins with
background and verification detail rather than telling an operator what to do. During live release
work, the maintainer had to infer two distinct workflows:

1. how to update repository schema artifacts after adding or changing a CloudKit field in code; and
2. how to promote a reviewed Development schema to Production before a release.

Two tool-output details compound the problem. The checked-in schema checker reports success without
pointing at the promotion workflow, and the production-schema harness deliberately prints a fixture
failure before its final PASS without marking that failure as expected.

## Decision

`docs/cloudkit-production-schema.md` remains the single canonical document and becomes task-first.
It opens with two numbered operator checklists in plain product language, followed by compact safety
and reference detail.

### Routine repository update

The first checklist starts from the operator's real trigger: “you added or changed a CloudKit field
in code.” It directs the operator to:

1. run the exact record-type and field searches from the header of
   `fastlane/required-prod-schema.txt`;
2. reconcile that manifest with the code while preserving built-in and deprecated requirements;
3. update `Foqos/CloudKit/cloudkit-schema.ckdb` from the CloudKit Development schema;
4. run the checked-in schema checker and its harness; and
5. include the code, manifest, schema export, and relevant verification evidence in the pull
   request.

The checklist does not hardcode the current record-type or field counts. Those counts are useful
reconciliation notes in the manifest header, but procedural steps that repeat them would become
stale as the schema grows.

### Release promotion

The second checklist directs the maintainer to:

1. run the checked-in export checker and both schema harnesses as repository preflight;
2. open CloudKit Console for `iCloud.com.cynexia.family-foqos` and select the Development
   environment;
3. review the pending additive schema, choose **Deploy Schema Changes**, and confirm completion;
4. run `bash scripts/check-prod-schema.sh` with authenticated `cktool` as postflight;
5. close the release's schema tracking issue; and
6. proceed to the applicable Fastlane beta or release lane only after postflight is green.

The Console deployment remains maintainer-only. Agents can update, check, and review repository
artifacts but cannot promote the Production schema.

## Tool Output Contracts

On success, `scripts/check-cloudkit-schema-export.sh` retains its existing coverage line and adds:

```text
Next: if preparing a release, promote via docs/cloudkit-production-schema.md
```

The existing `scripts/test-check-cloudkit-schema-export.sh` harness asserts that next-step line as a
behavioral contract, as well as the existing coverage message.

Only `scripts/test-check-prod-schema.sh` changes expected-failure presentation. Its successful test
run currently surfaces three deliberate failure lines: the empty-manifest diagnostic, its exit
status, and the forced `cktool` exit status. Each receives an `[expected-failure]` prefix; the final
`PASS: production-schema gate cases` line remains unprefixed.

Other harnesses remain unchanged. They print captured stderr only when the harness's own assertion
fails, so their output represents a real test failure and must not be relabelled as expected.

## Alternatives Rejected

### Add a second process document

A separate “schema upgrade process” document could have a more obvious title, but it would create
two authoritative-looking entry points and require permanent cross-link maintenance. Restructuring
the current runbook keeps one stable path for operators and for the checker’s next-step output.

### Put the process in command output

Scripts can point to the canonical guide, but embedding the Console and release workflow in command
output would deliver instructions too late and make prose maintenance awkward. The document owns the
workflow; tools provide short contextual next steps.

## Error Handling and Safety

Existing schema checks remain fail-closed and preserve their exit statuses. No schema artifact,
manifest requirement, CloudKit container setting, or Production deployment is changed by this work.
The runbook continues to state that Production schema changes are additive-only: operators must not
rename or remove deployed record types or fields.

The expected-failure prefix is presentation only. It does not suppress fixture stderr, change any
assertion, or turn an unexpected harness failure into a pass.

## Test Strategy

The baseline output establishes both requested behavior changes:

```text
Checked-in CloudKit schema covers every required record type and field.
```

has no next step, while the successful production-schema harness begins with an unlabelled
`Required schema file is empty or unreadable` fixture diagnostic.

Implementation verification runs:

```bash
bash scripts/test-check-cloudkit-schema-export.sh
bash scripts/check-cloudkit-schema-export.sh
bash scripts/test-check-prod-schema.sh
bash -n scripts/check-cloudkit-schema-export.sh
bash -n scripts/test-check-cloudkit-schema-export.sh
bash -n scripts/test-check-prod-schema.sh
```

The export harness must fail before the checker change when it first requires the new next-step line,
then pass after the checker emits it. Final direct output must contain both success lines. The
production harness must show three `[expected-failure]` lines followed by its unprefixed PASS line.

Version-gate verification, `git diff --check`, independent review, and required GitHub checks finish
the change. No Xcode build or simulator run is needed: these files are release/operator shell tools,
not Xcode build-phase tooling.

## Scope

Implementation changes are limited to:

- `docs/cloudkit-production-schema.md`
- `scripts/check-cloudkit-schema-export.sh`
- `scripts/test-check-cloudkit-schema-export.sh`
- `scripts/test-check-prod-schema.sh`
- `FamilyFoqos.xcodeproj/project.pbxproj` version settings, from 2.0.23/build 42 to
  2.0.24/build 43
- this design and its implementation plan

CloudKit schema exports, required-schema manifest contents, app code, Fastlane lanes, and Production
schema state do not change.
