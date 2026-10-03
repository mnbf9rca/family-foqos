import DeviceActivity
import Foundation
import UserNotifications

public class ScheduleTimerActivity: TimerActivity {
  public static let id: String = "ScheduleTimerActivity"

  /// Superset range covering all reminder minute values ever shipped.
  /// Used by both ScheduleTimerActivity (extension) and TimersUtil (main app)
  /// to cancel stale pre-activation reminder notifications.
  public static let allReminderCleanupRange: ClosedRange<Int> = 1...5

  private let appBlocker: RestrictionApplying
  private let registerTimer: (UUID, String, Int, Date) throws -> Date
  private let cancelTimer: (UUID, String) -> Void
  private let cancelReminders: (UUID) -> Void

  public init(
    applier: RestrictionApplying = AppBlockerUtil(),
    registerTimer: @escaping (UUID, String, Int, Date) throws -> Date = StrategyTimerActivity.register,
    cancelTimer: @escaping (UUID, String) -> Void = StrategyTimerActivity.cancel,
    cancelReminders: @escaping (UUID) -> Void = { id in
      let ids = allReminderCleanupRange.map { "pre-activation-reminder-\(id.uuidString)-\($0)" }
      UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
      UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }
  ) {
    self.appBlocker = applier
    self.registerTimer = registerTimer
    self.cancelTimer = cancelTimer
    self.cancelReminders = cancelReminders
  }

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

    let isV2 = (profile.profileSchemaVersion ?? 1) >= 2
    if isV2 {
      if let rejection = ProfileConditionValidation.startRejection(for: profile, origin: .init(kind: .schedule)) {
        switch rejection {
        case "Please edit this profile before starting. Its start and stop settings need updating.": Log.warning("Please edit this profile before starting. Its start and stop settings need updating.", category: .timer)
        case "This profile isn’t set to start this way. Please edit its start settings.": Log.warning("This profile isn’t set to start this way. Please edit its start settings.", category: .timer)
        case "This profile has no stop for this start. Please edit it before starting.": Log.warning("This profile has no stop for this start. Please edit it before starting.", category: .timer)
        default: Log.warning("Couldn’t start this profile. Please try again.", category: .timer)
        }
        return
      }
    } else {
      cancelReminders(profile.id)
    }

    guard profile.needsAppSelection != true else {
      Log.info("Skipping scheduled start until profile selection is confirmed", category: .timer)
      return
    }

    // Check start schedule — V2 uses consolidated shouldBeActiveNow, legacy uses individual checks
    if let startSchedule = profile.startSchedule, profile.startTriggersSchedule == true {
      let activeStopSchedule =
        (profile.stopConditionsSchedule == true) ? profile.stopSchedule : nil
      if !startSchedule.shouldBeActiveNow(
        stopSchedule: activeStopSchedule,
        lastStoppedAt: profile.scheduleLastStoppedAt)
      {
        Log.info("Start schedule timer activity for \(profile.id.uuidString), should not be active now", category: .timer)
        return
      }
    } else if let schedule = profile.schedule {
      guard schedule.isTodayScheduled() else {
        Log.info("Start schedule timer activity for \(profile.id.uuidString), not scheduled for today", category: .timer)
        return
      }
      guard schedule.olderThanOneMinute() else {
        Log.info("Start schedule timer activity for \(profile.id.uuidString), schedule is too new", category: .timer)
        return
      }
      if let stoppedAt = profile.scheduleLastStoppedAt,
        let windowStart = schedule.windowStart(),
        windowStart <= stoppedAt
      {
        Log.info(
          "Start schedule timer activity for \(profile.id.uuidString), window already stopped — suppressing (#229)",
          category: .timer)
        return
      }
    } else {
      Log.info("Start schedule timer activity for \(profile.id.uuidString), no schedule found", category: .timer)
      return
    }

    Log.info("Start schedule timer activity for \(profile.id.uuidString)", category: .timer)

