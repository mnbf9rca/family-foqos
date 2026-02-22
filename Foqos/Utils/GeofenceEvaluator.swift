import Foundation
import SwiftData
import SwiftUI
import UserNotifications

/// Evaluates geofence rules for profile start/stop and emergency unblock flows.
/// Owns all geofence-related UI state (checking spinner, start warning dialog).
/// Uses completion closures for session start/stop actions to avoid circular dependency with StrategyManager.
@MainActor
class GeofenceEvaluator: ObservableObject {
  static let shared = GeofenceEvaluator()

  let locationManager = LocationManager.shared

  @Published var isCheckingGeofence: Bool = false
  @Published var errorMessage: String?

  // Geofence start warning state
  @AppStorage("warnWhenActivatingAwayFromLocation") private var warnWhenActivatingAwayFromLocation =
    true
  @Published var showGeofenceStartWarning: Bool = false
  @Published var pendingStartProfile: BlockedProfiles? = nil
  @Published var geofenceWarningMessage: String = ""

  // Stored completion for confirmGeofenceStart
  private var pendingStartCompletion: ((ModelContext, BlockedProfiles) -> Void)?

  // MARK: - Evaluate (async, no UI side-effects)

  /// Evaluate geofence rule for a profile stop.
  /// Returns `nil` when no geofence exists (stop is allowed),
  /// or a `GeofenceCheckResult` indicating whether the stop should proceed.
  /// Returns `.failed` with a message when location can't be determined (fail-closed).
  func evaluateGeofenceForStop(
    profile: BlockedProfiles,
    context: ModelContext
  ) async -> GeofenceCheckResult? {
    guard let geofenceRule = profile.geofenceRule,
      geofenceRule.hasLocations
    else {
      return nil  // No geofence rule — stop is allowed
    }

    // If location permission is not determined or denied, fail-closed
    if locationManager.isNotDetermined || locationManager.isDenied {
      return .failed(
        message: "Could not verify your location. Open the app to stop this profile."
      )
    }

    let savedLocationsSnapshot: [SavedLocation]
    do {
      savedLocationsSnapshot = try SavedLocation.fetchAll(in: context)
    } catch {
      return .failed(message: "Unable to load saved locations. Please try again.")
    }

    return await locationManager.checkGeofenceRule(
      rule: geofenceRule,
      savedLocations: savedLocationsSnapshot
    )
  }

  // MARK: - Check and Stop (foreground UI path)

  /// Check geofence rule and stop blocking if satisfied (foreground UI path)
  func checkGeofenceAndStop(
    context: ModelContext,
    profile: BlockedProfiles,
    onStop: @escaping () -> Void
  ) {
    // Foreground-specific: request permission with user-facing prompt
    if locationManager.isNotDetermined {
      locationManager.requestAuthorization()
      errorMessage = "Please allow location access to stop this profile, then try again."
      return
    }

    if locationManager.isDenied {
      errorMessage =
        "Location access is denied. Enable location services in Settings to use location-based restrictions."
      return
    }

    isCheckingGeofence = true

    // Capture Sendable snapshots before entering the Task to avoid capturing
    // non-Sendable SwiftData models (profile) across the concurrency boundary
    guard let geofenceRule = profile.geofenceRule else {
      isCheckingGeofence = false
      onStop()
      return
    }
    let ruleToCheck = geofenceRule
    let savedLocationsSnapshot: [SavedLocation]
    do {
      savedLocationsSnapshot = try SavedLocation.fetchAll(in: context)
    } catch {
      self.isCheckingGeofence = false
      self.errorMessage = "Unable to load saved locations. Please try again."
      return
    }

    Task { @MainActor in
      let result = await self.locationManager.checkGeofenceRule(
        rule: ruleToCheck,
        savedLocations: savedLocationsSnapshot
      )

      self.isCheckingGeofence = false

      if result.isSatisfied {
        onStop()
      } else {
        self.errorMessage = result.failureMessage ?? "Location restriction not met."
      }
    }
  }

  // MARK: - Check and Start (foreground UI path)

