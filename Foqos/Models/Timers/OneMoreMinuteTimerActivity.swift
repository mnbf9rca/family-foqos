import DeviceActivity
import OSLog

private let log = Logger(
  subsystem: "com.cynexia.family-foqos.monitor", category: OneMoreMinuteTimerActivity.id)

class OneMoreMinuteTimerActivity: TimerActivity {
  static let id: String = "OneMoreMinuteActivity"

  private let appBlocker = AppBlockerUtil()

  func getDeviceActivityName(from profileId: String) -> DeviceActivityName {
    return DeviceActivityName(rawValue: "\(OneMoreMinuteTimerActivity.id):\(profileId)")
  }

  func getAllOneMoreMinuteActivities(from activities: [DeviceActivityName])
    -> [DeviceActivityName]
  {
    return activities.filter { $0.rawValue.starts(with: OneMoreMinuteTimerActivity.id) }
  }

  func start(for profile: SharedData.ProfileSnapshot) {
    let profileId = profile.id.uuidString

    guard let activeSession = SharedData.getActiveSharedSession() else {
      log.info(
        "Start one more minute activity for \(profileId), no active session found to start one more minute"
      )
      return
    }

    // Check to make sure the active session is the same as the profile before starting one more minute
    if activeSession.blockedProfileId != profile.id {
      log.info(
        "Start one more minute activity for \(profileId), active session profile does not match profile to start one more minute"
      )
      return
    }

    // End restrictions for one more minute
    appBlocker.deactivateRestrictions()

    // Record the one more minute start time
    let now = Date()
    SharedData.setOneMoreMinuteStartTime(date: now)
  }

  func stop(for profile: SharedData.ProfileSnapshot) {
    let profileId = profile.id.uuidString

    guard let activeSession = SharedData.getActiveSharedSession() else {
      log.info(
        "Stop one more minute activity for \(profileId), no active session found to stop one more minute"
      )
      return
    }

    // Check to make sure the active session is the same as the profile before stopping one more minute
    if activeSession.blockedProfileId != profile.id {
      log.info(
        "Stop one more minute activity for \(profileId), active session profile does not match profile to stop one more minute"
      )
      return
    }

    // Check if one more minute is active before stopping
    if activeSession.oneMoreMinuteStartTime != nil {
      // Start restrictions again since one more minute is ended
      appBlocker.activateRestrictions(for: profile)

      // Clear the one more minute start time so the session knows it's no longer active
      SharedData.clearOneMoreMinuteStartTime()
    }
  }
}
