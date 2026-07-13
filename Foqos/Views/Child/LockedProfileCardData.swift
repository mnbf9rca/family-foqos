import FamilyControls
import Foundation

// REGRESSION GUARD (#298): LockedProfileCard accepts ONLY this value type - it can no longer hold
// a live BlockedProfiles @Model, so a re-render can never read a vacated store row.
struct LockedProfileCardData {
  let id: UUID
  let name: String
  let appsBlockedCount: Int
}

extension BlockedProfiles {
  /// Build the card snapshot. MUST be called only on a valid (non-zombie) model - callers gate
  /// via `SafeModelView` before invoking. Reads live attributes/relationships.
  ///
  /// TRIPWIRE (#298 edit-propagation): this MUST be evaluated inside an observation-tracked
  /// SwiftUI body (LockedProfileCard's `SafeModelView` content closure). Those tracked reads
  /// register the `@Observable` dependencies that make a legitimate edit rebuild the snapshot.
  /// Do NOT memoize it, cache it on the model, or move the call into an `init` / stored property /
  /// out of the render path - that silently stops the card updating on edits while still compiling
  /// and passing the zombie test. Verified by
  /// `testGivenLockedProfileCardDataThenModelDeletedAndSaved_ThenValuesStillReadableNoTrap` and
  /// the device-gate edit step.
  var lockedProfileCardData: LockedProfileCardData {
    LockedProfileCardData(
      id: id,
      name: name,
      appsBlockedCount: FamilyActivityUtil.countSelectedActivities(selectedActivity)
    )
  }
}
