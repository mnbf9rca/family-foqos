# Development Workflow

The root `AGENTS.md` carries the common-case commands and non-negotiable invariants. This runbook
explains credential preparation, implementation isolation, simulator ownership, safe scripts, and
build/test/format behavior.

## Keep Changes Small and Reviewable

Keep implementations DRY and KISS and, in general, apply YAGNI. Never force-push or amend a
commit. Create a new signed commit for each fix; use Git revert when history must be undone.
Always obtain independent code review before merge.

Implementation streams use separate feature branches/worktrees and disjoint files. The simulator
gate supports up to three Xcode streams, but Git isolation does not excuse overlapping edits.
Read-only investigation/review may run concurrently from its own working copy and consumes no gate
slot.

## Warm Git Credentials

At fleet/session startup, while the human is present, the orchestrator dispatches this warm-up to every
implementation stream. Each stream runs it in its clean assigned feature worktree before taking
implementation work:

```bash
scripts/warm-git-credentials.sh
```

The script fails closed unless the worktree is clean, the current branch is a named feature branch,
and `origin` has an SSH push URL. It creates a unique scratch branch, makes a signed empty scratch
commit, performs an SSH push dry-run, restores the starting branch, deletes the scratch branch, and
verifies the final branch/tree. The dry run creates no remote ref.

If signing or SSH approval expires, rerun the script while the human can touch the biometric
sensor. If the human is absent, commit-only work may use the authorized GitHub
`createCommitOnBranch` API when one server-side commit exactly represents the change; otherwise
wait. Never disable signing, create an unsigned production commit, amend, or force-push to evade a
prompt. The separate `op` prompt uses #365's service-account path, not this Git warm-up.

## Simulator Ownership

Every simulator build, test, and screenshot process tree enters through `scripts/xcode-stream.sh`.
The machine-wide gate assigns a distinct simulator UUID, DerivedData directory, and capacity slot
to each exact `(project, agent, session)` owner. Give every stream a stable agent name and optional
session; later runs by the same owner reuse its registered UUID. In this fleet, `--agent` is your Herdr agent name (`build1`, `build2`, or `reviewer`) and `--session` is always `collab`; it is the simulator gate's ownership label, not a Herdr session identifier.

UUID destinations only. Never pass a device-name destination: it can create a simulator under
`~/Library/Developer/XCTestDevices/` on every invocation and consume about 16 GB. Never pass a
destination or DerivedData path yourself. Do not boot, clone, erase, or delete a gate-owned
simulator outside the wrapper. The wrapper injects `-parallel-testing-enabled NO` and
`-disable-concurrent-destination-testing` to prevent XCTestDevices clones.

Set `IOS_SIM_GATE_DEVICE_TYPE` or `IOS_SIM_GATE_RUNTIME` only when the task requires an override.
Always put `xcodebuild` directly after the wrapper's `--`; do not mediate it through `xcrun`, `env`,
`bundle`, or a shell command. Wrapper-owned formatting preserves the exact child status without
depending on caller shell options. Pass `--xcbeautify` to select formatting; the wrapper checks the
standalone `xcbeautify` binary before acquiring the gate and owns the internal
`xcodebuild 2>&1 | xcbeautify` pipeline.

## Build and Clean

```bash
scripts/xcode-stream.sh --agent <agent> --session <session> --xcbeautify -- \
  xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -configuration Debug build

scripts/xcode-stream.sh --agent <agent> --session <session> -- \
  scripts/clean-build.sh
```

The clean command removes only the current owner's gate-assigned DerivedData.

## Test

The unit tests are in `FoqosTests`. The first run may spend several minutes booting the registered
simulator; later runs reuse it.

```bash
scripts/xcode-stream.sh --agent <agent> --session <session> -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos

scripts/xcode-stream.sh --agent <agent> --session <session> -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/ClassName
```

After a failing test run, `xcodebuild` can appear stalled while an asynchronous `simctl diagnose` collection waits up to ten minutes; waiting for it to finish is a safe alternative to stopping it. Confirm XCTest has finished, then trace the diagnose/collector PIDs through their parent chain to your own gate-owned `xcodebuild`, matching its owner DerivedData path and simulator UUID. Send `kill <pid>` (SIGTERM) only to the exact diagnose/collector PIDs whose ownership you proved; never match processes by name. Never stop another stream's processes, the `xcodebuild`, or the gate wrapper; if ownership cannot be established, do not stop the process. Wait for the original command to exit and preserve its exit status; completed test output alone is not a successful command result.

