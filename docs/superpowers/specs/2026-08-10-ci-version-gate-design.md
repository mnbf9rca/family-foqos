# CI Version Gate Design

## Goal

Add the repository's first GitHub Actions workflow and block pull requests to `main` unless both
Xcode version settings increase strictly from the pull request base:

- `MARKETING_VERSION` increases by numeric `major.minor.patch` comparison.
- `CURRENT_PROJECT_VERSION` increases by integer comparison.

## Scope

The change contains one repository-local check script, one fixture-based shell test, one
pull-request workflow, and the `2.0.1` / build `20` project-version increment required for this
pull request to pass its own gate. The workflow deliberately omits the optional sync guards and
Xcode unit suite; the approved board scope is the version gate only.

After the pull request merges, the maintainer must add the workflow's `Version gate` check to the
`main` branch ruleset. Repository ruleset configuration and any Xcode build are outside this
change.

## Design

`scripts/check-version-increment.sh` accepts a base Git ref and an optional head Git ref. It reads
`FamilyFoqos.xcodeproj/project.pbxproj` from both refs with `git show`, extracts every occurrence of
the two version settings, and requires each setting to have one unique project-wide value. It
validates `MARKETING_VERSION` as exactly three numeric components and
`CURRENT_PROJECT_VERSION` as an unsigned integer before comparing them numerically.

`.github/workflows/version-gate.yml` runs for pull requests targeting `main`, grants read-only
repository access, checks out full history, and passes the pull request base/head SHAs to the
script. Keeping comparison logic in the repository makes the behavior locally testable and avoids
a third-party action dependency.

Because every pull request must compare against the current `main`, concurrent pull requests can
race on the same next version. A branch that becomes stale must add a new version-bump commit after
rebasing or merging the updated base; existing commits are never amended.

## Failure Behavior

The gate fails closed when a ref or project file cannot be read, a setting is absent, target/build
configurations disagree, a value is malformed, or either head value is less than or equal to its
base value. Diagnostic output identifies the invalid setting or the required increase without
printing unrelated project data.

## Verification

`scripts/test-check-version-increment.sh` creates a disposable Git repository and proves:

- both values increasing passes;
- unchanged marketing or build values fail;
- decreased values fail;
- numeric semantic comparison handles multi-digit components correctly;
- malformed values fail;
- inconsistent values across build configurations fail.

The test is zero-Xcode and runs with standard macOS/GitHub runner shell and Git tools.
