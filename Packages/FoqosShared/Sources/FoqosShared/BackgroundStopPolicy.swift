import Foundation

/// The single source of truth for whether a background actor may stop a session.
/// Pure and side-effect-free so both the app process and DeviceActivity monitor
/// extension can evaluate it from the app-group snapshot.
public enum BackgroundStopPolicy {

  public enum Channel: Equatable {
    case shortcut
    case schedule
    case takeover
  }

  public enum GeofenceState: Equatable {
    case noRule
    case satisfied
    case notSatisfied(reason: String)
    case unavailable
  }

  public enum Denial: Equatable {
    case noMatchingSession
    case backgroundStopsDisabled
    case geofenceNotSatisfied(reason: String)
    case geofenceUnavailable
    case stopConditionNotMet(reason: String)
  }

  public enum Decision: Equatable {
    case allowed
    case denied(Denial)
  }

  public static func evaluate(
    channel: Channel,
    sessionMatchesProfile: Bool,
    disableBackgroundStops: Bool,
    geofence: GeofenceState,
    stopConditions: ProfileStopConditions?
  ) -> Decision {
    guard sessionMatchesProfile else { return .denied(.noMatchingSession) }

    if disableBackgroundStops { return .denied(.backgroundStopsDisabled) }

    switch geofence {
    case .noRule, .satisfied:
      break
    case .notSatisfied(let reason):
      return .denied(.geofenceNotSatisfied(reason: reason))
    case .unavailable:
      return .denied(.geofenceUnavailable)
    }

    let conditions = stopConditions ?? ProfileStopConditions()
    switch channel {
    case .shortcut, .takeover:
      guard conditions.manual else {
        return .denied(
          .stopConditionNotMet(
            reason: "This profile can only be stopped with its configured stop method."))
      }
    case .schedule:
      guard conditions.schedule else {
        return .denied(
          .stopConditionNotMet(
            reason: "This profile is not configured to stop on a schedule."))
      }
    }

    return .allowed
  }
}
