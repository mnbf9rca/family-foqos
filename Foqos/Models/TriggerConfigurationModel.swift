// Foqos/Models/TriggerConfigurationModel.swift
import Foundation
import SwiftUI

/// Observable model for trigger configuration UI
@MainActor
final class TriggerConfigurationModel: ObservableObject {
  private let validator = TriggerValidator()

  @Published var startTriggers = ProfileStartTriggers()
  @Published var stopConditions = ProfileStopConditions()
  @Published var validationErrors: [String] = []

  // Tag bindings
  @Published var startNFCTagId: String?
  @Published var startQRCodeId: String?
  @Published var stopNFCTagId: String?
  @Published var stopQRCodeId: String?

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
    validationErrors = validator.validate(start: startTriggers, stop: stopConditions)
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
  func loadFromProfile(_ profile: BlockedProfiles) {
    startTriggers = profile.startTriggers
    stopConditions = profile.stopConditions
    startNFCTagId = profile.startNFCTagId
    startQRCodeId = profile.startQRCodeId
    stopNFCTagId = profile.stopNFCTagId
    stopQRCodeId = profile.stopQRCodeId
    startSchedule = profile.startSchedule
    stopSchedule = profile.stopSchedule
    validate()
  }

  /// Save to profile
  func saveToProfile(_ profile: BlockedProfiles) {
    profile.startTriggers = startTriggers
    profile.stopConditions = stopConditions
    profile.startNFCTagId = startNFCTagId
    profile.startQRCodeId = startQRCodeId
    profile.stopNFCTagId = stopNFCTagId
    profile.stopQRCodeId = stopQRCodeId
    profile.startSchedule = startSchedule
    profile.stopSchedule = stopSchedule
  }
}
