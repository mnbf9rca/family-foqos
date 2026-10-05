# Development Workflow

The root `AGENTS.md` carries the common-case commands and non-negotiable invariants. This runbook explains credential preparation, implementation isolation, simulator ownership, safe scripts, and build/test/format behavior.

## Keep Changes Small and Reviewable

Keep implementations DRY and KISS and, in general, apply YAGNI. Never force-push or amend a commit. Create a new signed commit for each fix; use Git revert when history must be undone. Always obtain independent code review before merge.

Concurrent streams use separate feature worktrees with disjoint files; read-only work needs no gate slot. Sequential shared-file slices may stack within one stream, with plans carried in implementation PRs and signed merges instead of rebase/force; see [Merge Readiness](multi-agent-coordination.md#report-merge-readiness-literally).

## Warm Git Credentials

At fleet/session startup, while the human is present, the orchestrator dispatches this warm-up to every implementation stream. Each stream runs it in its clean assigned feature worktree before taking implementation work:

```bash
scripts/warm-git-credentials.sh
```

The script fails closed unless the worktree is clean, the current branch is a named feature branch, and `origin` has an SSH push URL. It creates a unique scratch branch, makes a signed empty scratch commit, performs an SSH push dry-run, restores the starting branch, deletes the scratch branch, and verifies the final branch/tree. The dry run creates no remote ref.

The orchestrator dispatches a rerun only when signing or SSH approval expires and the human is present for biometric approval. If the human is absent, commit-only work may use the authorized GitHub `createCommitOnBranch` API when one server-side commit exactly represents the change; otherwise wait. Never disable signing, create an unsigned production commit, amend, or force-push to evade a prompt. The separate `op` prompt uses #365's service-account path, not this Git warm-up.

## Simulator Ownership

Every simulator process tree enters through `scripts/xcode-stream.sh`; the machine-wide gate supports three streams and assigns each `(project, agent, session)` a distinct UUID, DerivedData, and capacity slot. Use your Herdr name with `--session collab`, a stable ownership label rather than a Herdr session ID; subsequent runs reuse that owner’s simulator.

UUID destinations only. Never pass a device-name destination: it can create a simulator under `~/Library/Developer/XCTestDevices/` on every invocation and consume about 16 GB. Never pass a destination or DerivedData path yourself. Do not boot, clone, erase, or delete a gate-owned simulator outside the wrapper. The wrapper injects `-parallel-testing-enabled NO` and `-disable-concurrent-destination-testing` to prevent XCTestDevices clones.

Set `IOS_SIM_GATE_DEVICE_TYPE` or `IOS_SIM_GATE_RUNTIME` only when the task requires an override. Always put `xcodebuild` directly after the wrapper's `--`; do not mediate it through `xcrun`, `env`, `bundle`, or a shell command. Wrapper-owned formatting preserves the exact child status without depending on caller shell options. Pass `--xcbeautify` to select formatting; the wrapper checks the standalone `xcbeautify` binary before acquiring the gate and owns the internal `xcodebuild 2>&1 | xcbeautify` pipeline.

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

The unit tests are in `FoqosTests`. The first run may spend several minutes booting the registered simulator; later runs reuse it.

```bash
scripts/xcode-stream.sh --agent <agent> --session <session> -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos

scripts/xcode-stream.sh --agent <agent> --session <session> -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/ClassName
```

After a failing test run, `xcodebuild` can appear stalled while an asynchronous `simctl diagnose` collection waits up to ten minutes; waiting for it to finish is a safe alternative to stopping it. Confirm XCTest has finished, then trace the diagnose/collector PIDs through their parent chain to your own gate-owned `xcodebuild`, matching its owner DerivedData path and simulator UUID. Send `kill <pid>` (SIGTERM) only to the exact diagnose/collector PIDs whose ownership you proved; never match processes by name. Never stop another stream's processes, the `xcodebuild`, or the gate wrapper; if ownership cannot be established, do not stop the process. Wait for the original command to exit and preserve its exit status; completed test output alone is not a successful command result.

## Agent Acceptance Runbooks

Agents verify UI themselves using [Verify UI Changes in the Simulator](simulator-ui-verification.md), including throwaway drivers, inspected screenshots, and restoration. For source-built V1 → V2 acceptance, follow the [upgrade runbook](v1-v2-upgrade-runbook.md): generate the matrix, compile fixtures before touching data, and report evidence to the orchestrator.

Each PR runs affected checks on its agent’s normal simulator. Once per release candidate, run the full unit suite, upgrade runbook, and UI checks on iOS 27 plus the newest available iOS 26 simulator runtime (currently 26.5), per the [coverage ruling](https://github.com/mnbf9rca/family-foqos/issues/506#issuecomment-5973757793). Coverage uses the agent’s `collab` owner and an orchestrator-authorized second `collab-ios27` owner created with an installed iOS 27 runtime override when needed; record `IOS_SIM_GATE_RUNTIME_VERSION` inside each gate, because an existing owner’s runtime does not change with an override.

The human performs only genuinely device-only checks, once on the release-candidate TestFlight build after all work merges, on iOS 27; never per PR or slice. See the [recorded ruling](https://github.com/mnbf9rca/family-foqos/issues/507#issuecomment-5973689700).

## Screenshots, Archives, and Uploads

The Family Controls screenshot demo has no live CKShare identities, so its member list shows “Parent”, “Child”, and “Child” rather than the former synthetic names Alex, Emma, and Sam.

The screenshots lane boots a simulator, so gate its entire process tree:

```bash
scripts/xcode-stream.sh --agent <agent> --session <session> -- \
  scripts/fastlane.sh screenshots
```

V1 (release/v1) receives no entitlement changes; fixes such as the iOS 26 share entitlement ship in V2 only.

Archive and upload lanes do not boot simulators. Run them through `scripts/fastlane.sh` without the simulator gate:

```bash
# Archive and export only; performs no TestFlight, App Store, or GitHub upload.
scripts/fastlane.sh verify_export

# Upload lanes.
scripts/fastlane.sh beta
scripts/fastlane.sh release
scripts/fastlane.sh update_screenshots
```

Before every beta, compare live Production and Development schemas. Development must hold the canonical schema imported by an agent [after merge](cloudkit-production-schema.md#1-routine-schema-change--coding-agents). Run this read-only comparison with authenticated `cktool`:

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

Only matching, nonempty exports pass. An export failure or any difference blocks the beta. If the schemas differ, the human reviews and deploys the change in CloudKit Console using the linked runbook, then reruns the comparison and Production postflight before uploading.

`verify_export`, `beta`, and `release` preflight the standalone xcbeautify binary. The beta lane uploads to TestFlight and then publishes dSYMs; the release lane uploads metadata, screenshots, and the binary, confirms submission for review, and then publishes dSYMs.

The Require Device Unlock setting for Siri and Shortcuts was accepted without a physical-device test because Siri was unusable on the maintainer's device; enforcement by iOS remains unverified.

`update_screenshots` requires a clean `main` checkout, the framed screenshots validated by the lane, and an existing editable App Store Connect version. It uses the ASC credentials from 1Password to replace draft screenshots, skipping binary, metadata, and app-version updates. Overwrite deletes **all device screenshot sets in each uploaded locale** before uploading their replacements. The lane never submits for review and does not immediately change the live App Store listing shown to TestFlight testers. Its first live run is performed by the human.

## Format Swift

Configuration lives in `.swift-format`; the pre-commit hook formats staged Swift files.

```bash
brew install swift-format ripgrep xcbeautify
swift-format --in-place --recursive .
swift-format lint --recursive .
```

## Script Safety

Follow `AGENTS.md` Script Safety: validate dependencies before shared state, fail closed on unusable checks/input/output, propagate exact child status, verify effects (including clone census), and enforce guards in scripts/build phases because API commits bypass hooks. Investigate unexplained failures through [early online research](multi-agent-coordination.md#investigate-unexplained-behavior).
