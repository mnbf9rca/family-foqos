import DeviceActivity
import Foundation

enum DeviceActivityClassifier {
  struct Classification {
    let type: String
    let profileId: UUID?

    func matches(profileId: UUID) -> Bool {
      self.profileId == profileId
    }
  }

  static func classify(_ activity: DeviceActivityName) -> Classification {
    let rawValue = activity.rawValue

    if let result = classifyPrefixed(
      rawValue,
      activityId: BreakTimerActivity.id,
      type: "Break Timer"
    ) {
      return result
    }
    if let result = classifyPrefixed(
      rawValue,
      activityId: StopScheduleTimerActivity.id,
      type: "Stop Schedule Timer"
    ) {
      return result
    }
    if let result = classifyPrefixed(
      rawValue,
      activityId: ScheduleTimerActivity.id,
      type: "Schedule Timer"
    ) {
      return result
    }
    if let result = classifyPrefixed(
      rawValue,
      activityId: StrategyTimerActivity.id,
      type: "Strategy Timer"
    ) {
      return result
    }
    if let profileId = UUID(uuidString: rawValue) {
      return Classification(type: "Schedule Timer (Legacy)", profileId: profileId)
    }
    return Classification(type: "Unknown", profileId: nil)
  }

  private static func classifyPrefixed(
    _ rawValue: String,
    activityId: String,
    type: String
  ) -> Classification? {
    let prefix = "\(activityId):"
    guard rawValue.hasPrefix(prefix) else { return nil }
    let rawProfileId = String(rawValue.dropFirst(prefix.count))
    return Classification(type: type, profileId: UUID(uuidString: rawProfileId))
  }
}
