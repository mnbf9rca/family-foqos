import Foundation

/// Validates complete settings without rewriting the user's selections.
public enum ProfileConditionValidation {
  public static func settingsAreReadable(
    start: ProfileStartTriggers?, stop: ProfileStopConditions?,
    startScheduleData: Data?, stopScheduleData: Data?
  ) -> Bool {
    start != nil && stop != nil
      && (startScheduleData == nil || startScheduleData.flatMap { try? JSONDecoder().decode(ProfileScheduleTime.self, from: $0) } != nil)
      && (stopScheduleData == nil || stopScheduleData.flatMap { try? JSONDecoder().decode(ProfileScheduleTime.self, from: $0) } != nil)
  }

  public static func persistedKeys(schemaVersion: Int, list: [String], scalar: String?) -> [String] {
    schemaVersion == 2 ? scalar.map { [$0] } ?? [] : list
  }

  public static func configurationErrors(
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
    if start.schedule && stop.schedule,
      let start = startSchedule, let stop = stopSchedule,
      start.isActive, stop.isActive,
      start.hour == stop.hour && start.minute == stop.minute
    {
      add("Choose different moments for scheduled start and stop.")
    }
    if start.schedule && stop.schedule,
      let start = startSchedule, let stop = stopSchedule,
      start.isActive, stop.isActive
    {
      let window = ProfileConditionValidation.scheduleWindowMinutes(
        startHour: start.hour, startMinute: start.minute,
        stopHour: stop.hour, stopMinute: stop.minute
      )
      // window == 0 is already reported by the same-time rule above.
      if window > 0 && window < DeviceActivityLimits.minimumIntervalMinutes {
        add(
          "A scheduled window must be at least "
            + "\(DeviceActivityLimits.minimumIntervalMinutes) minutes long"
        )
      }
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
  public static func startRejection(for snapshot: SharedData.ProfileSnapshot, origin: SessionOrigin) -> String? {
    let editRequired = "Please edit this profile before starting. Its start and stop settings need updating."
    guard snapshot.profileSchemaVersion.map({ $0 >= 2 }) == true,
      snapshot.settingsReadable == true,
      let start = snapshot.startTriggers, let stop = snapshot.stopConditions,
      configurationErrors(
        start: start, stop: stop,
        startNFCTagIds: snapshot.startNFCTagIds ?? [], startQRCodeIds: snapshot.startQRCodeIds ?? [],
        stopNFCTagIds: snapshot.stopNFCTagIds ?? [], stopQRCodeIds: snapshot.stopQRCodeIds ?? [],
        startSchedule: snapshot.startSchedule, stopSchedule: snapshot.stopSchedule, forSave: false
      ).isEmpty
    else { return editRequired }

    let entranceEnabled: Bool
    switch origin.kind {
    case .manual: entranceEnabled = start.manual
    case .shortcut: entranceEnabled = start.shortcuts
    case .link: entranceEnabled = start.deepLink
    case .schedule: entranceEnabled = start.schedule
    case .nfc:
      entranceEnabled = start.anyNFC || (start.specificNFC && origin.initiatingKey.map { (snapshot.startNFCTagIds ?? []).contains($0) } == true)
    case .qr:
      entranceEnabled = start.anyQR || (start.specificQR && origin.initiatingKey.map { (snapshot.startQRCodeIds ?? []).contains($0) } == true)
    }
    guard entranceEnabled else {
      return "This profile isn’t set to start this way. Please edit its start settings."
    }
    let hasStop =
      stop.manual || (stop.timer && stop.timerDurationMinutes != nil)
      || stop.schedule || stop.nfc == .any || stop.nfc == .specific
      || stop.qr == .any || stop.qr == .specific
      || (stop.nfc == .same && origin.kind == .nfc && origin.initiatingKey != nil)
      || (stop.qr == .same && origin.kind == .qr && origin.initiatingKey != nil)
    return hasStop ? nil : "This profile has no stop for this start. Please edit it before starting."
  }
}

extension ProfileConditionValidation {
  /// Length, in minutes, of the repeating DeviceActivity window a start/stop
  /// time pair produces. Computed modulo a 24h day so it is correct for both
  /// same-day windows (stop after start) and cross-midnight windows (stop before
  /// start). Returns 0 when the two times are identical.
  public static func scheduleWindowMinutes(
    startHour: Int, startMinute: Int, stopHour: Int, stopMinute: Int
  ) -> Int {
    let startMin = startHour * 60 + startMinute
    let stopMin = stopHour * 60 + stopMinute
    return ((stopMin - startMin) % 1440 + 1440) % 1440
  }
}
