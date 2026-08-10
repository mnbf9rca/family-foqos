# Family Foqos Developer Guidelines

This file provides guidelines for agentic coding assistants working on the Family Foqos iOS app codebase.

## Key rules agents often forget but must ALWAYS follow:

  - **NEVER** force commit or amend commits. Ever. Always create new commits for fixes, and use Git's revert feature to undo changes if needed. This preserves the integrity of the commit history and allows for proper code review.
  - **ALWAYS request code review before merging any changes.** This ensures that all changes are vetted for quality, correctness, and adherence to project standards.
  - **WARM GIT CREDENTIALS BEFORE ANY IMPLEMENTATION WORK.** At session start, while the human
    is present, every implementation subagent must warm both 1Password-backed Git paths in its
    clean assigned worktree before real work. Run this block so commit-signing and SSH prompts
    happen while the human can touch the sensor:

    ```bash
    (
      set -e
      test -z "$(git status --porcelain)"
      start_branch="$(git branch --show-current)"
      test -n "$start_branch"
      case "$(git remote get-url --push origin)" in git@*|ssh://*) ;; *) exit 1 ;; esac
      scratch="scratch/biometric-warmup/$(date -u +%Y%m%dT%H%M%SZ)-$$"
      git switch -c "$scratch"
      trap 'git switch "$start_branch"; git branch -D "$scratch"' EXIT
      git commit -S --allow-empty -m "chore: biometric warm-up (discard)"
      git push --dry-run origin "HEAD:refs/heads/$scratch"
    )
    ```

    The dry run must use the SSH push URL and must not create a remote ref. Start real work only
    after the block succeeds and the assigned worktree is back on its starting branch and clean.

    If signing or SSH approval expires mid-session, rerun the block while the human is present. If
    the human is absent, commit-only work may use the authorized GitHub `createCommitOnBranch` API
    when one server-side commit exactly represents the change; otherwise wait. Never disable
    signing, create an unsigned production commit, amend, or force-push to evade a prompt.

    The separate `op` prompt is handled by #365's service-account credential path, not this Git
    warm-up.

  - **All simulator builds and tests use the machine-wide gate.** The host supports up to three
    Xcode/simulator streams when every stream enters through `scripts/xcode-stream.sh`. The gate
    assigns a distinct simulator UUID, DerivedData directory, and capacity slot to each exact
    `(project, agent, session)` owner. UUID destinations only; device-name destinations are
    forbidden. The wrapper injects `-parallel-testing-enabled NO` and
    `-disable-concurrent-destination-testing` to prevent XCTestDevices clones. Writing streams
    still use separate feature branches/worktrees and disjoint file sets.
    Read-only work does not consume a gate slot and may run concurrently from its own working copy.

## Build & Test Commands

### Building

Agents must not invoke raw `xcodebuild` for simulator work. Give every stream a stable agent name
and optional session name, then use the wrapper. It allocates or reuses the registry-owned iPhone
17 on the newest compatible installed iOS runtime. Set `IOS_SIM_GATE_DEVICE_TYPE` or
`IOS_SIM_GATE_RUNTIME` only when the task requires an override.
Always place `xcodebuild` directly after the wrapper's `--`; never mediate it through `xcrun`,
`env`, `bundle`, or a shell command.

```bash
# Preserve xcodebuild's status when formatting output.
set -o pipefail

# Build from command line
scripts/xcode-stream.sh --agent <agent> --session <session> -- \
  xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -configuration Debug build 2>&1 | bundle exec xcpretty

# Clean only this owner's gate-assigned DerivedData.
scripts/xcode-stream.sh --agent <agent> --session <session> -- scripts/clean-build.sh
```

The screenshots lane also boots a simulator, so gate its entire process tree:

```bash
scripts/xcode-stream.sh --agent <agent> --session <session> -- \
  scripts/fastlane.sh screenshots
```

Archive and upload lanes do not boot simulators and remain unchanged; run them through
`scripts/fastlane.sh` without the simulator gate.

### Running Tests
The project has unit tests in the `FoqosTests` target.

**Never pass a destination or DerivedData path yourself.** The wrapper injects the exact registered
UUID and owner-scoped DerivedData. A device-name destination can create a new simulator under
`~/Library/Developer/XCTestDevices/` on every invocation, consuming about 16 GB each.

```bash
# Run all tests. The wrapper injects UUID destination, DerivedData, and no-clone flags.
scripts/xcode-stream.sh --agent <agent> --session <session> -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos

# Run a single test class.
scripts/xcode-stream.sh --agent <agent> --session <session> -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/ClassName
```

The first run may spend several minutes booting the simulator. Later runs with the same exact
agent/session owner reuse its registered UUID. Do not boot, clone, erase, or delete that simulator
outside the wrapper.

### Code Formatting
The project uses swift-format to maintain consistent code style. Configuration is in `.swift-format` at the repo root. A pre-commit hook auto-formats staged Swift files.

**Prerequisite:** Install swift-format: `brew install swift-format`

```bash
# Format all Swift files
swift-format --in-place --recursive .

# Check for formatting violations without making changes
swift-format lint --recursive .
```

