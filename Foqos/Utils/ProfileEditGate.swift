import Foundation

/// Pure decision for whether editing a BlockedProfile's settings should be disabled.
/// Extracted from BlockedProfileView so it can be unit-tested and reused by every
/// selector in the form (start/stop triggers, geofence). Only Child mode is blocked by
/// locks (AGENTS.md mode table): `mode == .child`, never `!= .parent`.
enum ProfileEditGate {
  static func editingDisabled(
    isBlocking: Bool,
    isManaged: Bool,
    isUnlocked: Bool,
    mode: AppMode,
    lockActive: Bool
  ) -> Bool {
    isBlocking || (isManaged && !isUnlocked && mode == .child && lockActive)
  }
}
