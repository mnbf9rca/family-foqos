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
  @Published var startNFC: [PhysicalKey] = []
  @Published var startQR: [PhysicalKey] = []
  @Published var stopNFC: [PhysicalKey] = []
  @Published var stopQR: [PhysicalKey] = []

  // Schedule bindings
  @Published var startSchedule: ProfileScheduleTime?
  @Published var stopSchedule: ProfileScheduleTime?

  init() {}

  /// Call when start triggers change to auto-fix invalid stop conditions
  func startTriggersDidChange() {
    validator.autoFix(start: startTriggers, stop: &stopConditions)
    validate()
  }

  /// Call when stop conditions change to re-run validation
  func stopConditionsDidChange() {
    validate()
  }

  /// Run validation and update error list
  func validate() {
    var errors = validator.validate(start: startTriggers, stop: stopConditions)

    // Check for missing data when specific toggles are enabled
    if startTriggers.specificNFC && startNFC.isEmpty {
      errors.append("Scan an NFC tag to use as the start trigger")
    }
    if startTriggers.specificQR && startQR.isEmpty {
      errors.append("Scan a QR code to use as the start trigger")
    }
    if stopConditions.specificNFC && stopNFC.isEmpty {
      errors.append("Scan an NFC tag to use as the stop condition")
    }
    if stopConditions.specificQR && stopQR.isEmpty {
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

  /// Returns the existing alert message when the scanned value is already registered.
  func appendKey(
    value: String, to slot: ReferenceWritableKeyPath<TriggerConfigurationModel, [PhysicalKey]>,
    label: String
  ) -> String? {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "Scan a valid \(label == "Tag" ? "NFC tag" : "QR code")"
    }
    guard !self[keyPath: slot].contains(where: { $0.value == value }) else {
      return "This \(label == "Tag" ? "tag" : "QR code") is already on the list"
    }
    self[keyPath: slot].append(PhysicalKey(name: "\(label) \(self[keyPath: slot].count + 1)", value: value))
    validate()
    return nil
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
    if !hasActiveSession {
      let migrated = profile.migrateToV2IfEligible(hasActiveSession: false)
      guard !profile.needsMigration else {
        throw NSError(
          domain: "ProfileMigration", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Could not migrate this profile’s trigger settings."])
      }
      // A failed save leaves the in-memory schema advanced; retry the pending save too.
      if migrated || context.hasChanges {
        try context.save()
        BlockedProfiles.updateSnapshot(for: profile)
      }
    }
    startTriggers = profile.startTriggers
    stopConditions = profile.stopConditions
    startNFC = profile.physicalKeys.startNFC
    startQR = profile.physicalKeys.startQR
    stopNFC = profile.physicalKeys.stopNFC
    stopQR = profile.physicalKeys.stopQR
    startSchedule = profile.startSchedule
    stopSchedule = profile.stopSchedule
    validate()
    hasLoadedProfile = true
  }

  /// Save to profile
  func saveToProfile(_ profile: BlockedProfiles) {
    profile.startTriggers = startTriggers
    profile.stopConditions = stopConditions
    profile.physicalKeys = ProfilePhysicalKeys(
      startNFC: startNFC, startQR: startQR, stopNFC: stopNFC, stopQR: stopQR)
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
