import DeviceActivity
import Foundation

public class TimerActivityUtil {
  /// #238: reload the home-screen widget after every scheduled interval event. Overridable in
  /// tests and configured by the monitor extension so FoqosShared does not link WidgetKit.
  public nonisolated(unsafe) static var reloadWidgets: @Sendable () -> Void = {}

  public static func startTimerActivity(for activity: DeviceActivityName) {
    defer { Self.reloadWidgets() }

    guard activity.rawValue.split(separator: ":", omittingEmptySubsequences: false).count <= 2 else { return }
    let parts = getTimerParts(from: activity)

    guard let timerActivity = getTimerActivity(for: parts.deviceActivityId),
      let profile = getProfile(for: parts.profileId)
    else {
      return
    }

    timerActivity.start(for: profile)
  }

  public static func stopTimerActivity(for activity: DeviceActivityName) {
    defer { Self.reloadWidgets() }

    if let identity = StrategyTimerActivity.sessionIdentity(from: activity) {
      if let profile = getProfile(for: identity.profileId.uuidString) {
        _ = StrategyTimerActivity().stop(for: profile, sessionId: identity.sessionId, now: Date())
      }
      return
    }
    guard activity.rawValue.split(separator: ":", omittingEmptySubsequences: false).count <= 2 else { return }
    let parts = getTimerParts(from: activity)

    guard let timerActivity = getTimerActivity(for: parts.deviceActivityId),
      let profile = getProfile(for: parts.profileId)
    else {
      return
    }

    timerActivity.stop(for: profile)
  }

  private static func getTimerParts(from activity: DeviceActivityName) -> (
    deviceActivityId: String, profileId: String
  ) {
    let activityName = activity.rawValue
    let components = activityName.split(separator: ":")

    // For versions >= 1.24, the activity name format is "type:profileId"
    if components.count == 2 {
      return (deviceActivityId: String(components[0]), profileId: String(components[1]))
    }

    // For versions < 1.24, the activity name format is just "profileId" and only supports schedule timer activity
    // This is to support backward compatibility for older schedules
    guard UUID(uuidString: activityName) != nil else { return ("", "") }
    return (deviceActivityId: ScheduleTimerActivity.id, profileId: activityName)
  }

  private static func getTimerActivity(for deviceActivityId: String) -> TimerActivity? {
    switch deviceActivityId {
    case ScheduleTimerActivity.id:
      return ScheduleTimerActivity()
    case BreakTimerActivity.id:
      return BreakTimerActivity()
    case StrategyTimerActivity.id:
      return StrategyTimerActivity()
    case StopScheduleTimerActivity.id:
      return StopScheduleTimerActivity()
    case OneMoreMinuteTimerActivity.id:
      return OneMoreMinuteTimerActivity()
    case BreakDeadlineBackstopActivity.id:
      return BreakDeadlineBackstopActivity()
    case OneMoreMinuteDeadlineBackstopActivity.id:
      return OneMoreMinuteDeadlineBackstopActivity()
    default:
      return nil
    }
  }

  private static func getProfile(for profileId: String) -> SharedData.ProfileSnapshot? {
    return SharedData.snapshot(for: profileId)
  }
}
