import DeviceActivity
import OSLog

private let log: Logger = Logger(subsystem: "com.cynexia.family-foqos.monitor", category: StrategyTimerActivity.id)

class StrategyTimerActivity: TimerActivity {
  static let id: String = "StrategyTimerActivity"

  private let appBlocker = AppBlockerUtil()

  func getDeviceActivityName(from profileId: String) -> DeviceActivityName {
    return DeviceActivityName(rawValue: "\(StrategyTimerActivity.id):\(profileId)")
  }

  func getAllStrategyTimerActivities(from activities: [DeviceActivityName]) -> [DeviceActivityName] {
    return activities.filter { $0.rawValue.starts(with: StrategyTimerActivity.id) }
  }

  func start(for profile: SharedData.ProfileSnapshot) {
    let profileId = profile.id.uuidString

    log.info("Start strategy timer activity for \(profileId), profile: \(profileId)")

    if let activeSession = SharedData.getActiveSharedSession(),
      activeSession.blockedProfileId != profile.id
    {
      log.info(
        "Start strategy timer activity for \(profileId), active session profile does not match device activity profile, not continuing"
      )
      return
    }

    // No need to create a new active session since this is started in the app itself and session already exists
    // Start restrictions
    appBlocker.activateRestrictions(for: profile)
  }

  func stop(for profile: SharedData.ProfileSnapshot) {
    let profileId = profile.id.uuidString

    guard let activeSession = SharedData.getActiveSharedSession() else {
      log.info("Stop strategy timer activity for \(profileId), no active session found")
      return
    }

    // Check to make sure the active session is the same as the profile before disabling restrictions
    if activeSession.blockedProfileId != profile.id {
      log.info(
        "Stop strategy timer activity for \(profileId), active session profile does not match device activity profile"
      )
      return
    }

    // If this was a schedule-started session, record when it stopped.
    // Schedule-started sessions have tag == profile UUID (set by createSessionForSchedular).
    let isScheduleStarted = (activeSession.tag == profileId)
    if isScheduleStarted {
      let now = Date()
      log.info("Stop strategy timer for \(profileId), recording stop at \(now)")
      SharedData.setLastStoppedAt(for: profileId, at: now)
    }

    // End restrictions
    appBlocker.deactivateRestrictions()

    // End the active strategy session
    SharedData.endActiveSharedSession()
  }
}
