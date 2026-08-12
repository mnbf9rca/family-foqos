# CloudKit Schema Drift Automation Implementation Plan

This minimal plan supersedes the earlier hardening plan by maintainer order. Hardening is deferred
until the reporter earns it.

## 1. Reporter and Smoke Test

- Add `scripts/report-cloudkit-schema-drift.sh` with named command/file failures.
- Run the five existing searches and normalize code, manifest, and `.ckdb` entries.
- Report missing and extra entries with a nonzero drift status.
- Keep the `cloudkit.share` and `FamilyPolicy` exceptions as two documented filters in the script.
- Add one smoke test: verify the real tree is clean, inject one fake field into a temporary copy,
  and verify that exact field is reported.
- Run Bash syntax checks and ShellCheck.

## 2. Runbook and Version

- Label section 1 for coding agents and section 2 for maintainers only.
- Make section 1 flow from reporter, to reported edits, to existing checker, to pull request.
- Add the reporter to maintainer release preflight.
- Set every Xcode build setting to version `2.0.25` and build `44`.

## 3. Verification and Gates

- Run the reporter against the real tree and run its one smoke test.
- Run the existing schema checker and its test harnesses.
- Perform a literal deliberate-failure walkthrough in a disposable worktree and retain its
  transcript for the pull request.
- Request code review.
- Open a non-draft pull request with the note: “minimal by maintainer order; hardening deferred
  until the tool earns it”.
- Request the required maintainer read before merge.