  /// Check geofence rule before starting and show warning if user is not at location
  func checkGeofenceAndStart(
    context: ModelContext,
    activeProfile: BlockedProfiles?,
    onStart: @escaping (ModelContext, BlockedProfiles?) -> Void
  ) {
    guard let profile = activeProfile else {
      onStart(context, activeProfile)
      return
    }

    // Fast path: if setting is off, skip check
    guard warnWhenActivatingAwayFromLocation else {
      onStart(context, profile)
      return
    }

    // Fast path: if profile has no geofence rule, skip check
    guard let geofenceRule = profile.geofenceRule, geofenceRule.hasLocations else {
      onStart(context, profile)
      return
    }

    // If location permission not granted, proceed without warning (don't block activation)
    if locationManager.isNotDetermined || locationManager.isDenied {
      onStart(context, profile)
      return
    }

    isCheckingGeofence = true

    // Capture saved locations before entering the Task to avoid Sendable warnings
    let ruleToCheck = geofenceRule
    let savedLocationsSnapshot: [SavedLocation]
    do {
      savedLocationsSnapshot = try SavedLocation.fetchAll(in: context)
    } catch {
      self.isCheckingGeofence = false
      self.errorMessage = "Unable to load saved locations. Please try again."
      return
    }

    // Store the completion for confirmGeofenceStart
    pendingStartCompletion = onStart

    Task { @MainActor in
      let result = await locationManager.checkGeofenceRule(
        rule: ruleToCheck,
        savedLocations: savedLocationsSnapshot
      )

      self.isCheckingGeofence = false

      if result.isSatisfied {
        // User is at location, proceed without warning
        self.pendingStartCompletion = nil
        onStart(context, profile)
      } else {
        // User is NOT at location, show warning
        self.pendingStartProfile = profile
        self.geofenceWarningMessage = self.buildStartWarningMessage(
          rule: ruleToCheck,
          savedLocations: savedLocationsSnapshot
        )
        self.showGeofenceStartWarning = true
      }
    }
  }

  /// Build user-friendly warning message for starting away from location
  private func buildStartWarningMessage(
    rule: ProfileGeofenceRule,
    savedLocations: [SavedLocation]
  ) -> String {
    let locationNames = rule.locationReferences.compactMap { ref in
      savedLocations.first { $0.id == ref.savedLocationId }?.name
    }

    if locationNames.isEmpty {
      return
        "This profile has location restrictions. You won't be able to stop it until you're at the required location."
    } else if locationNames.count == 1 {
      return
        "This profile can only be stopped at \"\(locationNames[0])\". You're not currently at that location."
    } else {
      let locationList = locationNames.joined(separator: ", ")
      return
        "This profile can only be stopped at one of these locations: \(locationList). You're not currently at any of them."
    }
  }

  // MARK: - Geofence Start Confirmation

  /// Called when user confirms starting despite geofence warning
  func confirmGeofenceStart(context: ModelContext) {
    guard let profile = pendingStartProfile,
      let completion = pendingStartCompletion
    else {
      cancelGeofenceStart()
      return
    }

    completion(context, profile)
    cancelGeofenceStart()
  }

  /// Called when user cancels starting due to geofence warning
  func cancelGeofenceStart() {
    pendingStartProfile = nil
    pendingStartCompletion = nil
    geofenceWarningMessage = ""
    showGeofenceStartWarning = false
  }

  // MARK: - Emergency Unblock Geofence Check

  /// Check geofence rule and perform emergency unblock if satisfied
  func checkGeofenceAndEmergencyUnblock(
    context: ModelContext,
    rule: ProfileGeofenceRule,
    session: BlockedProfileSession,
    onUnblock: @escaping (ModelContext, BlockedProfileSession) -> Void
  ) {
    // Request permission if not determined
    if locationManager.isNotDetermined {
      locationManager.requestAuthorization()
      errorMessage = "Please allow location access to use emergency unblock, then try again."
      return
    }

    // Check if permission is denied
    if locationManager.isDenied {
      errorMessage =
        "Location access is denied. Enable location services in Settings to use emergency unblock."
      return
    }

    isCheckingGeofence = true

    // Capture saved locations before entering the Task to avoid Sendable warnings
    let ruleToCheck = rule
    let savedLocationsSnapshot: [SavedLocation]
    do {
      savedLocationsSnapshot = try SavedLocation.fetchAll(in: context)
    } catch {
      self.isCheckingGeofence = false
      self.errorMessage = "Unable to load saved locations. Please try again."
      return
    }

    Task { @MainActor in
      let result = await locationManager.checkGeofenceRule(
        rule: ruleToCheck,
        savedLocations: savedLocationsSnapshot
      )

      self.isCheckingGeofence = false

      if result.isSatisfied {
        onUnblock(context, session)
      } else {
        self.errorMessage = result.failureMessage ?? "Location restriction not met."
      }
    }
  }

  // MARK: - Geofence Notifications

  /// Post a local notification when a background stop is blocked by geofence
  func postGeofenceBlockedNotification(
    profileId: UUID,
    profileName: String,
    reason: String
  ) {
    let content = UNMutableNotificationContent()
    content.title = "Profile couldn't be stopped"
    content.body = "\(profileName): \(reason)"
    content.sound = .default

    // Stable per-profile identifier so repeated blocked stops replace the previous notification
    let request = UNNotificationRequest(
      identifier: "geofence-blocked-\(profileId.uuidString)",
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request) { error in
      if let error {
        Log.warning(
          "Failed to post geofence blocked notification: \(error.localizedDescription)",
          category: .location)
      }
    }
  }
}