## Agent Acceptance Runbooks

For source-built V1 → V2 upgrade acceptance, an agent follows the [V1 → V2 upgrade runbook](v1-v2-upgrade-runbook.md). It generates the profile matrix, checks fixture compilation before touching data, and reports evidence to the orchestrator. The human performs only the separate checks that require real devices.

## Screenshots, Archives, and Uploads

The Family Controls screenshot demo has no live CKShare identities, so its member list shows “Parent”, “Child”, and “Child” rather than the former synthetic names Alex, Emma, and Sam.

The screenshots lane boots a simulator, so gate its entire process tree:

```bash
scripts/xcode-stream.sh --agent <agent> --session <session> -- \
  scripts/fastlane.sh screenshots
```

V1 (release/v1) receives no entitlement changes; fixes such as the iOS 26 share entitlement ship in V2 only.

Archive and upload lanes do not boot simulators. Run them through `scripts/fastlane.sh` without the
simulator gate:

```bash
# Archive and export only; performs no TestFlight, App Store, or GitHub upload.
scripts/fastlane.sh verify_export

# Upload lanes.
scripts/fastlane.sh beta
scripts/fastlane.sh release
scripts/fastlane.sh update_screenshots
```

Before every beta, compare the live Production and Development schemas. Development must first
hold the canonical checked-in schema, as described in step 2 of
[Release Promotion](cloudkit-production-schema.md#2-release-promotion--maintainer-only).
Run this read-only comparison from an authenticated `cktool` session:

```bash
(
  set -e
  for tool in xcrun mktemp diff; do
    command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 127; }
  done
  schema_dir=$(mktemp -d)
  xcrun cktool export-schema --team-id BU7526J4QY \
    --container-id iCloud.com.cynexia.family-foqos --environment production \
    > "$schema_dir/production.ckdb"
  xcrun cktool export-schema --team-id BU7526J4QY \
    --container-id iCloud.com.cynexia.family-foqos --environment development \
    > "$schema_dir/development.ckdb"
  test -s "$schema_dir/production.ckdb" && test -s "$schema_dir/development.ckdb" \
    || { echo "Schema export is empty" >&2; exit 1; }
  diff -u "$schema_dir/development.ckdb" "$schema_dir/production.ckdb"
  echo "Production and Development schemas match."
)
```

Only matching, nonempty exports pass. An export failure or any difference blocks the beta.
If the schemas differ, the human reviews and deploys the change in CloudKit Console using the
linked runbook, then reruns the comparison and Production postflight before uploading.

`verify_export`, `beta`, and `release` preflight the standalone xcbeautify binary. The beta lane
uploads to TestFlight and then publishes dSYMs; the release lane uploads metadata, screenshots,
and the binary, confirms submission for review, and then publishes dSYMs.

The Require Device Unlock setting for Siri and Shortcuts was accepted without a physical-device test because Siri was unusable on the maintainer's device; enforcement by iOS remains unverified.

`update_screenshots` requires a clean `main` checkout, the framed screenshots validated by the lane,
and an existing editable App Store Connect version. It uses the ASC credentials from 1Password to
replace draft screenshots, skipping binary, metadata, and app-version updates. Overwrite deletes
**all device screenshot sets in each uploaded locale** before uploading their replacements. The lane
never submits for review and does not immediately change the live App Store listing shown to
TestFlight testers. Its first live run is performed by the human.

## Format Swift

Configuration lives in `.swift-format`; the pre-commit hook formats staged Swift files.

```bash
brew install swift-format ripgrep xcbeautify
swift-format --in-place --recursive .
swift-format lint --recursive .
```

## Script Safety

New or modified scripts must validate external dependencies with `command -v` and a named nonzero
failure before touching shared state. They fail closed when a check cannot run, input is unreadable,
or output is unparseable. They propagate the exact child status through pipelines and wrappers,
verify effects rather than text forms for important invariants such as simulator-clone census, and
put mandatory guards in build phases or scripts rather than only Git hooks because API commits
bypass hooks.
