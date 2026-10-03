import FoqosShared
// Foqos/Models/TriggerValidator.swift
import Foundation

/// Validates complete settings without rewriting the user's selections.
final class TriggerValidator {
  func validate(
    start: ProfileStartTriggers,
    stop: ProfileStopConditions,
    startNFCTagIds: [String] = [],
    startQRCodeIds: [String] = [],
    stopNFCTagIds: [String] = [],
    stopQRCodeIds: [String] = [],
    startSchedule: ProfileScheduleTime? = nil,
    stopSchedule: ProfileScheduleTime? = nil,
    settingsReadable: Bool = true,
    forSave: Bool = true
  ) -> [String] {
    ProfileConditionValidation.configurationErrors(
      start: start, stop: stop, startNFCTagIds: startNFCTagIds, startQRCodeIds: startQRCodeIds,
      stopNFCTagIds: stopNFCTagIds, stopQRCodeIds: stopQRCodeIds,
      startSchedule: startSchedule, stopSchedule: stopSchedule,
      settingsReadable: settingsReadable, forSave: forSave
    )
  }
}