## Code Style Guidelines

### Formatting & Indentation
- **Indentation**: 2 spaces (no tabs)
- **Line width**: Prefer 100-120 characters max
- **Trailing whitespace**: Remove all trailing whitespace
- **Blank lines**: One blank line between functions, two between major sections

### Imports
- Place at the top of each file
- Group alphabetically (system frameworks first, then third-party)
- Separate groups with blank lines
- Remove unused imports

```swift
import DeviceActivity
import FamilyControls
import SwiftUI
import WidgetKit
```

### Naming Conventions
- **Types** (struct, class, enum): PascalCase
  - Views: PascalCase + "View" suffix (e.g., `HomeView`, `ActionButton`)
  - Managers: PascalCase + "Manager" suffix (e.g., `StrategyManager`)
  - Utilities: PascalCase + "Util" suffix (e.g., `TimersUtil`)
  - Models: PascalCase (e.g., `BlockedProfiles`)
- **Functions/Methods**: camelCase, verb-based (e.g., `startBlocking`, `stopBlocking`)
- **Variables/Properties**: camelCase
- **Constants**: camelCase (not UPPER_CASE)
- **Booleans**: Prefix with `is`, `has`, `enable`, `allow` (e.g., `isActive`, `hasPermission`)
- **Private properties**: camelCase, no underscore prefix
- **Static properties**: camelCase or PascalCase based on usage
- **UserDefaults keys**: Use `family_foqos_` prefix (e.g., `family_foqos_app_mode`)

### SwiftUI Patterns
- Use `@State` for local view state
- Use `@Binding` for parent-child data flow
- Use `@Environment(\.keyPath)` for environment values
- Use `@EnvironmentObject` for shared state managers
- Use `@SafeQuery` for SwiftData queries (never raw `@Query`)
- Prefer trailing closure syntax for view modifiers

```swift
@State private var isPresenting = false
@Environment(\.modelContext) private var context
@EnvironmentObject var strategyManager: StrategyManager
@SafeQuery(sort: \BlockedProfiles.order) private var profiles: [BlockedProfiles]
```

### SwiftData Patterns
- Mark models with `@Model`
- Use `@Attribute(.unique)` for unique identifiers
- Use `@Relationship` for relationships between models
- Use `#Predicate` for complex queries
- Always call `context.save()` after modifications

```swift
@Model
class BlockedProfiles {
  @Attribute(.unique) var id: UUID
  @Relationship var sessions: [BlockedProfileSession] = []
}
```

### SwiftData Safety with @SafeQuery

Always use `@SafeQuery` instead of `@Query` in views. `@SafeQuery` is a `DynamicProperty` wrapper (defined in `Foqos/Utils/SafeQuery.swift`) that auto-filters deleted SwiftData models, preventing `EXC_BREAKPOINT` crashes from zombie objects.

```swift
// CORRECT - auto-filters deleted models
@SafeQuery(sort: \BlockedProfiles.order) private var profiles: [BlockedProfiles]

// WRONG - can crash; also rejected by pre-commit hook
@Query(sort: \BlockedProfiles.order) private var profiles: [BlockedProfiles]
```

`@SafeQuery` mirrors the `@Query` initializers used in this codebase (excluding `animation:` and `transaction:` parameters). Use it the same way, including underscore-init for dynamic predicates:

```swift
_sessions = SafeQuery(
  filter: #Predicate<BlockedProfileSession> { $0.blockedProfile.id == profileId },
  sort: \BlockedProfileSession.startTime,
  order: .reverse
)
```

**For non-query contexts** (components receiving arrays as parameters), use the `.valid` extension:

```swift
// In components that receive [PersistentModel] arrays (not @SafeQuery)
ForEach(profiles.valid) { profile in
  ProfileCard(profile: profile)
}
```

### Protocols & Strategy Pattern
- Define clear protocols for extensible behavior
- Protocol methods should be minimal and focused
- Use associated types or generic constraints when appropriate
- Strategy implementations return optional views for custom UI

```swift
protocol BlockingStrategy {
  static var id: String { get }
  var name: String { get }
  func startBlocking(context: ModelContext, profile: BlockedProfiles, forceStart: Bool?) -> (any View)?
  func stopBlocking(context: ModelContext, session: BlockedProfileSession) -> (any View)?
}
```

### Error Handling
- Use `try-catch` for throwing functions
- Provide descriptive error messages for user feedback
- Use `fatalError()` only for truly unrecoverable states (e.g., ModelContainer initialization)
- Use `Log.debug()` for debugging instead of print()

```swift
do {
  try context.save()
} catch {
  errorMessage = "Failed to save changes: \(error.localizedDescription)"
}
```

### Logging

The app uses a custom privacy-focused logging framework. Use `Log` instead of `print()`:

```swift
import Foundation  // Log is available globally

// Use appropriate level and category
Log.debug("Button tapped", category: .ui)
Log.info("Session started for profile: \(profileId)", category: .session)
Log.warning("Sync conflict detected", category: .sync)
Log.error("Failed to save: \(error.localizedDescription)", category: .cloudKit)
```

