import DeviceActivity
import Foundation

/// C2-owned break deadline backstop. The in-process lift owns grant opening; this only closes.
public class BreakDeadlineBackstopActivity: TimerActivity {
  public static let id: String = "BreakDeadlineBackstop"

  private let appBlocker: AppBlockerUtil

  public init() {
    self.appBlocker = AppBlockerUtil()
  }

  public func getDeviceActivityName(from profileId: String) -> DeviceActivityName {
    DeviceActivityName(rawValue: "\(BreakDeadlineBackstopActivity.id):\(profileId)")
  }

  public func getAllBreakDeadlineBackstopActivities(
    from activities: [DeviceActivityName]
  ) -> [DeviceActivityName] {
    activities.filter { $0.rawValue.starts(with: BreakDeadlineBackstopActivity.id) }
  }

  public func start(for profile: SharedData.ProfileSnapshot) {
    Log.info("Break deadline backstop intervalDidStart - no-op", category: .timer)
  }

  public func stop(for profile: SharedData.ProfileSnapshot) {
    guard let session = SharedData.getActiveSharedSession() else { return }
    let live = SharedData.snapshot(for: session.blockedProfileId.uuidString)
    SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: session.id,
      explicit: false,
      now: Date(),
      process: .monitorExtension,
      durationMinutes: live?.breakTimeInMinutes,
      liveSnapshot: live,
      applier: appBlocker)
  }
}
