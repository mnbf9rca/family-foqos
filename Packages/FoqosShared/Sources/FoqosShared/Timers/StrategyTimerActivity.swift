import DeviceActivity
import Foundation

public class StrategyTimerActivity: TimerActivity {
  public static let id = "StrategyTimerActivity"
  private let appBlocker: RestrictionApplying
  public init(applier: RestrictionApplying = AppBlockerUtil()) { appBlocker = applier }

  public func getDeviceActivityName(from profileId: String) -> DeviceActivityName {
    .init("\(Self.id):\(profileId)")
  }
  public func getDeviceActivityName(profileId: UUID, sessionId: String) -> DeviceActivityName {
    .init("\(Self.id):\(profileId):\(sessionId)")
  }
  public static func sessionIdentity(from activity: DeviceActivityName) -> (profileId: UUID, sessionId: String)? {
    let parts = activity.rawValue.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == Substring(id),
      let profileId = UUID(uuidString: String(parts[1])), UUID(uuidString: String(parts[2])) != nil
    else { return nil }
    return (profileId, String(parts[2]))
  }
  public static func timerInterval(minutes: Int, now: Date, calendar: Calendar = .current) throws -> (start: DateComponents, end: DateComponents, deadline: Date) {
    guard (DeviceActivityLimits.minimumIntervalMinutes...DeviceActivityLimits.maximumTimerMinutes).contains(minutes),
      let deadline = calendar.dateInterval(of: .minute, for: now.addingTimeInterval(Double(minutes) * 60))?.start
    else { throw NSError(domain: "StrategyTimer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a timer from 15 minutes to 23 hours 59 minutes."]) }
    return (calendar.dateComponents([.hour, .minute], from: now), calendar.dateComponents([.hour, .minute], from: deadline), deadline)
  }
  public static func register(profileId: UUID, sessionId: String, minutes: Int, now: Date) throws -> Date {
    guard UUID(uuidString: sessionId) != nil else { throw NSError(domain: "StrategyTimer", code: 2) }
    let interval = try timerInterval(minutes: minutes, now: now)
    let name = StrategyTimerActivity().getDeviceActivityName(profileId: profileId, sessionId: sessionId)
    try DeviceActivityCenter().startMonitoring(name, during: .init(intervalStart: interval.start, intervalEnd: interval.end, repeats: false))
    return interval.deadline
  }
  public static func cancel(profileId: UUID, sessionId: String) {
    DeviceActivityCenter().stopMonitoring([StrategyTimerActivity().getDeviceActivityName(profileId: profileId, sessionId: sessionId)])
  }
  public func getAllStrategyTimerActivities(from activities: [DeviceActivityName]) -> [DeviceActivityName] {
    activities.filter { $0.rawValue.hasPrefix(Self.id + ":") }
  }
  // Interval starts are deliberately inert: originating admission establishes restrictions.
  public func start(for profile: SharedData.ProfileSnapshot) {}

  @discardableResult
  public func stop(for profile: SharedData.ProfileSnapshot, sessionId: String, now: Date) -> Bool {
    guard let active = SharedData.getActiveSharedSession(), active.blockedProfileId == profile.id else { return false }
    return SharedData.completeSession(expectedSessionId: sessionId, now: now, requireTimerDeadline: true) {
      self.appBlocker.deactivateRestrictions()
    }
  }
  public func stop(for profile: SharedData.ProfileSnapshot) {
    guard (profile.profileSchemaVersion ?? 1) < 2,
      let active = SharedData.getActiveSharedSession(), active.blockedProfileId == profile.id,
      active.origin == nil
    else { return }
    let now = Date()
    if active.tag == profile.id.uuidString { SharedData.setLastStoppedAt(for: profile.id.uuidString, at: now) }
    _ = SharedData.completeSession(expectedSessionId: active.id, now: now) {
      self.appBlocker.deactivateRestrictions()
    }
  }
}
