# Agent-run V1 → V2 source upgrade verification

An agent runs this procedure and reports the result. The human does not create profiles, execute the matrix, or interpret simulator output. Use it before a release candidate and after changing migration, shared snapshots, tag routing, or session starts/stops.

This builds V1 **1.31.3 from `589bee9`** as a proxy for the App Store app, generates its actual on-disk store and shared JSON, and installs the chosen V2 revision over that data. It is not the physical App Store → TestFlight check: signed reader handoffs, real Screen Time shields, OS callback delivery and cross-device iCloud still require the RC device checklist.

## Contract and coverage

The agent owns one **disposable test app** on its assigned simulator. `prepare` backs up the previous app data and group, uninstalls that app and clears its backed-up store/preferences remnants. It does not erase the simulator, remove other apps, or use a device supplied by the reader. If existing app data is not known to be disposable, stop and route that decision through the orchestrator. All device operations, including backups, captures and version reads, enter through `scripts/xcode-stream.sh` with the same agent and `collab` session.

The matrix lives in [V1UpgradeSeedTests.swift](fixtures/V1UpgradeSeedTests.swift); its checks live in [V2UpgradeVerificationTests.swift](fixtures/V2UpgradeVerificationTests.swift). Keep them together when adding cases. They generate fresh IDs/timestamps and cover conversion, retained settings, active-session identity and deferred conversion, scan starts/stops, legacy background identities, saved Shortcut timer duration and retained-but-invalid profiles. Expected behavior comes from [the conditions rulebook](superpowers/specs/2026-10-02-508-v2-conditions-rulebook.md) and the [#507 rulings](https://github.com/mnbf9rca/family-foqos/issues/507). The output JSON names each seeded profile and its resulting configuration.

The drivers are documentation fixtures, not normal test-target members. **Every run must first compile both in throwaway worktrees, before changing simulator app data.** An API mismatch means **“fixtures out of date: update them in a PR”**. Preserve the failing log, update the fixture through review, and rerun; never skip cases or weaken expectations to produce a pass. A gate/tool/build-environment failure is also a failed preflight, not proof of fixture drift or an upgrade pass.

## 1. Pin inputs, create throwaway worktrees, compile fixtures

Run in Bash from a clean checkout containing this runbook and helper. Replace `<agent>` with your own assigned fleet identity; an unchanged placeholder stops before creating worktrees or touching the simulator. `HEAD` is the V2 revision under test; use another reviewed commit if the task names one. Never test a moving branch without recording its resolved commit.

```bash
set -euo pipefail
for tool in git python3 xcodebuild xcrun plutil xcbeautify swift-format mktemp mkdir cp rm; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 127; }
done
export UPGRADE_AGENT='<agent>'
[ "$UPGRADE_AGENT" != '<agent>' ] && [ -n "$UPGRADE_AGENT" ] || {
  echo 'Replace <agent> with your assigned fleet identity; never borrow another stream' >&2; exit 1;
}
export UPGRADE_REPO=$(git rev-parse --show-toplevel)
[ -z "$(git status --porcelain)" ] || { echo 'Start from a clean checkout' >&2; exit 1; }
git check-ignore -q .worktrees/ || { echo '.worktrees must already be ignored' >&2; exit 1; }
git fetch origin main release/v1
export UPGRADE_TARGET=$(git rev-parse HEAD)
export UPGRADE_V1_SHA=$(git rev-parse '589bee9^{commit}')
export UPGRADE_RUN=$(mktemp -d /private/tmp/family-foqos-v1-v2.XXXXXX)
export UPGRADE_GATE="$UPGRADE_REPO/scripts/xcode-stream.sh"
export UPGRADE_STATE="$UPGRADE_REPO/scripts/v1-v2-upgrade-state.py"
export UPGRADE_V1="$UPGRADE_REPO/.worktrees/$UPGRADE_AGENT-v1-${UPGRADE_RUN##*.}"
export UPGRADE_V2="$UPGRADE_REPO/.worktrees/$UPGRADE_AGENT-v2-${UPGRADE_RUN##*.}"
for name in UPGRADE_AGENT UPGRADE_REPO UPGRADE_TARGET UPGRADE_V1_SHA UPGRADE_RUN UPGRADE_GATE UPGRADE_STATE UPGRADE_V1 UPGRADE_V2; do
  printf 'export %s=%q\n' "$name" "${!name}"
done > "$UPGRADE_RUN/env.sh"
printf 'Saved run environment: %s\n' "$UPGRADE_RUN/env.sh"
printf 'V1=%s\nV2=%s\nAgent=%s\n' "$UPGRADE_V1_SHA" "$UPGRADE_TARGET" "$UPGRADE_AGENT" > "$UPGRADE_RUN/source-refs.txt"
git worktree add --detach "$UPGRADE_V1" "$UPGRADE_V1_SHA"
git worktree add --detach "$UPGRADE_V2" "$UPGRADE_TARGET"
cp "$UPGRADE_V1/FoqosTests/LogTailTests.swift" "$UPGRADE_RUN/original-LogTailTests.swift"
# V1 has explicit project membership: replace this existing test file temporarily.
cp "$UPGRADE_REPO/docs/fixtures/V1UpgradeSeedTests.swift" "$UPGRADE_V1/FoqosTests/LogTailTests.swift"
# V2 has a synchronized test directory: no project.pbxproj edit is needed.
[ ! -e "$UPGRADE_V2/FoqosTests/RCUpgradeVerificationTests.swift" ] || { echo 'Driver target already exists' >&2; exit 1; }
cp "$UPGRADE_REPO/docs/fixtures/V2UpgradeVerificationTests.swift" "$UPGRADE_V2/FoqosTests/RCUpgradeVerificationTests.swift"
"$UPGRADE_REPO/scripts/test-v1-v2-upgrade-state.sh"

(cd "$UPGRADE_V2"
 "$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session collab --xcbeautify -- \
  xcodebuild build-for-testing -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/RCUpgradeVerificationTests \
  > "$UPGRADE_RUN/preflight-v2.log" 2>&1) || {
 status=$?; echo 'V2 preflight failed; API mismatch means fixtures out of date: update them in a PR' >&2; exit "$status";
}
(cd "$UPGRADE_V1"
 "$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session collab --xcbeautify -- \
  xcodebuild build-for-testing -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:foqosTests/RCUpgradeSeedTests \
  > "$UPGRADE_RUN/preflight-v1.log" 2>&1) || {
 status=$?; echo 'V1 preflight failed; API mismatch means fixtures out of date: update them in a PR' >&2; exit "$status";
}
```

V1 uses the frozen lowercase `foqosTests` target; V2 uses `FoqosTests`. V2 compiles first so V1 remains the gate's last build product for `prepare`. The current wrapper is used from both worktrees because the frozen V1 checkout predates it. No custom destination or DerivedData argument is allowed.

Step 1 saves only the named `UPGRADE_*` variables to the printed `env.sh` path. Agent tool calls often start new shells: set `UPGRADE_ENV` to that exact path in each later shell before running its block. Do not source a past run or another agent’s environment file. Missing environment input stops the block.

## 2. Reset the disposable app, seed real V1 data, capture it

```bash
set -euo pipefail
: "${UPGRADE_ENV:?Set UPGRADE_ENV to the env.sh path printed by step 1}"
[ -f "$UPGRADE_ENV" ] || { echo 'Run environment file is missing' >&2; exit 1; }
source "$UPGRADE_ENV"
"$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session collab -- \
 python3 "$UPGRADE_STATE" prepare "$UPGRADE_RUN"
(cd "$UPGRADE_V1"
 "$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session collab --xcbeautify -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:foqosTests/RCUpgradeSeedTests -collect-test-diagnostics never \
  -resultBundlePath "$UPGRADE_RUN/v1-seed.xcresult" \
  > "$UPGRADE_RUN/v1-seed.log" 2>&1)
"$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session collab -- \
 python3 "$UPGRADE_STATE" capture-v1 "$UPGRADE_RUN"
```

Require the seed test to execute and pass, not merely compile. The helper records installed 1.31.3, checks the store belongs to this simulator, checks the shared active ID and profile IDs match the seed, rejects stale V2 keys and requires V1's omission of `oneMoreMinuteUsed`. It shuts down the owner before copying SQLite plus its sidecars and preferences. The fresh JSON is saved beside the container backups. Do not substitute a current-model encoder for the V1 writer: that would hide failures like [#537](https://github.com/mnbf9rca/family-foqos/issues/537).

## 3. Install V2 over the captured data and verify the matrix

Do **not** uninstall, clear preferences or restore a V2 store here. Clean only the owner's DerivedData before changing source versions; that leaves the V1 containers intact and avoids stale XCTest host/framework artifacts. Use `test`, not an unverified `test-without-building` product.

```bash
set -euo pipefail
: "${UPGRADE_ENV:?Set UPGRADE_ENV to the env.sh path printed by step 1}"
[ -f "$UPGRADE_ENV" ] || { echo 'Run environment file is missing' >&2; exit 1; }
source "$UPGRADE_ENV"
(cd "$UPGRADE_V2"
 "$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session collab -- \
  "$UPGRADE_REPO/scripts/clean-build.sh"
 "$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session collab --xcbeautify -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/RCUpgradeVerificationTests -collect-test-diagnostics never \
  -resultBundlePath "$UPGRADE_RUN/v2-upgrade.xcresult" \
  > "$UPGRADE_RUN/v2-upgrade.log" 2>&1)
"$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session collab -- \
 python3 "$UPGRADE_STATE" capture-v2 "$UPGRADE_RUN"
```

The first verification read checks the existing V1 session and shared JSON before migration. The fixture exercises the retained V1 scanner, then the production migration/start/stop APIs. Timer registration and restriction application are substituted because they cannot prove actual shielding or OS delivery in the simulator. Parser/producer and schedule behavior get their normal unit coverage next. A captured file is evidence, not an alternative to a passing executed test.

## 4. Run production regressions and report

The upgrade test consumes its one active V1 session, so exclude this temporary driver from the subsequent full unit suite.

```bash
set -euo pipefail
: "${UPGRADE_ENV:?Set UPGRADE_ENV to the env.sh path printed by step 1}"
[ -f "$UPGRADE_ENV" ] || { echo 'Run environment file is missing' >&2; exit 1; }
source "$UPGRADE_ENV"
(cd "$UPGRADE_V2"
 "$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session collab --xcbeautify -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests -skip-testing:FoqosTests/RCUpgradeVerificationTests \
  -collect-test-diagnostics never -resultBundlePath "$UPGRADE_RUN/v2-units.xcresult" \
  > "$UPGRADE_RUN/v2-units.log" 2>&1)
```

Confirm XCTest actually ran the seed, upgrade and production tests with zero failures. Preserve all logs, result bundles, source refs, installed-version manifests, original/captured shared JSON, container backups and `v2-app-data/Documents/rc-upgrade-verification.json`. Record the actual unit count and runtime from the results; historical counts are not acceptance criteria. Use the wrapper's UUID destination as simulator identity, not a device-name match.

Report to the orchestrator (and the release issue only when requested):

- Exact V1 and V2 commits, installed versions/builds, simulator UUID/OS and evidence directory.
- PASS/FAIL/UNRUN for source upgrade, each fixture profile, retained active session, decoder compatibility, scan identity, Shortcut timer and invalid conversion, plus the production unit result.
- The failing test/operation and original error if anything fails. Preserve that failed run, fix through the normal reviewed workflow, and use a fresh directory plus a fresh seed for the next attempt. Never overwrite a failure with a successful retry.
- Physical App Store → TestFlight, NFC radio/Camera/Code Scanner/signed Universal Links, actual timer/schedule shields and iCloud/device pairs remain human checks. Injected callbacks, bitmap decoding or Safari web fallback do not certify a physical handoff.

Do not report overall PASS if an operation was unavailable, output was malformed or tests did not execute. `-collect-test-diagnostics never` avoids Xcode's lengthy automatic simulator diagnosis after a failure; it does not ignore that failure.

## 5. Restore source files and remove only the created worktrees

Run cleanup after either success or failure. Do not reset someone else's worktree or erase their simulator. The state helper is deliberately not an automatic rollback of previous sessions: previous app/group backups remain in the evidence directory, and the disposable app keeps the tested V2 state.

```bash
set -euo pipefail
: "${UPGRADE_ENV:?Set UPGRADE_ENV to the env.sh path printed by step 1}"
[ -f "$UPGRADE_ENV" ] || { echo 'Run environment file is missing' >&2; exit 1; }
source "$UPGRADE_ENV"
if [ -d "$UPGRADE_V1" ] && [ -f "$UPGRADE_RUN/original-LogTailTests.swift" ]; then
  cp "$UPGRADE_RUN/original-LogTailTests.swift" "$UPGRADE_V1/FoqosTests/LogTailTests.swift"
fi
if [ -f "$UPGRADE_V2/FoqosTests/RCUpgradeVerificationTests.swift" ]; then
  rm -- "$UPGRADE_V2/FoqosTests/RCUpgradeVerificationTests.swift"
fi
for worktree in "$UPGRADE_V1" "$UPGRADE_V2"; do
  if [ -d "$worktree" ]; then
    [ -z "$(git -C "$worktree" status --porcelain)" ] || { echo "Worktree has additional changes: preserve and inspect $worktree" >&2; exit 1; }
    git worktree remove "$worktree"
  fi
done
```

If setup stopped before creating a file/worktree, clean only the artifacts that actually exist. Preserve the evidence directory until its report has been saved in the issue or PR. The checked-in runbook, helper and Swift fixtures are the reusable procedure; a past `/private/tmp` directory is never a prerequisite for a new run.
