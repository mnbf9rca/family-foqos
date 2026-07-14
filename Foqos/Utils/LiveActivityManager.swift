import ActivityKit
import Foundation
import SwiftUI

/// #249: pure startSessionActivity action, testable without ActivityKit runtime support.
enum LiveActivityAction: Equatable {
  case start
  case update
  case recreate
  case end
  case skip
}

@MainActor
class LiveActivityManager: ObservableObject {
  // Published property for live activity reference
  @Published var currentActivity: Activity<FoqosWidgetAttributes>?

  // Use AppStorage for persisting the activity ID across app launches
  @AppStorage("family_foqos_current_activity_id") private var storedActivityId: String = ""
  @AppStorage("family_foqos_current_activity_profile_id")
  private var storedActivityProfileId: String = ""

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

  private var currentActivityProfileId: UUID? {
    storedActivityProfileId.isEmpty ? nil : UUID(uuidString: storedActivityProfileId)
  }

  /// #249: a profile switch must recreate the activity because the profile name is an immutable
  /// ActivityAttribute. Disabled switched-in profiles end any stale activity instead of updating it.
  nonisolated static func decideAction(
    currentProfileId: UUID?,
    incomingProfileId: UUID,
    enableLiveActivity: Bool,
    hasCurrentActivity: Bool
  ) -> LiveActivityAction {
    guard enableLiveActivity else {
      return hasCurrentActivity ? .end : .skip
    }
    guard hasCurrentActivity else {
      return .start
    }
    return currentProfileId == incomingProfileId ? .update : .recreate
  }

  // Save activity ID using AppStorage
  private func saveActivityId(_ id: String) {
    storedActivityId = id
  }

  // Remove activity ID from AppStorage
  private func removeActivityId() {
    storedActivityId = ""
    storedActivityProfileId = ""
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

    let action = Self.decideAction(
      currentProfileId: currentActivityProfileId,
      incomingProfileId: session.blockedProfile.id,
      enableLiveActivity: session.blockedProfile.enableLiveActivity,
      hasCurrentActivity: currentActivity != nil
    )

    switch action {
    case .skip:
      Log.info("Live Activity disabled for profile, nothing to do", category: .liveActivity)
    case .update:
      Log.info("Live Activity already running for this profile, updating", category: .liveActivity)
      updateSessionActivity(session: session)
    case .end:
      Log.info("Live Activity disabled for switched-in profile, ending", category: .liveActivity)
      endSessionActivity()
    case .recreate:
      Log.info("Profile switched, recreating Live Activity for new name", category: .liveActivity)
      endSessionActivity()
      requestActivity(session: session)
    case .start:
      requestActivity(session: session)
    }
  }

  private func requestActivity(session: BlockedProfileSession) {
    let profileName = session.blockedProfile.name
    let message = FocusMessages.getRandomMessage()
    let attributes = FoqosWidgetAttributes(name: profileName, message: message)
    let contentState = FoqosWidgetAttributes.ContentState(
      startTime: session.startTime,
      isBreakActive: session.isBreakActive,
      breakStartTime: session.breakStartTime,
      breakEndTime: session.breakEndTime,
      isOneMoreMinuteActive: false,
      oneMoreMinuteStartTime: nil
    )

    do {
      let content = ActivityContent(state: contentState, staleDate: nil)
      let activity = try Activity.request(
        attributes: attributes,
        content: content
      )
      currentActivity = activity

      saveActivityId(activity.id)
      storedActivityProfileId = session.blockedProfile.id.uuidString
      Log.info("Started Live Activity with ID: \(activity.id) for profile: \(profileName)", category: .liveActivity)
    } catch {
      Log.info("Error starting Live Activity: \(error.localizedDescription)", category: .liveActivity)
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
      breakEndTime: session.breakEndTime,
      isOneMoreMinuteActive: session.isOneMoreMinuteActive(),
      oneMoreMinuteStartTime: session.oneMoreMinuteStartTime
    )

    let activityId = activity.id
    Task {
      await Self.updateActivity(withId: activityId, to: updatedState)
      Log.info("Updated Live Activity with ID: \(activityId)", category: .liveActivity)
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
      breakEndTime: session.breakEndTime,
      isOneMoreMinuteActive: session.isOneMoreMinuteActive(),
      oneMoreMinuteStartTime: session.oneMoreMinuteStartTime
    )

    let activityId = activity.id
    let isBreakActive = session.isBreakActive
    Task {
      await Self.updateActivity(withId: activityId, to: updatedState)
      Log.info("Updated Live Activity break state: \(isBreakActive)", category: .liveActivity)
    }
  }

  func updateOneMoreMinuteState(session: BlockedProfileSession) {
    guard let activity = currentActivity else {
      Log.info("No Live Activity to update for one-more-minute state", category: .liveActivity)
      return
    }

    let updatedState = FoqosWidgetAttributes.ContentState(
      startTime: session.startTime,
      isBreakActive: session.isBreakActive,
      breakStartTime: session.breakStartTime,
      breakEndTime: session.breakEndTime,
      isOneMoreMinuteActive: session.isOneMoreMinuteActive(),
      oneMoreMinuteStartTime: session.oneMoreMinuteStartTime
    )

    let activityId = activity.id
    Task {
      await Self.updateActivity(withId: activityId, to: updatedState)
      Log.info(
        "Updated Live Activity one-more-minute state", category: .liveActivity)
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

    let activityId = activity.id
    Task {
      await Self.endActivity(withId: activityId, finalState: completedState)
      Log.info("Ended Live Activity", category: .liveActivity)
    }

    // Remove the stored activity ID when ending the activity
    removeActivityId()
    currentActivity = nil
  }

  // Activity<T> is not Sendable, so a MainActor-held reference cannot be passed
  // to its nonisolated async update/end methods. Look the activity up by ID in a
  // nonisolated context instead, keeping it out of the main actor's region.
  private nonisolated static func activity(
    withId id: String
  ) -> Activity<FoqosWidgetAttributes>? {
    Activity<FoqosWidgetAttributes>.activities.first(where: { $0.id == id })
  }

  private nonisolated static func updateActivity(
    withId id: String, to state: FoqosWidgetAttributes.ContentState
  ) async {
    guard let activity = activity(withId: id) else { return }
    await activity.update(ActivityContent(state: state, staleDate: nil))
  }

  private nonisolated static func endActivity(
    withId id: String, finalState: FoqosWidgetAttributes.ContentState
  ) async {
    guard let activity = activity(withId: id) else { return }
    await activity.end(
      ActivityContent(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
  }
}
