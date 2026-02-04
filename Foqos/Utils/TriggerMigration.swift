// Foqos/Utils/TriggerMigration.swift
import Foundation

/// Handles migration from legacy blockingStrategyId to new trigger system
enum TriggerMigration {

  /// Maps a legacy strategy ID to the equivalent start triggers and stop conditions
  static func migrateFromStrategy(_ strategyId: String?) -> (
    ProfileStartTriggers, ProfileStopConditions
  ) {
    var start = ProfileStartTriggers()
    var stop = ProfileStopConditions()

    switch strategyId {
    case "ManualBlockingStrategy":
      start.manual = true
      stop.manual = true

    case "NFCBlockingStrategy":
      start.anyNFC = true
      stop.sameNFC = true

    case "NFCManualBlockingStrategy":
      start.manual = true
      stop.anyNFC = true

    case "NFCTimerBlockingStrategy":
      start.manual = true
      stop.anyNFC = true
      stop.timer = true

    case "QRCodeBlockingStrategy":
      start.anyQR = true
      stop.sameQR = true

    case "QRManualBlockingStrategy":
      start.manual = true
      stop.anyQR = true

    case "QRTimerBlockingStrategy":
      start.manual = true
      stop.anyQR = true
      stop.timer = true

    case "ShortcutTimerBlockingStrategy":
      start.manual = true
      stop.timer = true

    default:
      // Unknown strategy defaults to manual
      start.manual = true
      stop.manual = true
    }

    return (start, stop)
  }

  /// Migrates physical unlock tags to the new specific NFC/QR stop conditions
  /// Returns updated stop conditions and the stop tag ID to set
  static func migratePhysicalUnlock(
    stopConditions: ProfileStopConditions,
    physicalUnblockNFCTagId: String?,
    physicalUnblockQRCodeId: String?
  ) -> (ProfileStopConditions, String?) {
    var stop = stopConditions
    var stopTagId: String?

    if let nfcTagId = physicalUnblockNFCTagId {
      // Replace anyNFC with specificNFC
      stop.anyNFC = false
      stop.specificNFC = true
      stopTagId = nfcTagId
    } else if let qrCodeId = physicalUnblockQRCodeId {
      // Replace anyQR with specificQR
      stop.anyQR = false
      stop.specificQR = true
      stopTagId = qrCodeId
    }

    return (stop, stopTagId)
  }

  /// Migrates legacy combined schedule to separate start and stop schedules
  static func migrateSchedule(_ legacySchedule: BlockedProfileSchedule?) -> (
    ProfileScheduleTime?, ProfileScheduleTime?
  ) {
    guard let schedule = legacySchedule, schedule.isActive else {
      return (nil, nil)
    }

    let startSchedule = ProfileScheduleTime(
      days: schedule.days,
      hour: schedule.startHour,
      minute: schedule.startMinute,
      updatedAt: schedule.updatedAt
    )

    let stopSchedule = ProfileScheduleTime(
      days: schedule.days,
      hour: schedule.endHour,
      minute: schedule.endMinute,
      updatedAt: schedule.updatedAt
    )

    return (startSchedule, stopSchedule)
  }
}
