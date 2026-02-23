import DeviceActivity
import Foundation

public class StrategyTimerActivity: TimerActivity {
  public static let id: String = "StrategyTimerActivity"

  private let appBlocker: AppBlockerUtil

  public init() { self.appBlocker = AppBlockerUtil() }

  public func getDeviceActivityName(from profileId: String) -> DeviceActivityName {
    return DeviceActivityName(rawValue: "\(StrategyTimerActivity.id):\(profileId)")
  }

  public func getAllStrategyTimerActivities(from activities: [DeviceActivityName]) -> [DeviceActivityName] {
    return activities.filter { $0.rawValue.starts(with: StrategyTimerActivity.id) }
  }

  public func start(for profile: SharedData.ProfileSnapshot) {
    let profileId = profile.id.uuidString

    Log.info("Start strategy timer activity for \(profileId), profile: \(profileId)", category: .timer)

    if let activeSession = SharedData.getActiveSharedSession(),
      activeSession.blockedProfileId != profile.id
    {
      Log.info(
        "Start strategy timer activity for \(profileId), active session profile does not match device activity profile, not continuing",
        category: .timer
      )
      return
    }

    // No need to create a new active session since this is started in the app itself and session already exists
    // Start restrictions
    appBlocker.activateRestrictions(for: profile)
  }

  public func stop(for profile: SharedData.ProfileSnapshot) {
    let profileId = profile.id.uuidString

    guard let activeSession = SharedData.getActiveSharedSession() else {
      Log.info("Stop strategy timer activity for \(profileId), no active session found", category: .timer)
      return
    }

    // Check to make sure the active session is the same as the profile before disabling restrictions
    if activeSession.blockedProfileId != profile.id {
      Log.info(
        "Stop strategy timer activity for \(profileId), active session profile does not match device activity profile",
        category: .timer
      )
      return
    }

    // If this was a schedule-started session, record when it stopped.
    // Schedule-started sessions have tag == profile UUID (set by createSessionForScheduler).
    let isScheduleStarted = (activeSession.tag == profileId)
    if isScheduleStarted {
      let now = Date()
      Log.info("Stop strategy timer for \(profileId), recording stop at \(now)", category: .timer)
      SharedData.setLastStoppedAt(for: profileId, at: now)
    }

    // End restrictions
    appBlocker.deactivateRestrictions()

    // End the active strategy session
    SharedData.endActiveSharedSession()
  }
}
