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

  init() {
    validate()
  }

  /// Call when start triggers change to auto-fix invalid stop conditions
  func startTriggersDidChange() {
    validator.autoFix(start: startTriggers, stop: &stopConditions)
    validate()
  }

  /// Run validation and update error list
  func validate() {
    validationErrors = validator.validate(start: startTriggers, stop: stopConditions)
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
