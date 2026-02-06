import DeviceActivity
import OSLog

private let log: Logger = Logger(subsystem: "com.cynexia.family-foqos.monitor", category: ScheduleTimerActivity.id)

class ScheduleTimerActivity: TimerActivity {
  static let id: String = "ScheduleTimerActivity"

  private let appBlocker = AppBlockerUtil()

  func getDeviceActivityName(from profileId: String) -> DeviceActivityName {
    // Since schedules were implemented before the timer activities, the profile id is used as the device activity name for
    // backward compatibility
    return DeviceActivityName(rawValue: profileId)
  }

  func getAllScheduleTimerActivities(from activities: [DeviceActivityName]) -> [DeviceActivityName]
  {
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

    // Check start schedule — prefer V2, fall back to legacy
    let isTodayScheduled: Bool
    let isOldEnough: Bool

    if let startSchedule = profile.startSchedule, profile.startTriggersSchedule == true {
      isTodayScheduled = startSchedule.isTodayScheduled()
      isOldEnough = startSchedule.olderThan15Minutes()
    } else if let schedule = profile.schedule {
      isTodayScheduled = schedule.isTodayScheduled()
      isOldEnough = schedule.olderThan15Minutes()
    } else {
      log.info("Start schedule timer activity for \(profileId), no schedule found")
      return
    }

    if !isTodayScheduled {
      log.info("Start schedule timer activity for \(profileId), not scheduled for today")
      return
    }

    if !isOldEnough {
      log.info("Start schedule timer activity for \(profileId), schedule is too new")
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

  func getScheduleInterval(from schedule: BlockedProfileSchedule) -> (
    intervalStart: DateComponents, intervalEnd: DateComponents
  ) {
    let intervalStart = DateComponents(hour: schedule.startHour, minute: schedule.startMinute)
    let intervalEnd = DateComponents(hour: schedule.endHour, minute: schedule.endMinute)
    return (intervalStart: intervalStart, intervalEnd: intervalEnd)
  }

  func getScheduleInterval(
    startSchedule: ProfileScheduleTime,
    stopSchedule: ProfileScheduleTime?
  ) -> (intervalStart: DateComponents, intervalEnd: DateComponents) {
    let intervalStart = DateComponents(hour: startSchedule.hour, minute: startSchedule.minute)
    let intervalEnd: DateComponents
    if let stop = stopSchedule {
      intervalEnd = DateComponents(hour: stop.hour, minute: stop.minute)
    } else {
      // No stop schedule — set end to just before start
      let endHour = (startSchedule.hour + 23) % 24
      let endMinute = startSchedule.minute > 0 ? startSchedule.minute - 1 : 59
      intervalEnd = DateComponents(hour: endHour, minute: endMinute)
    }
    return (intervalStart: intervalStart, intervalEnd: intervalEnd)
  }
}
