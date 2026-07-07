import Foundation

/// D-C2-4 derived restriction state. Pure; no side effects.
public enum RestrictionDecision: Equatable {
  case deactivate
  case activate(SharedData.ProfileSnapshot)
  case bailPreserve
}

/// Process authority differs only for absent/ended sessions.
public enum RestrictionProcess {
  case mainApp
  case monitorExtension
}

extension SharedData {
  /// Raw-field grant predicate (I11): restrictions are OFF if a break or OMM is open.
  public static func hasOpenGrant(_ s: SessionSnapshot) -> Bool {
    let breakOpen = s.breakStartTime != nil && s.breakEndTime == nil
    let ommOpen = s.oneMoreMinuteStartTime != nil
    return breakOpen || ommOpen
  }

  /// Pure derivation of desired restriction state from persisted state (D-C2-4).
  public static func deriveRestriction(
    session: SessionSnapshot?,
    liveSnapshot: ProfileSnapshot?,
    process: RestrictionProcess
  ) -> RestrictionDecision {
    guard let session, session.endTime == nil else {
      switch process {
      case .mainApp: return .deactivate
      case .monitorExtension: return .bailPreserve
      }
    }
    if hasOpenGrant(session) { return .deactivate }
    if let liveSnapshot { return .activate(liveSnapshot) }
    if let pinned = session.pinnedProfileConfig { return .activate(pinned) }
    return .bailPreserve
  }
}
