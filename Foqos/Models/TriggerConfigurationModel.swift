import FoqosShared
import Foundation
import SwiftData
import SwiftUI

/// Observable model for trigger configuration UI
@MainActor
final class TriggerConfigurationModel: ObservableObject {
  private let validator = TriggerValidator()

  @Published var startTriggers = ProfileStartTriggers()
  @Published var stopConditions = ProfileStopConditions()
  @Published var validationErrors: [String] = []
  @Published private(set) var hasLoadedProfile = false

  // Tag bindings
  @Published var startNFCTagIds: [String] = []
  @Published var startQRCodeIds: [String] = []
  @Published var stopNFCTagIds: [String] = []
  @Published var stopQRCodeIds: [String] = []

  // Schedule bindings
  @Published var startSchedule: ProfileScheduleTime?
  @Published var stopSchedule: ProfileScheduleTime?

  init() {}

  /// Call when start triggers change to auto-fix invalid stop conditions
  func startTriggersDidChange() {
    if !startTriggers.specificNFC { startNFCTagIds = [] }
    if !startTriggers.specificQR { startQRCodeIds = [] }
    validator.autoFix(start: startTriggers, stop: &stopConditions)
    validate()
  }

  /// Call when stop conditions change to re-run validation
  func stopConditionsDidChange() {
    if !stopConditions.specificNFC { stopNFCTagIds = [] }
    if !stopConditions.specificQR { stopQRCodeIds = [] }
    validate()
  }

  /// Run validation and update error list
  func validate() {
    var errors = validator.validate(start: startTriggers, stop: stopConditions)

    // Check for missing data when specific toggles are enabled
    if startTriggers.specificNFC && startNFCTagIds.isEmpty {
      errors.append("Scan an NFC tag to use as the start trigger")
    }
    if startTriggers.specificQR && startQRCodeIds.isEmpty {
      errors.append("Scan a QR code to use as the start trigger")
    }
    if stopConditions.specificNFC && stopNFCTagIds.isEmpty {
      errors.append("Scan an NFC tag to use as the stop condition")
    }
    if stopConditions.specificQR && stopQRCodeIds.isEmpty {
      errors.append("Scan a QR code to use as the stop condition")
    }
    if startTriggers.schedule && (startSchedule == nil || startSchedule?.isActive != true) {
      errors.append("Configure a start schedule")
    }
    if stopConditions.schedule && (stopSchedule == nil || stopSchedule?.isActive != true) {
      errors.append("Configure a stop schedule")
    }
    if startTriggers.schedule && stopConditions.schedule,
      let start = startSchedule, let stop = stopSchedule,
      start.isActive, stop.isActive,
      start.hour == stop.hour && start.minute == stop.minute
    {
      errors.append("Start and stop times can't be the same")
    }
    if startTriggers.schedule && stopConditions.schedule,
      let start = startSchedule, let stop = stopSchedule,
      start.isActive, stop.isActive
    {
      let window = TriggerValidator.scheduleWindowMinutes(
        startHour: start.hour, startMinute: start.minute,
        stopHour: stop.hour, stopMinute: stop.minute
      )
      // window == 0 is already reported by the same-time rule above.
      if window > 0 && window < DeviceActivityLimits.minimumIntervalMinutes {
        errors.append(
          "A scheduled window must be at least "
            + "\(DeviceActivityLimits.minimumIntervalMinutes) minutes long"
        )
      }
    }

    validationErrors = errors
    if !validationErrors.isEmpty {
      Log.debug(
        "Trigger validation errors: \(validationErrors.joined(separator: ", ")). "
          + "Start: manual=\(startTriggers.manual), NFC=\(startTriggers.hasNFC), QR=\(startTriggers.hasQR), schedule=\(startTriggers.schedule), deepLink=\(startTriggers.deepLink). "
          + "Stop: manual=\(stopConditions.manual), timer=\(stopConditions.timer), NFC=\(stopConditions.anyNFC || stopConditions.specificNFC || stopConditions.sameNFC), "
          + "QR=\(stopConditions.anyQR || stopConditions.specificQR || stopConditions.sameQR), schedule=\(stopConditions.schedule), deepLink=\(stopConditions.deepLink)",
        category: .ui
      )
    }
  }

  /// Check if a stop option is enabled given current start triggers
  func isStopEnabled(_ stop: StopOption) -> Bool {
    validator.isStopAvailable(stop, forStart: startTriggers)
  }

  /// Get reason why a stop option is disabled
  func reasonStopDisabled(_ stop: StopOption) -> String? {
    validator.unavailabilityReason(stop, forStart: startTriggers)
  }

  /// Load from profile
  func loadFromProfile(
    _ profile: BlockedProfiles, in context: ModelContext, hasActiveSession: Bool = false
  ) throws {
    hasLoadedProfile = false
    let migrated = try ProfileMigrationUtil.migrate(profile, hasActiveSession: hasActiveSession)
    if !hasActiveSession && profile.needsMigration {
      throw NSError(
        domain: "ProfileMigration", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not migrate this profile’s trigger settings."])
    }
    if migrated { BlockedProfiles.updateSnapshot(for: profile) }
    startTriggers = profile.startTriggers
    stopConditions = profile.stopConditions
    startNFCTagIds = profile.startNFCTagIds
    startQRCodeIds = profile.startQRCodeIds
    stopNFCTagIds = profile.stopNFCTagIds
    stopQRCodeIds = profile.stopQRCodeIds
    startSchedule = profile.startSchedule
    stopSchedule = profile.stopSchedule
    validate()
    hasLoadedProfile = true
  }

  /// Save to profile
  func saveToProfile(_ profile: BlockedProfiles) {
    profile.startTriggers = startTriggers
    profile.stopConditions = stopConditions
    profile.startNFCTagIds = startNFCTagIds
    profile.startQRCodeIds = startQRCodeIds
    profile.stopNFCTagIds = stopNFCTagIds
    profile.stopQRCodeIds = stopQRCodeIds
    profile.startSchedule = startSchedule
    profile.stopSchedule = stopSchedule

    // Refresh the app-group snapshot now that the trigger fields are set on the
    // in-memory model (SwiftData persistence happens later in the caller) — the
    // snapshot written earlier by createProfile/updateProfile predates these
    // fields, and the FoqosDeviceMonitor extension enforces schedules purely
    // from it (#198)
    BlockedProfiles.updateSnapshot(for: profile)
  }
}
