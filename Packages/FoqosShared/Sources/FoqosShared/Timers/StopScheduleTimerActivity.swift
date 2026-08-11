import DeviceActivity

/// Handles stop-only scheduling for profiles that start manually but stop on schedule.
/// `intervalDidStart` is a no-op. `intervalDidEnd` stops the active session.
public class StopScheduleTimerActivity: TimerActivity {
  public static let id: String = "StopScheduleTimerActivity"

  private let appBlocker: AppBlockerUtil

  public init() { self.appBlocker = AppBlockerUtil() }

  public func getDeviceActivityName(from profileId: String) -> DeviceActivityName {
    return DeviceActivityName(rawValue: "\(StopScheduleTimerActivity.id):\(profileId)")
  }

  public func start(for profile: SharedData.ProfileSnapshot) {
    // No-op: this activity only handles stop timing.
    // intervalDidStart fires at midnight but we don't want to start a session.
    Log.info("StopScheduleTimerActivity.start called for \(profile.id.uuidString) - no-op", category: .timer)
  }

  public func stop(for profile: SharedData.ProfileSnapshot) {
    let profileId = profile.id.uuidString

    guard let activeSession = SharedData.getActiveSharedSession() else {
      Log.info("Stop schedule timer for \(profileId), no active session found", category: .timer)
      return
    }

    // Check if today is a scheduled stop day
    if let stopSchedule = profile.stopSchedule {
      if !stopSchedule.isTodayScheduled() {
        Log.info("Stop schedule timer for \(profileId), not scheduled for today", category: .timer)
        return
      }
    }

    let decision = BackgroundStopPolicy.evaluate(
      channel: .schedule,
      sessionMatchesProfile: activeSession.blockedProfileId == profile.id,
      disableBackgroundStops: profile.disableBackgroundStops ?? false,
      geofence: .noRule,
      stopConditions: profile.stopConditions
    )
    guard case .allowed = decision else {
      Log.info(
        "Stop schedule timer for \(profileId) refused by background-stop policy",
        category: .timer)
      return
    }

    Log.info("Stop schedule timer firing for \(profileId), ending session", category: .timer)

    if SharedData.endActiveSharedSession(expectedSessionId: activeSession.id) {
      appBlocker.deactivateRestrictions()
    }
  }
}
