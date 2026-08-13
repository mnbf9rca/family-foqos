# App Modes and Locking

## Mode Matrix

| Mode | Lock Code | Can Create Unlocked Items | Can Create Locked Items | Blocked by Locked Items |
|---|---|---|---|---|
| **Individual** | None possible | Yes | No | No |
| **Parent** | Can set code | Yes | Yes | No (full access) |
| **Child** | Synced from parent | Yes | No | Yes (requires code) |

## Individual-to-Parent Promotion

An Individual device can set a lock code through the Family Controls Dashboard. This is the only
user-initiated path to Parent because `ModeSelectionView` offers only Individual and Child. Setting
the code promotes the device to Parent in the same action, so an Individual device never persists
with a lock code and never creates locked items.

The `setLockCode` guard therefore remains `!= .child`, not `== .parent`; the latter would deadlock
the promotion by requiring Parent mode before the action that creates it.

## Lock Checks

Only Child mode is restricted by lock codes:

```swift
// Correct
appModeManager.currentMode == .child

// Wrong: also matches Individual
appModeManager.currentMode != .parent
```

## Lock-Related UI

Show lock toggles, which create locked items, only in Parent mode with a configured code:

```swift
appModeManager.currentMode == .parent && lockCodeManager.hasAnyLockCode
```

Prompt to edit or delete an existing locked item only in Child mode:

```swift
item.isLocked && appModeManager.currentMode == .child
```
