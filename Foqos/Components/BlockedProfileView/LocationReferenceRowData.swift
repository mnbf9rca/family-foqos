import Foundation

// REGRESSION GUARD (#298): LocationReferenceRow's location accepts ONLY this value type - it can
// no longer hold a live SavedLocation @Model. The `reference` binding stays a two-way @Binding
// because ProfileLocationReference is a value struct.
struct LocationReferenceRowData {
  let id: UUID
  let name: String
  let isLocked: Bool
  let defaultRadiusMeters: Double
}

extension SavedLocation {
  /// Build the row snapshot. MUST be called only on a valid (non-zombie) model - callers gate
  /// via `SafeModelView` before invoking. Reads live attributes/relationships.
  ///
  /// TRIPWIRE (#298 edit-propagation): this MUST be evaluated inside an observation-tracked
  /// SwiftUI body (LocationReferenceRow's `SafeModelView` content closure). Those tracked reads
  /// register the `@Observable` dependencies that make a legitimate edit rebuild the snapshot.
  /// Do NOT memoize it, cache it on the model, or move the call into an `init` / stored property /
  /// out of the render path - that silently stops the row updating on edits while still compiling
  /// and passing the zombie test. Verified by
  /// `testGivenLocationReferenceRowDataThenModelDeletedAndSaved_ThenValuesStillReadableNoTrap`
  /// and the device-gate edit step.
  var locationReferenceRowData: LocationReferenceRowData {
    LocationReferenceRowData(
      id: id,
      name: name,
      isLocked: isLocked,
      defaultRadiusMeters: defaultRadiusMeters
    )
  }
}
