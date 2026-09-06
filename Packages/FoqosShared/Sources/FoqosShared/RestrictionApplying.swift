import Foundation

/// Lock-free restriction applier seam for production settings and recording test spies.
public protocol RestrictionApplying {
  func activateRestrictions(for profile: SharedData.ProfileSnapshot)
  func deactivateRestrictions()
  func deactivateRestrictions(keepingSafeguardsFor profile: SharedData.ProfileSnapshot?)
}

extension AppBlockerUtil: RestrictionApplying {}
