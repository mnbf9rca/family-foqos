import DeviceActivity
import UserNotifications

class ScheduleTimerActivity: TimerActivity {
  static let id: String = "ScheduleTimerActivity"

  private let appBlocker = AppBlockerUtil()

  func getDeviceActivityName(from profileId: String) -> DeviceActivityName {
    // Since schedules were implemented before the timer activities, the profile id is used as the device activity name for
    // backward compatibility
    return DeviceActivityName(rawValue: profileId)
  }

  func getAllScheduleTimerActivities(from activities: [DeviceActivityName]) -> [DeviceActivityName] {
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

  func start(for profile: SharedData.ProfileSnapshot) {
    let profileId = profile.id.uuidString

    // Cancel any pre-activation reminders now that the start time has arrived,
    // regardless of whether the profile actually starts (early returns below).
    // SYNC: identifier format must match TimersUtil.preActivationReminderIdentifier(for:minutes:)
    // SYNC: cancels full 1-5 range intentionally (matches allPreActivationReminderIdentifiers)
    let reminderIds = (1...5).map { "pre-activation-reminder-\(profile.id.uuidString)-\($0)" }
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
    } else {
      Log.info("Start schedule timer activity for \(profileId), no schedule found", category: .timer)
      return
    }

    Log.info("Start schedule timer activity for \(profileId)", category: .timer)

    if let existingSession = SharedData.getActiveSharedSession() {
      if existingSession.blockedProfileId == profile.id {
        Log.info("Start schedule timer for \(profileId), continuing active session", category: .timer)
        return
      } else {
        Log.info("Start schedule timer for \(profileId), ending different active session", category: .timer)
        SharedData.endActiveSharedSession()
      }
    }

    SharedData.createSessionForSchedular(for: profile.id)
    appBlocker.activateRestrictions(for: profile)
  }

  func stop(for profile: SharedData.ProfileSnapshot) {
    let profileId = profile.id.uuidString

    guard let activeSession = SharedData.getActiveSharedSession() else {
      Log.info("Stop schedule timer activity for \(profileId), no active session found", category: .timer)
      return
    }

    // Check to make sure the active session is the same as the profile before disabling restrictions
    if activeSession.blockedProfileId != profile.id {
      Log.info(
        "Stop schedule timer activity for \(profileId), active session profile does not match device activity profile",
        category: .timer
      )
      return
    }

    // End restrictions
    appBlocker.deactivateRestrictions()

    // End the active scheduled session
    SharedData.endActiveSharedSession()
  }

}
