import DeviceActivity
import Foundation

public class OneMoreMinuteTimerActivity: TimerActivity {
  public static let id: String = "OneMoreMinuteActivity"

  private let appBlocker: AppBlockerUtil

  public init() { self.appBlocker = AppBlockerUtil() }

  public func getDeviceActivityName(from profileId: String) -> DeviceActivityName {
    return DeviceActivityName(rawValue: "\(OneMoreMinuteTimerActivity.id):\(profileId)")
  }

  public func getAllOneMoreMinuteActivities(from activities: [DeviceActivityName])
    -> [DeviceActivityName]
  {
    return activities.filter { $0.rawValue.starts(with: OneMoreMinuteTimerActivity.id) }
  }

  public func start(for profile: SharedData.ProfileSnapshot) {
    // No-op: The main app process already deactivated restrictions and set
    // oneMoreMinuteStartTime before registering this DeviceActivity.
    // intervalDidStart fires immediately (since intervalStart is 00:00:00)
    // but the work is already done. We only need intervalDidEnd to fire.
    let profileId = profile.id.uuidString
    Log.info("One more minute intervalDidStart for \(profileId) - no-op (main process handled start)", category: .timer)
  }

  public func stop(for profile: SharedData.ProfileSnapshot) {
    guard let session = SharedData.getActiveSharedSession() else { return }
    let live = SharedData.snapshot(for: session.blockedProfileId.uuidString)
    SharedData.closeOneMoreMinuteGrantIfExpired(
      expectedSessionId: session.id,
      now: Date(),
      process: .monitorExtension,
      liveSnapshot: live,
      applier: appBlocker)
  }
}
