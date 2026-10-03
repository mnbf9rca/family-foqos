import DeviceActivity
import Foundation

/// Handles the independent stop recurrence, regardless of session origin.
/// `intervalDidStart` is a no-op. `intervalDidEnd` stops the active session.
public class StopScheduleTimerActivity: TimerActivity {
  public static let id: String = "StopScheduleTimerActivity"

  private let appBlocker: RestrictionApplying
  private let cancelTimer: (UUID, String) -> Void

  public init(
    applier: RestrictionApplying = AppBlockerUtil(),
    cancelTimer: @escaping (UUID, String) -> Void = StrategyTimerActivity.cancel
  ) {
    self.appBlocker = applier
    self.cancelTimer = cancelTimer
  }

  public func getDeviceActivityName(from profileId: String) -> DeviceActivityName {
    return DeviceActivityName(rawValue: "\(StopScheduleTimerActivity.id):\(profileId)")
  }

  public func start(for profile: SharedData.ProfileSnapshot) {
    // No-op: this activity only handles stop timing.
    // intervalDidStart fires at midnight but we don't want to start a session.
    Log.info("StopScheduleTimerActivity.start called for \(profile.id.uuidString) - no-op", category: .timer)
  }

  public func stop(for profile: SharedData.ProfileSnapshot) {
    stop(for: profile, now: Date())
  }

  public func stop(for profile: SharedData.ProfileSnapshot, now: Date, calendar: Calendar = .current) {
    let profileId = profile.id.uuidString

    guard let activeSession = SharedData.getActiveSharedSession() else {
      Log.info("Stop schedule timer for \(profileId), no active session found", category: .timer)
      return
    }

    let isV2 = (profile.profileSchemaVersion ?? 1) >= 2
    let stopOccurrence: Date?
    if isV2 {
      guard profile.stopConditionsSchedule == true, profile.stopConditions?.schedule == true,
        let stopSchedule = profile.stopSchedule,
        let occurrence = stopSchedule.previousOccurrence(atOrBefore: now, calendar: calendar),
        activeSession.startTime <= occurrence
      else { return }
      stopOccurrence = occurrence
    } else {
      // Preserve pre-update snapshots and active deferred V1 sessions.
      guard profile.disableBackgroundStops != true else { return }
      if let stopSchedule = profile.stopSchedule,
        !stopSchedule.isTodayScheduled(now: now, calendar: calendar)
      {
        return
      }
      stopOccurrence = nil
    }

    let decision = BackgroundStopPolicy.evaluate(
      channel: .schedule,
      sessionMatchesProfile: activeSession.blockedProfileId == profile.id,
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

    if SharedData.completeSession(
      expectedSessionId: activeSession.id, now: now,
      scheduledStopAt: stopOccurrence, expectedProfileId: profile.id, calendar: calendar,
      onComplete: { self.appBlocker.deactivateRestrictions() })
    {
      if isV2 { cancelTimer(profile.id, activeSession.id) }
    }
  }
}
