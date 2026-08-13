# Swift Style Guide

The root `AGENTS.md` carries the highest-risk invariants. Apply the complete conventions below to
Swift implementation and tests.

## Formatting and Imports

- Indent with 2 spaces, never tabs.
- Prefer 100–120 characters maximum line width.
- Remove trailing whitespace.
- Use one blank line between functions and two between major sections.
- Put imports at the top, group alphabetically with system frameworks before third-party modules,
  separate groups with a blank line, and remove unused imports.

```swift
import DeviceActivity
import FamilyControls
import SwiftUI
import WidgetKit
```

## Naming

- Types use PascalCase. Views end in `View`, managers in `Manager`, and utilities in `Util`.
- Models use descriptive PascalCase names such as `BlockedProfiles`.
- Functions and methods use verb-based camelCase such as `startBlocking`.
- Variables, properties, and constants use camelCase, not upper snake case.
- Boolean names begin with `is`, `has`, `enable`, or `allow`.
- Private properties have no underscore prefix.
- Static properties use camelCase or PascalCase according to their role.
- UserDefaults keys use the `family_foqos_` prefix.

## SwiftUI

- Use `@State` for local view state and `@Binding` for parent-child data flow.
- Use `@Environment(\.keyPath)` for environment values and `@EnvironmentObject` for shared
  managers.
- Prefer trailing-closure syntax for view modifiers.
- Use `@SafeQuery`, never raw `@Query`.

```swift
@State private var isPresenting = false
@Environment(\.modelContext) private var context
@EnvironmentObject var strategyManager: StrategyManager
@SafeQuery(sort: \BlockedProfiles.order) private var profiles: [BlockedProfiles]
```

## SwiftData

- Mark models with `@Model`.
- Use `@Attribute(.unique)` for unique identifiers and `@Relationship` for relationships.
- Use `#Predicate` for complex queries.
- Call `context.save()` after modifications and report descriptive failures.

```swift
@Model
class BlockedProfiles {
  @Attribute(.unique) var id: UUID
  @Relationship var sessions: [BlockedProfileSession] = []
}
```

### SafeQuery and Deleted Models

`@SafeQuery` is a `DynamicProperty` wrapper in `Foqos/Utils/SafeQuery.swift`. It mirrors the Query
initializers used by this codebase, except `animation:` and `transaction:`, and filters deleted
SwiftData models to prevent zombie-object `EXC_BREAKPOINT` crashes.

```swift
// Correct
@SafeQuery(sort: \BlockedProfiles.order) private var profiles: [BlockedProfiles]

// Wrong and rejected by the pre-commit hook
@Query(sort: \BlockedProfiles.order) private var profiles: [BlockedProfiles]
```

Use underscore initialization for dynamic predicates:

```swift
_sessions = SafeQuery(
  filter: #Predicate<BlockedProfileSession> { $0.blockedProfile.id == profileId },
  sort: \BlockedProfileSession.startTime,
  order: .reverse
)
```

Components that receive persistent-model arrays instead of querying use `.valid`:

```swift
ForEach(profiles.valid) { profile in
  ProfileCard(profile: profile)
}
```

## Protocols and Strategy Pattern

Define focused protocols with minimal methods. Use associated types or generic constraints when
appropriate. Strategy implementations may return optional views for custom UI.

```swift
protocol BlockingStrategy {
  static var id: String { get }
  var name: String { get }
  func startBlocking(
    context: ModelContext,
    profile: BlockedProfiles,
    forceStart: Bool?
  ) -> (any View)?
  func stopBlocking(context: ModelContext, session: BlockedProfileSession) -> (any View)?
}
```

## Error Handling

Use `try`/`catch` for throwing functions and give users descriptive error messages. Reserve
`fatalError()` for unrecoverable initialization such as ModelContainer creation. Use `Log`, never
`print()`, for diagnostics.

```swift
do {
  try context.save()
} catch {
  errorMessage = "Failed to save changes: \(error.localizedDescription)"
}
```

## Privacy-Focused Logging

Use the global custom `Log` framework with the narrowest appropriate level and category:

```swift
Log.debug("Button tapped", category: .ui)
Log.info("Session started for profile: \(profileId)", category: .session)
Log.warning("Sync conflict detected", category: .sync)
Log.error("Failed to save: \(error.localizedDescription)", category: .cloudKit)
```

Levels are `debug` (hidden in production), `info` (normal noteworthy operation), `warning`
(potential issue), and `error` (failure requiring attention).

Categories are `.app`, `.cloudKit`, `.sync`, `.strategy`, `.session`, `.ui`, `.location`, `.nfc`,
`.timer`, `.authorization`, `.liveActivity`, and `.familyControls`.

Never log passwords, lock codes, or personal identifiers. User-defined profile names are allowed;
UUIDs and timestamps are allowed. Users export logs through Home → version footer “Debug mode” →
Export Logs when a profile is active, or Settings → Diagnostics → Debug Mode → Export Logs.

## Control Flow and Properties

- Prefer `guard` and early returns over nested conditions.
- Use optional chaining and `??` for defaults.
- Use lightweight computed properties instead of parameterless functions; computed properties have
  no side effects.

```swift
guard let profile = try? BlockedProfiles.findProfile(byID: id, in: context) else {
  errorMessage = "Profile not found"
  return
}

var isBlocking: Bool {
  return activeSession?.isActive == true
}
```

## Closures

Prefer trailing-closure syntax, mark stored closures `@escaping`, and use weak references where a
class closure would otherwise retain its owner.

```swift
strategy.onSessionCreation = { [weak self] status in
  self?.handleSessionStatus(status)
}
```

## Comments and Previews

Keep comments minimal and explain why rather than what. Document complex business rules and
workarounds. Include realistic `#Preview` blocks and isolate preview defaults.

```swift
#Preview {
  HomeView()
    .environmentObject(RequestAuthorizer())
    .defaultAppStorage(UserDefaults(suiteName: "preview")!)
}
```

## Architecture and Files

- Shared managers use `static let shared` when singleton ownership is intended.
- Inject shared managers through environment objects.
- Models expose repository-like static data methods.
- `StrategyManager` coordinates complex flows.
- Group files under `Views/`, `Models/`, `Components/`, and `Utils/`.
- Prefer one public type per file. Private related types may remain together; group extensions
  logically or place them in separate files.

## Testing

- Test public interfaces rather than private implementation.
- Use async/await for asynchronous behavior.
- Mock dependencies when isolation requires it.
- Cover success and failure paths.
- Use descriptive names such as `testGivenX_WhenY_ThenZ()`.
- Pin time: call `Date()` once per test, capture `let now = Date()`, derive all other dates from it,
  and inject `now:` into the method under test. Independent clock reads create flaky drift.
