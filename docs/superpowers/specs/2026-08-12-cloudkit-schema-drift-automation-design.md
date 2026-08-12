# CloudKit Schema Drift Automation Design

## Scope

This design supersedes the earlier hardening proposal by maintainer order. The first version is a
small, read-only shell report whose value can be proven in one deliberate-failure walkthrough.
Hardening is deferred until the tool earns it.

The change does not deploy CloudKit schema, modify a Fastlane lane, or alter the existing checked-in
schema checker.

## Reporter

Add `scripts/report-cloudkit-schema-drift.sh`. It runs the five existing source searches, normalizes
their record types and fields, and compares them in two stages:

- code declarations against `fastlane/required-prod-schema.txt`;
- the manifest against `Foqos/CloudKit/cloudkit-schema.ckdb`.

The reporter prints missing and extra entries, exits nonzero when drift exists, and prints a named
error when a required command or input file is unavailable. It is read-only. The only intentional
exceptions are documented beside their filters in the script: CloudKit's built-in
`cloudkit.share` type and the additive-only legacy `FamilyPolicy` type.

Clean output is `OK: no CloudKit schema drift.`. Drift output ends with
`CloudKit schema drift detected.`.

## Test

Add one smoke test, `scripts/test-report-cloudkit-schema-drift.sh`. It first proves the real tree is
clean, then copies the relevant files to a temporary repository, inserts one fake field, and proves
the reporter identifies that field as missing from the manifest.

## Runbook and Release Metadata

`docs/cloudkit-production-schema.md` has two explicit audiences. Coding agents run the reporter,
make the reported manifest and schema edits, run the existing checker, and attach evidence to their
pull request. Maintainers alone perform Production promotion after merge.

Set the application version to `2.0.25` and build number to `44` in all Xcode build settings.

## Merge Gates

Before merge:

1. capture a literal walkthrough in which a new field makes the reporter stop the workflow, then
   reconcile the manifest and checked-in schema and rerun the existing checker;
2. obtain code review;
3. obtain a maintainer read of the operator-facing runbook and walkthrough.
