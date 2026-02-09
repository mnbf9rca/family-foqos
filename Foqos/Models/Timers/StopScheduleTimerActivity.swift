import DeviceActivity
import OSLog

private let log: Logger = Logger(
  subsystem: "com.cynexia.family-foqos.monitor",
  category: StopScheduleTimerActivity.id
)

/// Handles stop-only scheduling for profiles that start manually but stop on schedule.
/// `intervalDidStart` is a no-op. `intervalDidEnd` stops the active session.
class StopScheduleTimerActivity: TimerActivity {
  static let id: String = "StopScheduleTimerActivity"

  private let appBlocker = AppBlockerUtil()

  func getDeviceActivityName(from profileId: String) -> DeviceActivityName {
    return DeviceActivityName(rawValue: "\(StopScheduleTimerActivity.id):\(profileId)")
  }

  func start(for profile: SharedData.ProfileSnapshot) {
    // No-op: this activity only handles stop timing.
    // intervalDidStart fires at midnight but we don't want to start a session.
    log.info("StopScheduleTimerActivity.start called for \(profile.id.uuidString) - no-op")
  }

  func stop(for profile: SharedData.ProfileSnapshot) {
    let profileId = profile.id.uuidString

    guard let activeSession = SharedData.getActiveSharedSession() else {
      log.info("Stop schedule timer for \(profileId), no active session found")
      return
    }

    if activeSession.blockedProfileId != profile.id {
      log.info("Stop schedule timer for \(profileId), active session profile does not match")
      return
    }

    // Check if today is a scheduled stop day
    if let stopSchedule = profile.stopSchedule {
      if !stopSchedule.isTodayScheduled() {
        log.info("Stop schedule timer for \(profileId), not scheduled for today")
        return
      }
    }

    log.info("Stop schedule timer firing for \(profileId), ending session")

    appBlocker.deactivateRestrictions()
    SharedData.endActiveSharedSession()
  }
}
