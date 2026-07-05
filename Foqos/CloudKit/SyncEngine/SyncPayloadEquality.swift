import CloudKit
import Foundation

/// Payload equality excludes sync metadata (`lastModified`, `originDeviceId`, `version`)
/// and compares encoded-Data blobs by decoded semantic value where a decoder exists (§2).
enum SyncPayloadEquality {
  static func profilesPayloadEqual(_ a: SyncedProfile, _ b: SyncedProfile) -> Bool {
    return a.name == b.name
      && a.createdAt == b.createdAt
      && a.updatedAt == b.updatedAt
      && a.blockingStrategyId == b.blockingStrategyId
      && a.strategyData == b.strategyData
      && a.order == b.order
      && a.enableLiveActivity == b.enableLiveActivity
      && a.reminderTimeInSeconds == b.reminderTimeInSeconds
      && a.customReminderMessage == b.customReminderMessage
      && a.enableBreaks == b.enableBreaks
      && a.breakTimeInMinutes == b.breakTimeInMinutes
      && a.enableStrictMode == b.enableStrictMode
      && a.enableAllowMode == b.enableAllowMode
      && a.enableAllowModeDomains == b.enableAllowModeDomains
      && a.enableSafariBlocking == b.enableSafariBlocking
      && a.preActivationReminderTimes == b.preActivationReminderTimes
      && a.physicalUnblockNFCTagId == b.physicalUnblockNFCTagId
      && a.physicalUnblockQRCodeId == b.physicalUnblockQRCodeId
      && a.domains == b.domains
      && a.disableBackgroundStops == b.disableBackgroundStops
      && a.isManaged == b.isManaged
      && a.managedByChildId == b.managedByChildId
      && a.profileSchemaVersion == b.profileSchemaVersion
      && a.scheduleLastStoppedAt == b.scheduleLastStoppedAt
      && a.startNFCTagId == b.startNFCTagId
      && a.startQRCodeId == b.startQRCodeId
      && a.stopNFCTagId == b.stopNFCTagId
      && a.stopQRCodeId == b.stopQRCodeId
      && a.schedule == b.schedule
      && a.geofenceRule == b.geofenceRule
      && a.startTriggers == b.startTriggers
      && a.stopConditions == b.stopConditions
      && a.startSchedule == b.startSchedule
      && a.stopSchedule == b.stopSchedule
  }

  static func locationsPayloadEqual(_ a: SyncedLocation, _ b: SyncedLocation) -> Bool {
    return a.name == b.name
      && a.latitude == b.latitude
      && a.longitude == b.longitude
      && a.defaultRadiusMeters == b.defaultRadiusMeters
      && a.isLocked == b.isLocked
  }

  static func emergencyPayloadEqual(
    _ a: SyncedEmergencySettings, _ b: SyncedEmergencySettings
  ) -> Bool {
    return a.unblocksRemaining == b.unblocksRemaining
      && a.resetPeriodInDays == b.resetPeriodInDays
      && a.lastResetDate == b.lastResetDate
      && a.settingsLocked == b.settingsLocked
  }
}