    let existingSession = SharedData.getActiveSharedSession()
    if let existingSession, existingSession.blockedProfileId == profile.id {
      Log.info("Start schedule timer for \(profile.id.uuidString), continuing active session", category: .timer)
      return
    }
    if let existingSession {
      let victimSnapshot = SharedData.snapshot(for: existingSession.blockedProfileId.uuidString)
      let victimGeofence: BackgroundStopPolicy.GeofenceState =
        (victimSnapshot?.geofenceRule?.hasLocations == true) ? .unavailable : .noRule
      let decision = BackgroundStopPolicy.evaluate(
        channel: .takeover,
        sessionMatchesProfile: true,
        geofence: victimGeofence,
        stopConditions: victimSnapshot?.stopConditions
      )
      let legacyVeto =
        (victimSnapshot?.profileSchemaVersion ?? 1) < 2
        && victimSnapshot?.disableBackgroundStops == true
      guard !legacyVeto, case .allowed = decision else {
        Log.info(
          "Start schedule timer for \(profile.id.uuidString), NOT taking over protected session for "
            + "\(existingSession.blockedProfileId.uuidString): \(decision)",
          category: .timer)
        Self.postSkippedStartNotification(
          scheduledProfileId: profile.id,
          scheduledProfileName: profile.name,
          activeProfileName: victimSnapshot?.name ?? "another profile")
        return
      }
    }

    if isV2 {
      let now = Date()
      let sessionId = UUID().uuidString
      let minutes = profile.stopConditions?.timer == true ? profile.stopConditions?.timerDurationMinutes : nil
      var deadline: Date?
      if let minutes {
        do { deadline = try registerTimer(profile.id, sessionId, minutes, now) } catch {
          cancelTimer(profile.id, sessionId)
          Log.warning("This profile couldn’t start because its timer couldn’t be set. Please try again.", category: .timer)
          return
        }
      }
      let candidate = SharedData.SessionSnapshot(
        id: sessionId, tag: profileId, blockedProfileId: profile.id,
        startTime: now, timerEndTime: deadline, forceStarted: true, origin: .init(kind: .schedule))
      guard
        SharedData.commitOriginatingSession(
          candidate, expectedVictimId: existingSession?.id, now: now,
          onCommit: {
            self.appBlocker.activateRestrictions(for: profile)
          })
      else {
        if minutes != nil { cancelTimer(profile.id, sessionId) }
        Log.warning("Couldn’t start this profile. Please try again.", category: .timer)
        return
      }
      if let existingSession { cancelTimer(existingSession.blockedProfileId, existingSession.id) }
      cancelReminders(profile.id)
      return
    }

    guard
      SharedData.startSchedulerSessionTakingOver(
        profileId: profile.id,
        expectedVictimId: existingSession?.id
      )
    else {
      Log.info(
        "Start schedule timer for \(profile.id.uuidString), aborting takeover — active session changed under us",
        category: .timer)
      return
    }
    appBlocker.activateRestrictions(for: profile)
  }

  public func stop(for profile: SharedData.ProfileSnapshot) {
    let profileId = profile.id.uuidString

    guard let activeSession = SharedData.getActiveSharedSession() else {
      Log.info("Stop schedule timer activity for \(profile.id.uuidString), no active session found", category: .timer)
      return
    }

    // Pre-update snapshots and deferred V1 sessions retain their old lifecycle.
    guard (profile.profileSchemaVersion ?? 1) >= 2 || profile.disableBackgroundStops != true else { return }

    let decision = BackgroundStopPolicy.evaluate(
      channel: .schedule,
      sessionMatchesProfile: activeSession.blockedProfileId == profile.id,
      geofence: .noRule,
      stopConditions: profile.stopConditions
    )
    guard case .allowed = decision else {
      Log.info(
        "Stop schedule timer activity for \(profile.id.uuidString) refused by policy",
        category: .timer
      )
      return
    }

    if SharedData.completeSession(
      expectedSessionId: activeSession.id, now: Date(),
      onComplete: {
        self.appBlocker.deactivateRestrictions()
      })
    {
      cancelTimer(profile.id, activeSession.id)
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
