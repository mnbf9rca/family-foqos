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

At session start, while the human is present, every implementation stream runs this in its clean
assigned feature worktree:

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
session; later runs by the same owner reuse its registered UUID.

UUID destinations only. Never pass a device-name destination: it can create a simulator under
`~/Library/Developer/XCTestDevices/` on every invocation and consume about 16 GB. Never pass a
destination or DerivedData path yourself. Do not boot, clone, erase, or delete a gate-owned
simulator outside the wrapper. The wrapper injects `-parallel-testing-enabled NO` and
`-disable-concurrent-destination-testing` to prevent XCTestDevices clones.

Set `IOS_SIM_GATE_DEVICE_TYPE` or `IOS_SIM_GATE_RUNTIME` only when the task requires an override.
Always put `xcodebuild` directly after the wrapper's `--`; do not mediate it through `xcrun`, `env`,
`bundle`, or a shell command. Wrapper-owned formatting preserves the exact child status without
depending on caller shell options.

## Build and Clean

```bash
scripts/xcode-stream.sh --agent <agent> --session <session> --xcpretty -- \
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

## Screenshots, Archives, and Uploads

The screenshots lane boots a simulator, so gate its entire process tree:

```bash
scripts/xcode-stream.sh --agent <agent> --session <session> -- \
  scripts/fastlane.sh screenshots
```

Archive and upload lanes do not boot simulators. Run them through `scripts/fastlane.sh` without the
simulator gate.

## Format Swift

Configuration lives in `.swift-format`; the pre-commit hook formats staged Swift files.

```bash
brew install swift-format ripgrep
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
