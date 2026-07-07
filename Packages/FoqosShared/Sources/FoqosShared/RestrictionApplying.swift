import Foundation

/// Lock-free restriction applier seam. `AppBlockerUtil` already implements both methods,
/// so C2 primitives can default to it while tests inject a recording spy.
public protocol RestrictionApplying {
  func activateRestrictions(for profile: SharedData.ProfileSnapshot)
  func deactivateRestrictions()
}

extension AppBlockerUtil: RestrictionApplying {}
