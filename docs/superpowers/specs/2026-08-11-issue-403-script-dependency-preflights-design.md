# Issue #403: Preflight Remaining Script Dependencies

## Goal

Make repository scripts safe and deterministic when an external command, Xcode-bundled tool, or
Bundler-resolved executable is unavailable. A script must refuse before doing substantive work or
touching shared state, name the unavailable dependency, and return nonzero.

## Dependency boundaries

Each changed script owns validation of the external commands it directly invokes. Test harnesses
continue to inject fakes for dependencies whose failure behavior they are testing; they must not
turn hermetic fixtures into workstation audits.

The required semantic probes are discovery-based and do not pin an Xcode, Ruby, gem, or Homebrew
installation path:

```bash
xcrun --find cktool
bundle exec fastlane --version
bundle exec xcpretty --version
```

The production schema gate validates `xcrun` with `command -v`, then uses `xcrun --find cktool`
before reading its manifest or exporting the production schema. The schema harness keeps its fake
`xcrun` and adds a fixture proving an unavailable `cktool` is named and rejected before any export
attempt.

The Fastlane credential-routing harness preflights the ordinary external commands used to build
its fixtures. It keeps fake `op` and `bundle` commands so it can prove credential lanes reject a
missing `op` before invoking Bundler. The Fastlane gates integration harness preflights `bundle`
and verifies the resolved Fastlane executable with `bundle exec fastlane --version` before it
creates fixtures or runs the gate lane.

For formatted Xcode commands, the public `scripts/xcode-stream.sh --xcpretty` path validates
`bundle`, then verifies the resolved formatter with `bundle exec xcpretty --version`. Both checks
run before `gate status`, registry initialization, simulator lookup, or allocation. A fixture must
force the semantic formatter probe to fail and prove the simulator-gate log remains empty.

## Common preflight shape

Shell test scripts use the established array-and-loop pattern at the top of the file:

```bash
# Keep this list in sync whenever the suite starts invoking another external tool.
required_commands=(...)
for required_command in "${required_commands[@]}"; do
  command -v "$required_command" >/dev/null || {
    echo "FAIL: required command not found: $required_command" >&2
    exit 127
  }
done
```

Production entrypoints use equivalent named failures in their own diagnostic style. Missing
executables return 127. A command that exists but cannot discover its bundled tool or resolve its
gem returns 1. Runtime child failures keep their existing exact exit-status contracts.

## Script safety policy

Add a terse `Script Safety` subsection to `AGENTS.md` for every new or modified script:

- validate external dependencies before work or shared-state mutation, naming missing tools;
- fail closed when a check cannot run, input cannot be read, or output cannot be parsed;
- propagate exact child exit statuses through pipelines and wrappers;
- verify effects rather than textual forms when enforcing an invariant; and
- place guards in build phases or scripts, never solely in Git hooks.

This policy records the maintainer's governing principle: scripts should be safe and
deterministic.

## Tests and release metadata

Write the refusal fixtures before implementation, then run all four focused shell suites:

```bash
bash scripts/test-check-prod-schema.sh
bash scripts/test-fastlane-credential-routing.sh
bash scripts/test-fastlane-gates.sh
bash scripts/test-xcode-stream.sh
```

Also syntax-check every modified shell file, run the repository policy gates relevant to the
changed scripts and documentation, and obtain independent code review. No simulator build is
needed because this change is confined to shell execution and project release metadata. Advance
the release from 2.0.19 (38) to 2.0.20 (39).

## Rejected alternatives

Command-name-only validation cannot detect an absent Xcode component or unresolved gem. Pinning
absolute executable paths would ignore `DEVELOPER_DIR`, `xcode-select`, Bundler resolution, Ruby
homes, and future gem upgrades. Requiring real `cktool` or `op` installations in hermetic test
harnesses would test the host rather than the scripted behavior.
