# Family Foqos Developer Guidelines

This always-loaded file is the invariant sheet for agentic work in Family Foqos. Follow its linked runbooks when a task enters that area.

## Engineering Invariants

- Keep implementations DRY and KISS; in general, apply YAGNI.
- V2 start and stop conditions are independent; V1 strategy behaviour must not be reused. Follow the [V2 conditions rulebook](docs/superpowers/specs/2026-10-02-508-v2-conditions-rulebook.md); legacy data conversion does not give V1 behaviour authority over V2.
- Never amend or force commits. Put every fix in a new signed commit; revert with a new commit when needed.
- Obtain independent adversarial design review (correctness, over-engineering, missing cases that matter in practice) before implementation and independent code review before every merge. The orchestrator merges; operator and process docs require reviewer approval and green checks, while other PRs require the human’s approval of that specific PR.
- Warm each implementation stream’s Git credentials at startup while the human is present; follow [Development Workflow](docs/development-workflow.md#warm-git-credentials) for dispatch, expiry, and AFK rules.
- The gate supports up to three Xcode/simulator streams when all simulator work uses `scripts/xcode-stream.sh --agent <agent> --session <session>` with stable ownership and UUID destinations only, never device-name destinations; it injects `-parallel-testing-enabled NO` and `-disable-concurrent-destination-testing`.
- Keep concurrent implementation streams on separate feature branches/worktrees with disjoint files; sequential slices may stack within one stream. Read-only work needs no gate slot.

- Agents own simulator UI verification; follow [Development Workflow](docs/development-workflow.md#agent-acceptance-runbooks) for coverage and the single RC device pass.
- Schema-changing PRs require the post-merge Development import; follow [CloudKit Schema Upgrade](docs/cloudkit-production-schema.md); Production deployment belongs to the human.

See [Development Workflow](docs/development-workflow.md) for credentials, simulator ownership, and build/test/format guidance.

## Script Safety

- Validate external dependencies with `command -v` and a named nonzero failure before touching shared state.
- Fail closed when a check cannot run or input/output is unusable; never interpret that as a pass.
- Propagate the exact child exit status through every pipeline and wrapper.
- Verify effects rather than text forms when an invariant matters, including simulator-clone checks.
- Put mandatory guards in build phases or scripts, never only Git hooks, because API commits bypass hooks.

## Multi-Agent Coordination

- The fleet is one Herdr workspace with agents addressed by name: `orchestrator` (the human's proxy: dispatch, human gates, heartbeat, merges), `planner` (specs and plans only), `build1` and `build2` (implementation in their own worktrees), `reviewer` (design and code review), `auditor` (read-only audits and plan coverage; no repository artifacts).
- Every agent loads this file at startup; the orchestrator's first prompt names your role; read `docs/multi-agent-coordination.md` for that role's rules before taking work.
- Use role-prefixed Herdr messages; planner/reviewer review directly and notify the orchestrator at request and verdict, following [Messaging](docs/multi-agent-coordination.md#messaging).
- Route human gates through the orchestrator: send `<role>: blocked on human gate: <what>` to `orchestrator` and wait.
- The orchestrator records each human ruling on the relevant GitHub issue when made; every agent requires a recorded ruling before treating existing behaviour in a spec as a deliberate product decision.
- The orchestrator produces no repository artifacts, verifies claims through its own subagents rather than in its own context, and briefs agents with only the problem, the human's rulings, undiscoverable details, and how to report back.
- After 30 quiet minutes with in-flight work, the orchestrator checks the agent's Herdr state, has a subagent collect recent output, commit age, dirty files, and CPU delta, then prompts the agent unless it is blocked.
- Announce every wait for a gate, review, or dependency to the orchestrator when it begins.
- Research unexplained behavior online early; report source links with local evidence under [Investigation](docs/multi-agent-coordination.md#investigate-unexplained-behavior).
- A PR reported approved or merge-ready must already be ready for review and must not be a draft.
- Keep PR prose lean; send progress, packets, and long evidence directly to the orchestrator, following [Merge Readiness](docs/multi-agent-coordination.md#report-merge-readiness-literally).
- Never end with only promised future work; state exactly what remains, and use commit age, dirty files, and CPU delta as evidence, never message recency or Herdr's `agent_status`.

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
- Profiles, sessions, tags, and locations sync only within the owning iCloud account’s private database (`DeviceSync`), never across the family share. Parents do not push profiles, start/stop sessions, or scan for the child from their own device through family sharing; the child’s device scans its own NFC/QR tags.
- The family share (`FamilyPolicies`) carries only lock-code records (salted hash and scope metadata), `FamilyMember` rows, child-to-parent heartbeats, and the parent-to-child `resetEmergencyCount` and `resetLockCodeThrottle` commands. On a Child-mode device, the lock code gates only editing/deleting locked items and changes to locked emergency settings.

See [App Modes and Locking](docs/app-modes-and-locking.md) for the full matrix, promotion rationale, and UI rules.
