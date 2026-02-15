import DeviceActivity
import OSLog
import UserNotifications

private let log: Logger = Logger(subsystem: "com.cynexia.family-foqos.monitor", category: ScheduleTimerActivity.id)

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
        log.info("Start schedule timer activity for \(profileId), should not be active now")
        return
      }
    } else if let schedule = profile.schedule {
      guard schedule.isTodayScheduled() else {
        log.info("Start schedule timer activity for \(profileId), not scheduled for today")
        return
      }
      guard schedule.olderThanOneMinute() else {
        log.info("Start schedule timer activity for \(profileId), schedule is too new")
        return
      }
    } else {
      log.info("Start schedule timer activity for \(profileId), no schedule found")
      return
    }

    log.info("Start schedule timer activity for \(profileId)")

    if let existingSession = SharedData.getActiveSharedSession() {
      if existingSession.blockedProfileId == profile.id {
        log.info("Start schedule timer for \(profileId), continuing active session")
        return
      } else {
        log.info("Start schedule timer for \(profileId), ending different active session")
        SharedData.endActiveSharedSession()
      }
    }

    SharedData.createSessionForSchedular(for: profile.id)
    appBlocker.activateRestrictions(for: profile)
  }

  func stop(for profile: SharedData.ProfileSnapshot) {
    let profileId = profile.id.uuidString

    guard let activeSession = SharedData.getActiveSharedSession() else {
      log.info("Stop schedule timer activity for \(profileId), no active session found")
      return
    }

    // Check to make sure the active session is the same as the profile before disabling restrictions
    if activeSession.blockedProfileId != profile.id {
      log.info(
        "Stop schedule timer activity for \(profileId), active session profile does not match device activity profile"
      )
      return
    }

    // End restrictions
    appBlocker.deactivateRestrictions()

    // End the active scheduled session
    SharedData.endActiveSharedSession()
  }

}
