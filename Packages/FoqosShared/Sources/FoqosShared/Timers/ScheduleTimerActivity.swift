import DeviceActivity
import UserNotifications

public class ScheduleTimerActivity: TimerActivity {
  public static let id: String = "ScheduleTimerActivity"

  /// Superset range covering all reminder minute values ever shipped.
  /// Used by both ScheduleTimerActivity (extension) and TimersUtil (main app)
  /// to cancel stale pre-activation reminder notifications.
  public static let allReminderCleanupRange: ClosedRange<Int> = 1...5

  private let appBlocker: AppBlockerUtil

  public init() { self.appBlocker = AppBlockerUtil() }

  public func getDeviceActivityName(from profileId: String) -> DeviceActivityName {
    // Since schedules were implemented before the timer activities, the profile id is used as the device activity name for
    // backward compatibility
    return DeviceActivityName(rawValue: profileId)
  }

  public func getAllScheduleTimerActivities(from activities: [DeviceActivityName]) -> [DeviceActivityName] {
    // Schedule timer activities use just the profile UUID as the rawValue (no prefix)
    // Other activities use prefixes like "BreakScheduleActivity:" or "StrategyTimerActivity:"
    return activities.filter { activity in
      let rawValue = activity.rawValue
      // If it contains ":", it's a prefixed activity (break or strategy timer), not a schedule
      guard !rawValue.contains(":") else { return false }
      // Must be a valid UUID
      return UUID(uuidString: rawValue) != nil
    }
  }

  public static func skippedStartNotificationIdentifier(for scheduledProfileId: UUID) -> String {
    return "scheduled-start-skipped-\(scheduledProfileId.uuidString)"
  }

  public func start(for profile: SharedData.ProfileSnapshot) {
    let profileId = profile.id.uuidString

    // Cancel any pre-activation reminders now that the start time has arrived,
    // regardless of whether the profile actually starts (early returns below).
    let reminderIds = Self.allReminderCleanupRange.map { "pre-activation-reminder-\(profile.id.uuidString)-\($0)" }
    UNUserNotificationCenter.current().removePendingNotificationRequests(
      withIdentifiers: reminderIds
    )
    UNUserNotificationCenter.current().removeDeliveredNotifications(
      withIdentifiers: reminderIds
    )

    // Check start schedule — V2 uses consolidated shouldBeActiveNow, legacy uses individual checks
    if let startSchedule = profile.startSchedule, profile.startTriggersSchedule == true {
      let activeStopSchedule =
        (profile.stopConditionsSchedule == true) ? profile.stopSchedule : nil
      if !startSchedule.shouldBeActiveNow(
        stopSchedule: activeStopSchedule,
        lastStoppedAt: profile.scheduleLastStoppedAt)
      {
        Log.info("Start schedule timer activity for \(profileId), should not be active now", category: .timer)
        return
      }
    } else if let schedule = profile.schedule {
      guard schedule.isTodayScheduled() else {
        Log.info("Start schedule timer activity for \(profileId), not scheduled for today", category: .timer)
        return
      }
      guard schedule.olderThanOneMinute() else {
        Log.info("Start schedule timer activity for \(profileId), schedule is too new", category: .timer)
        return
      }
      if let stoppedAt = profile.scheduleLastStoppedAt,
        let windowStart = schedule.windowStart(),
        windowStart <= stoppedAt
      {
        Log.info(
          "Start schedule timer activity for \(profileId), window already stopped — suppressing (#229)",
          category: .timer)
        return
      }
    } else {
      Log.info("Start schedule timer activity for \(profileId), no schedule found", category: .timer)
      return
    }

    Log.info("Start schedule timer activity for \(profileId)", category: .timer)

    let existingSession = SharedData.getActiveSharedSession()
    if let existingSession, existingSession.blockedProfileId == profile.id {
      Log.info("Start schedule timer for \(profileId), continuing active session", category: .timer)
      return
    }
    if let existingSession {
      let victimSnapshot = SharedData.snapshot(for: existingSession.blockedProfileId.uuidString)
      let victimGeofence: BackgroundStopPolicy.GeofenceState =
        (victimSnapshot?.geofenceRule?.hasLocations == true) ? .unavailable : .noRule
      let decision = BackgroundStopPolicy.evaluate(
        channel: .takeover,
        sessionMatchesProfile: true,
        disableBackgroundStops: victimSnapshot?.disableBackgroundStops ?? false,
        geofence: victimGeofence,
        stopConditions: victimSnapshot?.stopConditions
      )
      guard case .allowed = decision else {
        Log.info(
          "Start schedule timer for \(profileId), NOT taking over protected session for "
            + "\(existingSession.blockedProfileId.uuidString): \(decision)",
          category: .timer)
        Self.postSkippedStartNotification(
          scheduledProfileId: profile.id,
          scheduledProfileName: profile.name,
          activeProfileName: victimSnapshot?.name ?? "another profile")
        return
      }
    }

    guard
      SharedData.startSchedulerSessionTakingOver(
        profileId: profile.id,
        expectedVictimId: existingSession?.id
      )
    else {
      Log.info(
        "Start schedule timer for \(profileId), aborting takeover — active session changed under us",
        category: .timer)
      return
    }
    appBlocker.activateRestrictions(for: profile)
  }

  public func stop(for profile: SharedData.ProfileSnapshot) {
    let profileId = profile.id.uuidString

    guard let activeSession = SharedData.getActiveSharedSession() else {
      Log.info("Stop schedule timer activity for \(profileId), no active session found", category: .timer)
      return
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
        "Stop schedule timer activity for \(profileId) refused by policy: \(decision)",
        category: .timer
      )
      return
    }

    if SharedData.endActiveSharedSession(expectedSessionId: activeSession.id) {
      appBlocker.deactivateRestrictions()
    }
  }

  private static func postSkippedStartNotification(
    scheduledProfileId: UUID,
    scheduledProfileName: String,
    activeProfileName: String
  ) {
    let content = UNMutableNotificationContent()
    content.title = "Scheduled profile didn't start"
    content.body =
      "\(scheduledProfileName) didn't start — \(activeProfileName) is active and can't be "
      + "stopped in the background."
    let request = UNNotificationRequest(
      identifier: skippedStartNotificationIdentifier(for: scheduledProfileId),
      content: content,
      trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }

}
