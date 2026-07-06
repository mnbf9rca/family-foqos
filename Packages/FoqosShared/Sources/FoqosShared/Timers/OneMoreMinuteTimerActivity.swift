import DeviceActivity

public class OneMoreMinuteTimerActivity: TimerActivity {
  public static let id: String = "OneMoreMinuteActivity"

  private let appBlocker: AppBlockerUtil

  public init() { self.appBlocker = AppBlockerUtil() }

  public func getDeviceActivityName(from profileId: String) -> DeviceActivityName {
    return DeviceActivityName(rawValue: "\(OneMoreMinuteTimerActivity.id):\(profileId)")
  }

  public func getAllOneMoreMinuteActivities(from activities: [DeviceActivityName])
    -> [DeviceActivityName]
  {
    return activities.filter { $0.rawValue.starts(with: OneMoreMinuteTimerActivity.id) }
  }

  public func start(for profile: SharedData.ProfileSnapshot) {
    // No-op: The main app process already deactivated restrictions and set
    // oneMoreMinuteStartTime before registering this DeviceActivity.
    // intervalDidStart fires immediately (since intervalStart is 00:00:00)
    // but the work is already done. We only need intervalDidEnd to fire.
    let profileId = profile.id.uuidString
    Log.info("One more minute intervalDidStart for \(profileId) - no-op (main process handled start)", category: .timer)
  }

  public func stop(for profile: SharedData.ProfileSnapshot) {
    let profileId = profile.id.uuidString

    guard let activeSession = SharedData.getActiveSharedSession() else {
      Log.info(
        "Stop one more minute activity for \(profileId), no active session found to stop one more minute",
        category: .timer
      )
      return
    }

    // Check to make sure the active session is the same as the profile before stopping one more minute
    if activeSession.blockedProfileId != profile.id {
      Log.info(
        "Stop one more minute activity for \(profileId), active session profile does not match profile to stop one more minute",
        category: .timer
      )
      return
    }

    // Check if one more minute is active before stopping
    if activeSession.oneMoreMinuteStartTime != nil {
      // Start restrictions again since one more minute is ended
      appBlocker.activateRestrictions(for: profile)

      // Clear the one more minute start time so the session knows it's no longer active
      SharedData.clearOneMoreMinuteStartTime(expectedSessionId: activeSession.id)
    }
  }
}
