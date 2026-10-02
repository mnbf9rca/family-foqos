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
    guard settingsReadable, forSave || !stop.requiresEditingAfterConversion else {
      return ["These settings couldn’t be saved. Please check this profile and try again."]
    }
    var errors: [String] = []
    func add(_ message: String) {
      if !errors.contains(message) { errors.append(message) }
    }
    func usableKeys(_ ids: [String]) -> Bool {
      !ids.isEmpty && ids.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    func validSchedule(_ schedule: ProfileScheduleTime?) -> Bool {
      guard let schedule else { return false }
      return schedule.isActive && (0...23).contains(schedule.hour) && (0...59).contains(schedule.minute)
    }
    if !start.isValid { add("Choose at least one way to start this profile.") }
    let nfcKeys = usableKeys(stopNFCTagIds)
    let qrKeys = usableKeys(stopQRCodeIds)
    if (start.specificNFC && !usableKeys(startNFCTagIds)) || (stop.nfc == .specific && !nfcKeys) {
      add("Choose at least one NFC tag.")
    }
    if (start.specificQR && !usableKeys(startQRCodeIds)) || (stop.qr == .specific && !qrKeys) {
      add("Choose at least one QR code.")
    }
    let scheduledStop = stop.schedule && validSchedule(stopSchedule)
    if (start.schedule && !validSchedule(startSchedule)) || (stop.schedule && !scheduledStop) {
      add("Choose the days and time for this schedule.")
    }
    let timerValid =
      stop.timerDurationMinutes.map {
        (DeviceActivityLimits.minimumIntervalMinutes...DeviceActivityLimits.maximumTimerMinutes).contains($0)
      } ?? false
    if stop.timer && !timerValid && (forSave || stop.timerDurationMinutes != nil) {
      add("Choose a timer from 15 minutes to 23 hours 59 minutes.")
    }
    let nonSameStop =
      stop.manual || (stop.timer && timerValid) || scheduledStop
      || stop.nfc == .any || (stop.nfc == .specific && nfcKeys)
      || stop.qr == .any || (stop.qr == .specific && qrKeys)
    let hasSame = stop.nfc == .same || stop.qr == .same
    if !nonSameStop && !hasSame && errors.isEmpty {
      add("Add at least one stop before saving this profile.")
    } else if !stop.manual && !stop.timer && !stop.schedule && stop.nfc == .none && stop.qr == .none {
      add("Add at least one stop before saving this profile.")
    }
    if !nonSameStop && hasSame && start.isValid {
      let nfcUncovered = stop.nfc == .same && (!start.hasNFC || start.manual || start.shortcuts || start.schedule || start.hasQR || start.deepLink)
      let qrUncovered = stop.qr == .same && (!start.hasQR || start.manual || start.shortcuts || start.schedule || start.hasNFC || start.deepLink)
      if start.deepLink {
        add("Links can come from NFC tags or QR codes. Add a stop that doesn’t rely on the same tag.")
      } else if nfcUncovered {
        add("Same NFC tag only works after an NFC start. Add another stop for other starts.")
      } else if qrUncovered {
        add("Same QR code only works after a QR start. Add another stop for other starts.")
      }
    }
    return errors
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
    let startMin = startHour * 60 + startMinute
    let stopMin = stopHour * 60 + stopMinute
    return ((stopMin - startMin) % 1440 + 1440) % 1440
  }
}