**Log Levels:**
- `debug`: Detailed debugging info (hidden in production)
- `info`: Normal operations worth noting
- `warning`: Potential issues that don't block functionality
- `error`: Failures that need attention

**Log Categories:**
- `.app` - General app lifecycle
- `.cloudKit` - CloudKit operations
- `.sync` - Profile/session sync
- `.strategy` - Blocking strategy operations
- `.session` - Session lifecycle
- `.ui` - User interface events
- `.location` - Geofence/location
- `.nfc` - NFC operations
- `.timer` - Timer/scheduling
- `.authorization` - FamilyControls auth
- `.liveActivity` - Live Activity widgets
- `.familyControls` - Device restrictions

**Privacy:**
- Never log passwords, lock codes, or personal identifiers
- Profile names are acceptable (user-defined)
- UUIDs and timestamps are acceptable
- Users can export and share logs via:
  - Home → version footer "Debug mode" link (when profile active) → Export Logs
  - Settings → Diagnostics → Debug Mode → Export Logs

### Control Flow
- Use `guard` for early returns and validation
- Prefer early returns over nested if statements
- Use optional chaining extensively
- Use nil-coalescing operator `??` for default values

```swift
guard let profile = try? BlockedProfiles.findProfile(byID: id, in: context) else {
  errorMessage = "Profile not found"
  return
}
```

### Computed Properties
- Use computed properties instead of functions when no parameters are needed
- Keep computed properties lightweight
- Avoid side effects in computed properties

```swift
var isBlocking: Bool {
  return activeSession?.isActive == true
}
```

### Closures
- Prefer trailing closure syntax
- Mark closure parameters with `@escaping` when stored
- Use weak references in closures to avoid retain cycles in classes

```swift
strategy.onSessionCreation = { [weak self] status in
  self?.handleSessionStatus(status)
}
```

### Comments
- Comments are minimal; let code be self-documenting
- Use comments to explain "why", not "what"
- Comment sections of related functionality
- Document complex business logic or workarounds

### Previews
- Include `#Preview` blocks for SwiftUI views
- Create realistic preview data
- Use separate UserDefaults for previews

```swift
#Preview {
  HomeView()
    .environmentObject(RequestAuthorizer())
    .defaultAppStorage(UserDefaults(suiteName: "preview")!)
}
```

### Architectural Patterns
- Use singleton pattern for shared managers via `static let shared`
- Dependency injection via environment objects
- Repository-like static methods on models for data operations
- Coordinator pattern for complex flows (StrategyManager)

### File Organization
- Group related files in subdirectories (Views/, Models/, Components/, Utils/)
- One public type per file when possible
- Private types can be in same file
- Extensions on types should be in separate files or grouped logically

## Testing Best Practices (When Adding Tests)
- Test public interfaces, not private implementation
- Use async/await for async operations
- Mock dependencies for unit tests
- Test both success and failure paths
- Name tests descriptively: `testGivenX_WhenY_ThenZ()`
- Pin time in tests: never call `Date()` more than once per test. Capture a single `let now = Date()` and derive all other dates from it. Inject `now` into the method under test via `now:` parameters. This prevents flaky failures from clock drift between independent `Date()` calls.

## App Modes & Lock Code Behavior

The app has three operating modes with distinct lock code behaviors:

| Mode | Lock Code | Can Create Unlocked Items | Can Create Locked Items | Blocked by Locked Items |
|------|-----------|--------------------------|------------------------|------------------------|
| **Individual** | None possible | Yes | No | No |
| **Parent** | Can SET code | Yes | Yes | No (full access) |
| **Child** | Synced from parent | Yes | No | Yes (requires code) |

> **Individual → Parent promotion:** an Individual device can set a lock code via the Family
> Controls Dashboard (the only user-initiated path to Parent — `ModeSelectionView` offers only
> Individual/Child). Doing so **promotes the device to Parent** in the same action, so the
> "Individual: Can Create Locked Items = No" invariant holds — a device never persists as
> Individual *with* a lock code. The `setLockCode` guard therefore stays `!= .child` (not
> `== .parent`), otherwise the promotion would deadlock.

### Critical Rule for Lock Checks

When checking if lock code restrictions apply:
- **CORRECT:** `appModeManager.currentMode == .child`
- **WRONG:** `appModeManager.currentMode != .parent`

The wrong pattern blocks both Individual AND Child modes. Only Child mode should be blocked by lock codes.

### When to Show Lock-Related UI

- **Lock toggles** (to create locked items): Show only in Parent mode
  ```swift
  appModeManager.currentMode == .parent && lockCodeManager.hasAnyLockCode
  ```

- **Lock verification prompts** (to edit/delete locked items): Show only in Child mode
  ```swift
  item.isLocked && appModeManager.currentMode == .child
  ```

## Build Output

When formatting a gated xcodebuild, enable `pipefail` so the command retains xcodebuild's status:

```bash
set -o pipefail
scripts/xcode-stream.sh --agent <agent> --session <session> -- \
  xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -configuration Debug build 2>&1 | bundle exec xcpretty
```
