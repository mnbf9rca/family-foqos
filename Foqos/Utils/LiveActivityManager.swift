import ActivityKit
import Foundation
import SwiftUI

class LiveActivityManager: ObservableObject {
  // Published property for live activity reference
  @Published var currentActivity: Activity<FoqosWidgetAttributes>?

  // Use AppStorage for persisting the activity ID across app launches
  @AppStorage("com.cynexia.family-foqos.currentActivityId") private var storedActivityId: String = ""

  static let shared = LiveActivityManager()

  private init() {
    // Try to restore existing activity on initialization
    restoreExistingActivity()
  }

  private var isSupported: Bool {
    if #available(iOS 16.1, *) {
      return ActivityAuthorizationInfo().areActivitiesEnabled
    }
    return false
  }

  // Save activity ID using AppStorage
  private func saveActivityId(_ id: String) {
    storedActivityId = id
  }

  // Remove activity ID from AppStorage
  private func removeActivityId() {
    storedActivityId = ""
  }

  // Restore existing activity from system if available
  private func restoreExistingActivity() {
    guard isSupported else { return }

    // Check if we have a saved activity ID
    if !storedActivityId.isEmpty {
      if let existingActivity = Activity<FoqosWidgetAttributes>.activities.first(where: {
        $0.id == storedActivityId
      }) {
        // Found the existing activity
        self.currentActivity = existingActivity
        Log.info("Restored existing Live Activity with ID: \(existingActivity.id)", category: .liveActivity)
      } else {
        // The activity no longer exists, clean up the stored ID
        Log.info("No existing activity found with saved ID, removing reference", category: .liveActivity)
        removeActivityId()
      }
    }
  }

  func startSessionActivity(session: BlockedProfileSession) {
    // Check if Live Activities are supported
    guard isSupported else {
      Log.info("Live Activities are not supported on this device", category: .liveActivity)
      return
    }

    // Check if we can restore an existing activity first
    if currentActivity == nil {
      restoreExistingActivity()
    }

    // Check if we already have an activity running
    if currentActivity != nil {
      Log.info("Live Activity is already running, will update instead", category: .liveActivity)
      updateSessionActivity(session: session)
      return
    }

    if session.blockedProfile.enableLiveActivity == false {
      Log.info("Activity is disabled for profile", category: .liveActivity)
      return
    }

    // Create and start the activity
    let profileName = session.blockedProfile.name
    let message = FocusMessages.getRandomMessage()
    let attributes = FoqosWidgetAttributes(name: profileName, message: message)
    let contentState = FoqosWidgetAttributes.ContentState(
      startTime: session.startTime,
      isBreakActive: session.isBreakActive,
      breakStartTime: session.breakStartTime,
      breakEndTime: session.breakEndTime
    )

    do {
      let content = ActivityContent(state: contentState, staleDate: nil)
      let activity = try Activity.request(
        attributes: attributes,
        content: content
      )
      currentActivity = activity

      saveActivityId(activity.id)
      Log.info("Started Live Activity with ID: \(activity.id) for profile: \(profileName)", category: .liveActivity)
      return
    } catch {
      Log.info("Error starting Live Activity: \(error.localizedDescription)", category: .liveActivity)
      return
    }
  }

  func updateSessionActivity(session: BlockedProfileSession) {
    guard let activity = currentActivity else {
      Log.info("No Live Activity to update", category: .liveActivity)
      return
    }

    let updatedState = FoqosWidgetAttributes.ContentState(
      startTime: session.startTime,
      isBreakActive: session.isBreakActive,
      breakStartTime: session.breakStartTime,
      breakEndTime: session.breakEndTime
    )

    Task {
      let content = ActivityContent(state: updatedState, staleDate: nil)
      await activity.update(content)
      Log.info("Updated Live Activity with ID: \(activity.id)", category: .liveActivity)
    }
  }

  func updateBreakState(session: BlockedProfileSession) {
    guard let activity = currentActivity else {
      Log.info("No Live Activity to update for break state", category: .liveActivity)
      return
    }

    let updatedState = FoqosWidgetAttributes.ContentState(
      startTime: session.startTime,
      isBreakActive: session.isBreakActive,
      breakStartTime: session.breakStartTime,
      breakEndTime: session.breakEndTime
    )

    Task {
      let content = ActivityContent(state: updatedState, staleDate: nil)
      await activity.update(content)
      Log.info("Updated Live Activity break state: \(session.isBreakActive)", category: .liveActivity)
    }
  }

  func endSessionActivity() {
    guard let activity = currentActivity else {
      Log.info("No Live Activity to end", category: .liveActivity)
      return
    }

    // End the activity
    let completedState = FoqosWidgetAttributes.ContentState(
      startTime: Date.now
    )

    Task {
      let content = ActivityContent(state: completedState, staleDate: nil)
      await activity.end(content, dismissalPolicy: .immediate)
      Log.info("Ended Live Activity", category: .liveActivity)
    }

    // Remove the stored activity ID when ending the activity
    removeActivityId()
    currentActivity = nil
  }
}
