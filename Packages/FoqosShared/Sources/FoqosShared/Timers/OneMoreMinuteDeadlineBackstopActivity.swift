import DeviceActivity
import Foundation

/// C2-owned one-more-minute deadline backstop. The in-process lift owns grant opening.
public class OneMoreMinuteDeadlineBackstopActivity: TimerActivity {
  public static let id: String = "OneMoreMinuteDeadlineBackstop"

  private let appBlocker: AppBlockerUtil

  public init() {
    self.appBlocker = AppBlockerUtil()
  }

  public func getDeviceActivityName(from profileId: String) -> DeviceActivityName {
    DeviceActivityName(rawValue: "\(OneMoreMinuteDeadlineBackstopActivity.id):\(profileId)")
  }

  public func getAllOneMoreMinuteDeadlineBackstopActivities(
    from activities: [DeviceActivityName]
  ) -> [DeviceActivityName] {
    activities.filter { $0.rawValue.starts(with: OneMoreMinuteDeadlineBackstopActivity.id) }
  }

  public func start(for profile: SharedData.ProfileSnapshot) {
    Log.info("OMM deadline backstop intervalDidStart - no-op", category: .timer)
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
