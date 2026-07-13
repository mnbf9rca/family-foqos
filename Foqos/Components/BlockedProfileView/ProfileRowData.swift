import FamilyControls
import Foundation

// REGRESSION GUARD (#298): ProfileRow accepts ONLY this value type - it can no longer hold a
// live BlockedProfiles @Model, so a re-render can never read a vacated store row. Reintroducing
// `let profile: BlockedProfiles` on the view is a compile-time-visible regression.
struct ProfileRowData {
  let id: UUID
  let name: String
  let updatedAt: Date
  let selectedItemsCount: Int
}

extension BlockedProfiles {
  /// Build the row snapshot. MUST be called only on a valid (non-zombie) model - callers gate
  /// via `.valid` / `SafeModelView` before invoking. Reads live attributes/relationships.
  ///
  /// TRIPWIRE (#298 edit-propagation): this MUST be evaluated inside an observation-tracked
  /// SwiftUI body (ProfileRow's `SafeModelView` content closure). Those tracked reads register
  /// the `@Observable` dependencies that make a legitimate edit rebuild the snapshot. Do NOT
  /// memoize it, cache it on the model, or move the call into an `init` / stored property / out of
  /// the render path - that silently stops the row updating on edits while still compiling and
  /// passing the zombie test. Verified by
  /// `testGivenProfileRowDataThenModelDeletedAndSaved_ThenValuesStillReadableNoTrap` and the
  /// device-gate edit step.
  var profileRowData: ProfileRowData {
    ProfileRowData(
      id: id,
      name: name,
      updatedAt: updatedAt,
      selectedItemsCount: FamilyActivityUtil.countSelectedActivities(selectedActivity)
    )
  }
}
