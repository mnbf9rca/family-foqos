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

extension TriggerValidator {
  /// Length, in minutes, of the repeating DeviceActivity window a start/stop
  /// time pair produces. Computed modulo a 24h day so it is correct for both
  /// same-day windows (stop after start) and cross-midnight windows (stop before
  /// start). Returns 0 when the two times are identical.
  static func scheduleWindowMinutes(
    startHour: Int, startMinute: Int, stopHour: Int, stopMinute: Int
  ) -> Int {
    ProfileConditionValidation.scheduleWindowMinutes(
      startHour: startHour, startMinute: startMinute, stopHour: stopHour, stopMinute: stopMinute
    )
  }
}
