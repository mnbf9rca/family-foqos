# Shortcuts Intent Error Propagation

**Issue:** #36
**Date:** 2026-02-10

## Problem

All four App Intents (`StartProfileIntent`, `StopProfileIntent`, `CheckProfileStatusIntent`, `CheckSessionActiveIntent`) silently swallow errors. Failures are stored on `StrategyManager.errorMessage` but the Shortcuts runtime always sees success. Users get no feedback when automations fail.

## Design

### 1. New `IntentError` enum

Create `Foqos/Intents/IntentError.swift` with a single error enum covering all failure cases:

```swift
enum IntentError: Error, CustomLocalizedStringResourceConvertible {
  case profileNotFound
  case sessionAlreadyActive
  case durationOutOfRange
  case noActiveSession(profileName: String)
  case backgroundStopsDisabled(profileName: String)
  case geofenceBlocked(reason: String)
  case unexpected(String)

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .profileNotFound:
      "Could not find that profile."
    case .sessionAlreadyActive:
      "A session is already active."
    case .durationOutOfRange:
      "Duration must be between 15 and 1440 minutes."
    case .noActiveSession(let name):
      "\(name) is not currently active."
    case .backgroundStopsDisabled(let name):
      "\(name) cannot be stopped remotely."
    case .geofenceBlocked(let reason):
      "Cannot stop — \(reason)"
    case .unexpected(let message):
      "Something went wrong: \(message)"
    }
  }
}
```

`CustomLocalizedStringResourceConvertible` is the protocol App Intents uses to display errors in Shortcuts/Siri.

### 2. StrategyManager changes

Make `startSessionFromBackground` and `stopSessionFromBackground` throw `IntentError` instead of silently setting `self.errorMessage` and returning.

- `startSessionFromBackground` becomes `throws`
- `stopSessionFromBackground` becomes `async throws`
- Each early-return-with-error becomes a `throw IntentError.xxx`
- Keep setting `self.errorMessage` alongside the throw so in-app error UI continues to work

### 3. Intent changes

**StartProfileIntent** — let errors propagate, add success dialog:
```swift
func perform() async throws -> some IntentResult & ProvidesDialog {
  try StrategyManager.shared.startSessionFromBackground(
    profile.id, context: modelContext, durationInMinutes: durationInMinutes
  )
  let message = durationInMinutes != nil
    ? "\(profile.name) started for \(durationInMinutes!) minutes."
    : "\(profile.name) started."
  return .result(dialog: .init(stringLiteral: message))
}
```

**StopProfileIntent** — same pattern:
```swift
func perform() async throws -> some IntentResult & ProvidesDialog {
  try await StrategyManager.shared.stopSessionFromBackground(
    profile.id, context: modelContext
  )
  return .result(dialog: "\(profile.name) stopped.")
}
```

**CheckProfileStatusIntent / CheckSessionActiveIntent** — already have dialogs. Just need to wrap `loadActiveSession` in do/catch if it can fail, or leave as-is since these have minimal error surface.

### 4. Files touched

| File | Change |
|------|--------|
| `Foqos/Intents/IntentError.swift` | **New** — error enum |
| `Foqos/Utils/StrategyManager.swift` | Make two background methods throw |
| `Foqos/Intents/StartProfileIntent.swift` | Add dialog, let errors propagate |
| `Foqos/Intents/StopProfileIntent.swift` | Add dialog, let errors propagate |
| `Foqos/Intents/CheckProfileStatusIntent.swift` | Minor — add error handling if needed |
| `Foqos/Intents/CheckSessionActiveIntent.swift` | Minor — add error handling if needed |
