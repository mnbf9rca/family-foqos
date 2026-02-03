# Family Foqos Developer Guidelines

This file provides guidelines for agentic coding assistants working on the Family Foqos iOS app codebase.

## Build & Test Commands

### Building

Use `xcpretty` to simplify output.

```bash
# Open in Xcode
open FamilyFoqos.xcodeproj

# Build from command line
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug build | xcpretty
```

### Running Tests
The project has unit tests in the `FoqosTests` target. Run tests using:
```bash
# Run all tests
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,name=iPhone 17' | xcpretty

# Run a single test class
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FoqosTests/ClassName | xcpretty
```

### Code Formatting
The project uses swift-format to maintain consistent code style. Run format commands before committing:
```bash
# Format all Swift files
swift-format .

# Format specific files or directories
swift-format Foqos/Views/

# Check formatting without making changes
swift-format --dry-run .

# Format in recursive mode
swift-format --recursive .
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
- Use `@Query` for SwiftData queries
- Prefer trailing closure syntax for view modifiers

```swift
@State private var isPresenting = false
@Environment(\.modelContext) private var context
@EnvironmentObject var strategyManager: StrategyManager
@Query(sort: \BlockedProfiles.order) private var profiles: [BlockedProfiles]
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

### SwiftData Safety with @Query

When iterating `@Query` results with `ForEach`, use the `.valid` extension to filter out deleted models. This prevents crashes when models are deleted via CloudKit sync while the app is in the background.

```swift
// CORRECT - filters out deleted models
ForEach(profiles.valid) { profile in
  ProfileCard(profile: profile)
}

// WRONG - can crash if a model was deleted but @Query hasn't updated yet
ForEach(profiles) { profile in
  ProfileCard(profile: profile)
}
```

**Why this matters:** When a SwiftData model is deleted, its `modelContext` becomes `nil`, but `@Query` may still hold a reference to it. Accessing properties on a deleted model causes `EXC_BREAKPOINT`. The `.valid` extension (defined in `Utils/Extensions.swift`) filters these out:

```swift
extension Array where Element: PersistentModel {
  var valid: [Element] { filter { $0.modelContext != nil } }
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

## App Modes & Lock Code Behavior

The app has three operating modes with distinct lock code behaviors:

| Mode | Lock Code | Can Create Unlocked Items | Can Create Locked Items | Blocked by Locked Items |
|------|-----------|--------------------------|------------------------|------------------------|
| **Individual** | None possible | Yes | No | No |
| **Parent** | Can SET code | Yes | Yes | No (full access) |
| **Child** | Synced from parent | Yes | No | Yes (requires code) |

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

When running xcodebuild commands, pipe output through xcpretty for cleaner build status:
```bash
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug build 2>&1 | xcpretty
```
