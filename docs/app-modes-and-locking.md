# App Modes and Locking

## Mode Matrix

| Mode | Lock Code | Can Create Unlocked Items | Can Create Locked Items | Blocked by Locked Items |
|---|---|---|---|---|
| **Individual** | None possible | Yes | No | No |
| **Parent** | Can set code | Yes | Yes | No (full access) |
| **Child** | Synced from parent | Yes | No | Yes (requires code) |

## Data Boundary

The app behaves exactly the same on a child’s device as on an adult’s: a parent may configure a profile, or the child configures it and the parent locks it, and the child can also keep unlocked profiles. The point is that a parent has to talk to the child, in person, to set anything up, so limits are agreed rather than imposed remotely.

Profiles, sessions, tags, and locations sync only between devices signed into the same private iCloud account; they never cross the family share. Family sharing carries only lock-code records (a salted hash and scope metadata), family-member records, child-to-parent heartbeats, and two parent-to-child commands: reset the emergency count (`resetEmergencyCount`) and reset lock-code throttling (`resetLockCodeThrottle`). A parent configures the profile on the child’s device, then enables Parent-Controlled in Parent mode with a configured code or uses the code-authorized Edit Locked Profiles sheet in Child mode; the lock code gates only editing/deleting locked items and changes to locked emergency settings in Child mode. The child’s device scans its own NFC/QR tags to start and stop sessions; parents do not push profiles, start/stop sessions, or scan for the child from their own device through family sharing.

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
