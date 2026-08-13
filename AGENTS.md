# Family Foqos Developer Guidelines

This always-loaded file is the invariant sheet for agentic work in Family Foqos. Follow its linked runbooks when a task enters that area.

## Engineering Invariants

- Keep implementations DRY and KISS; in general, apply YAGNI.
- Never amend or force commits. Put every fix in a new signed commit; revert with a new commit when needed.
- Obtain independent code review before every merge. The planner merges unless the active workflow explicitly names another merger.
- At fleet/session startup while the human is present, the planner dispatches `scripts/warm-git-credentials.sh` to every implementation stream; each stream runs it in its clean assigned feature worktree before taking implementation work, and reruns it only if signing or SSH approval expires mid-session while the human is present.
- The gate supports up to three Xcode/simulator streams when all simulator work uses `scripts/xcode-stream.sh --agent <agent> --session <session>` with stable ownership and UUID destinations only, never device-name destinations; it injects `-parallel-testing-enabled NO` and `-disable-concurrent-destination-testing`.
- Keep implementation streams on separate feature branches/worktrees with disjoint files. Read-only work does not consume a gate slot and may run concurrently from another working copy.

See [Development Workflow](docs/development-workflow.md) for credential fallback, simulator ownership, command rationale, and complete build/test/format guidance.

## Script Safety

- Validate external dependencies with `command -v` and a named nonzero failure before touching shared state.
- Fail closed when a check cannot run or input/output is unusable; never interpret that as a pass.
- Propagate the exact child exit status through every pipeline and wrapper.
- Verify effects rather than text forms when an invariant matters, including simulator-clone checks.
- Put mandatory guards in build phases or scripts, never only Git hooks, because API commits bypass hooks.

## Multi-Agent Coordination

- Route human gates through the planner; never park `gate/*` approvals in AMQ `user`, and send `blocked on human gate: <what>` on the normal planner thread.
- After 30 quiet minutes with in-flight work, the planner drains its inbox, inspects the agent's `inbox/new`, sweeps `user`, checks commit age/dirty files/CPU delta, then pings directly.
- `notifier_live` proves only that the wake process runs; never treat it as work or progress evidence.
- Announce every wait for a gate, review, or dependency when it begins.
- A PR reported approved or merge-ready must already be ready for review and must not be a draft.
- Never end with only promised future work; state exactly what remains, and use commit age, dirty files, and CPU delta—not message recency—as evidence.

See [Multi-Agent Coordination](docs/multi-agent-coordination.md) for gate examples, heartbeat diagnostics, CPU recipes, and calibrated operator-doc sign-off.

## Build, Test, and Format Commands

- Build: `scripts/xcode-stream.sh --agent <agent> --session <session> --xcbeautify -- xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug build`
- Clean only the owner's DerivedData: `scripts/xcode-stream.sh --agent <agent> --session <session> -- scripts/clean-build.sh`
- Test all: `scripts/xcode-stream.sh --agent <agent> --session <session> -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos`
- Test one class: append `-only-testing:FoqosTests/ClassName` to the test command.
- Screenshots: `scripts/xcode-stream.sh --agent <agent> --session <session> -- scripts/fastlane.sh screenshots`
- Archive and upload lanes do not boot simulators: run them through `scripts/fastlane.sh` without the simulator gate.
- Put `xcodebuild` directly after the wrapper's `--`; never insert `xcrun`, `env`, `bundle`, a shell, your own destination, or your own DerivedData path.
- Format: `swift-format --in-place --recursive .`; lint: `swift-format lint --recursive .` (install with `brew install swift-format ripgrep xcbeautify`).

## Swift and Test Invariants

- Use 2-space indentation, follow `.swift-format`, and keep imports grouped/alphabetized with unused imports removed.
- In views, use `@SafeQuery`, never raw `@Query`; for received persistent-model arrays, iterate `.valid`.
- Save SwiftData mutations with `context.save()` and surface descriptive errors.
- Use privacy-focused `Log`, never `print`; never log passwords, lock codes, or personal identifiers.
- Pin time in tests: call `Date()` once per test, derive other dates, and inject `now:` into the method under test.

See [Swift Style Guide](docs/swift-style-guide.md) for naming, SwiftUI/SwiftData patterns, logging categories, examples, architecture, and testing practices.

## App Modes and Locking

- Individual has no lock code and creates only unlocked items; Parent may set a code/create locked items and has full access; Child receives the code, creates only unlocked items, and is blocked by locked items.
- Lock restrictions apply only when `appModeManager.currentMode == .child`, never by checking `!= .parent`.
- Parent lock toggles require `appModeManager.currentMode == .parent && lockCodeManager.hasAnyLockCode`; Child verification requires `item.isLocked && appModeManager.currentMode == .child`.
- Individual-to-Parent lock-code setup must keep the `setLockCode` guard `!= .child`; requiring `== .parent` deadlocks promotion.

See [App Modes and Locking](docs/app-modes-and-locking.md) for the full matrix, promotion rationale, and UI rules.
