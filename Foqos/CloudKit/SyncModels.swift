import CloudKit
import FoqosShared
import Foundation

// MARK: - CloudKit Constants

/// Shared CloudKit configuration used across all sync services
enum CloudKitConstants {
  static let containerIdentifier = "iCloud.com.cynexia.family-foqos"
  static let syncZoneName = "DeviceSync"
}

// MARK: - SyncedProfile

/// CloudKit record representation of a profile for same-user multi-device sync.
/// Note: FamilyActivitySelection (app tokens) are NOT synced as they are device-specific.
struct SyncedProfile: Codable, Equatable {
  var profileId: UUID
  var name: String
  var createdAt: Date
  var updatedAt: Date

  // Strategy settings
  var blockingStrategyId: String?
  var strategyData: Data?
  var order: Int

  // Profile settings
  var enableLiveActivity: Bool
  var reminderTimeInSeconds: UInt32?
  var customReminderMessage: String?
  var enableBreaks: Bool
  var breakTimeInMinutes: Int
  var enableStrictMode: Bool
  var enableAllowMode: Bool
  var enableAllowModeDomains: Bool
  var enableSafariBlocking: Bool
  var preActivationReminderTimesData: Data?

  // Physical unlock settings
  var physicalUnblockNFCTagId: String?
  var physicalUnblockQRCodeId: String?

  /// Domains
  var domains: [String]?

  // Schedule and geofence (encoded as Data for CloudKit)
  var scheduleData: Data?
  var geofenceRuleData: Data?

  // V2 trigger system
  var startTriggersData: Data?
  var stopConditionsData: Data?
  var startScheduleData: Data?
  var stopScheduleData: Data?
  var startNFCTagId: String?
  var startQRCodeId: String?
  var stopNFCTagId: String?
  var stopQRCodeId: String?

  /// Other settings
  var disableBackgroundStops: Bool

  // Managed profile fields
  var isManaged: Bool
  var managedByChildId: String?

  // Sync metadata
  var lastModified: Date
  var originDeviceId: String
  var version: Int

  // Records when schedule-started session was last manually stopped (synced across devices)
  var scheduleLastStoppedAt: Date?

  // Schema version (for trigger system migration)
  var profileSchemaVersion: Int

  // MARK: - CloudKit Record Type

  static let recordType = "SyncedProfile"

  // MARK: - CloudKit Field Keys

  enum FieldKey: String {
    case profileId
    case name
    case createdAt
    case updatedAt
    case blockingStrategyId
    case strategyData
    case order
    case enableLiveActivity
    case reminderTimeInSeconds
    case customReminderMessage
    case enableBreaks
    case breakTimeInMinutes
    case enableStrictMode
    case enableAllowMode
    case enableAllowModeDomains
    case enableSafariBlocking
    case preActivationReminderTimesData
    case physicalUnblockNFCTagId
    case physicalUnblockQRCodeId
    case domains
    case scheduleData
    case geofenceRuleData
    case startTriggersData
    case stopConditionsData
    case startScheduleData
    case stopScheduleData
    case startNFCTagId
    case startQRCodeId
    case stopNFCTagId
    case stopQRCodeId
    case disableBackgroundStops
    case isManaged
    case managedByChildId
    case lastModified
    case originDeviceId
    case version
    case profileSchemaVersion
    case scheduleLastStoppedAt
  }

  // MARK: - CloudKit Conversion

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: profileId.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: SyncedProfile.recordType, recordID: recordID)
    updateCKRecord(record)
    return record
  }

  /// Update an existing CKRecord with this profile's values
  func updateCKRecord(_ record: CKRecord) {
    record[FieldKey.profileId.rawValue] = profileId.uuidString
    record[FieldKey.name.rawValue] = name
    record[FieldKey.createdAt.rawValue] = createdAt
    record[FieldKey.updatedAt.rawValue] = updatedAt
    record[FieldKey.blockingStrategyId.rawValue] = blockingStrategyId
    record[FieldKey.strategyData.rawValue] = strategyData
    record[FieldKey.order.rawValue] = order
    record[FieldKey.enableLiveActivity.rawValue] = enableLiveActivity
    record[FieldKey.reminderTimeInSeconds.rawValue] = reminderTimeInSeconds.map { Int($0) }
    record[FieldKey.customReminderMessage.rawValue] = customReminderMessage
    record[FieldKey.enableBreaks.rawValue] = enableBreaks
    record[FieldKey.breakTimeInMinutes.rawValue] = breakTimeInMinutes
    record[FieldKey.enableStrictMode.rawValue] = enableStrictMode
    record[FieldKey.enableAllowMode.rawValue] = enableAllowMode
    record[FieldKey.enableAllowModeDomains.rawValue] = enableAllowModeDomains
    record[FieldKey.enableSafariBlocking.rawValue] = enableSafariBlocking
    record[FieldKey.preActivationReminderTimesData.rawValue] = preActivationReminderTimesData
    record[FieldKey.physicalUnblockNFCTagId.rawValue] = physicalUnblockNFCTagId
    record[FieldKey.physicalUnblockQRCodeId.rawValue] = physicalUnblockQRCodeId
    record[FieldKey.domains.rawValue] = domains
    record[FieldKey.scheduleData.rawValue] = scheduleData
    record[FieldKey.geofenceRuleData.rawValue] = geofenceRuleData
    record[FieldKey.startTriggersData.rawValue] = startTriggersData
    record[FieldKey.stopConditionsData.rawValue] = stopConditionsData
    record[FieldKey.startScheduleData.rawValue] = startScheduleData
    record[FieldKey.stopScheduleData.rawValue] = stopScheduleData
    record[FieldKey.startNFCTagId.rawValue] = startNFCTagId
    record[FieldKey.startQRCodeId.rawValue] = startQRCodeId
    record[FieldKey.stopNFCTagId.rawValue] = stopNFCTagId
    record[FieldKey.stopQRCodeId.rawValue] = stopQRCodeId
    record[FieldKey.disableBackgroundStops.rawValue] = disableBackgroundStops
    record[FieldKey.isManaged.rawValue] = isManaged
    record[FieldKey.managedByChildId.rawValue] = managedByChildId
    record[FieldKey.lastModified.rawValue] = lastModified
    record[FieldKey.originDeviceId.rawValue] = originDeviceId
    record[FieldKey.version.rawValue] = version
    record[FieldKey.profileSchemaVersion.rawValue] = profileSchemaVersion
    record[FieldKey.scheduleLastStoppedAt.rawValue] = scheduleLastStoppedAt
  }

  init?(from record: CKRecord) {
    guard record.recordType == SyncedProfile.recordType,
      let profileIdString = record[FieldKey.profileId.rawValue] as? String,
      let profileId = UUID(uuidString: profileIdString),
      let name = record[FieldKey.name.rawValue] as? String,
      let createdAt = record[FieldKey.createdAt.rawValue] as? Date,
      let updatedAt = record[FieldKey.updatedAt.rawValue] as? Date,
      let lastModified = record[FieldKey.lastModified.rawValue] as? Date,
      let originDeviceId = record[FieldKey.originDeviceId.rawValue] as? String,
      let version = record[FieldKey.version.rawValue] as? Int
    else {
      return nil
    }

    self.profileId = profileId
    self.name = name
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    blockingStrategyId = record[FieldKey.blockingStrategyId.rawValue] as? String
    strategyData = record[FieldKey.strategyData.rawValue] as? Data
    order = record[FieldKey.order.rawValue] as? Int ?? 0
    enableLiveActivity = record[FieldKey.enableLiveActivity.rawValue] as? Bool ?? false
    if let reminderInt = record[FieldKey.reminderTimeInSeconds.rawValue] as? Int {
      // #265: range-check the narrowing cast (same defensive-decode discipline as the
      // `UInt8(exactly:)` sibling below, and as the C1/#275 clamp for out-of-domain values).
      // Invalid CloudKit data degrades to "no reminder" instead of trapping the inbound apply.
      if let bounded = UInt32(exactly: reminderInt) {
        reminderTimeInSeconds = bounded
      } else {
        Log.warning(
          "Ignoring out-of-range reminderTimeInSeconds \(reminderInt) from synced profile",
          category: .sync)
        reminderTimeInSeconds = nil
      }
    } else {
      reminderTimeInSeconds = nil
    }
    customReminderMessage = record[FieldKey.customReminderMessage.rawValue] as? String
    enableBreaks = record[FieldKey.enableBreaks.rawValue] as? Bool ?? false
    breakTimeInMinutes = record[FieldKey.breakTimeInMinutes.rawValue] as? Int ?? 15
    enableStrictMode = record[FieldKey.enableStrictMode.rawValue] as? Bool ?? false
    enableAllowMode = record[FieldKey.enableAllowMode.rawValue] as? Bool ?? false
    enableAllowModeDomains = record[FieldKey.enableAllowModeDomains.rawValue] as? Bool ?? false
    enableSafariBlocking = record[FieldKey.enableSafariBlocking.rawValue] as? Bool ?? true
    if let data = record[FieldKey.preActivationReminderTimesData.rawValue] as? Data {
      preActivationReminderTimesData = data
    } else if let legacyEnabled = record["preActivationReminderEnabled"] as? Bool,
      legacyEnabled,
      let legacyMinutes = record["preActivationReminderMinutes"] as? Int,
      let uint8Minutes = UInt8(exactly: legacyMinutes),
      (1...5).contains(legacyMinutes)
    {
      // Migration: synthesize new format from legacy single-reminder fields
      preActivationReminderTimesData = try? JSONEncoder().encode([uint8Minutes])
    } else {
      preActivationReminderTimesData = nil
    }
    physicalUnblockNFCTagId = record[FieldKey.physicalUnblockNFCTagId.rawValue] as? String
    physicalUnblockQRCodeId = record[FieldKey.physicalUnblockQRCodeId.rawValue] as? String
    domains = record[FieldKey.domains.rawValue] as? [String]
    scheduleData = record[FieldKey.scheduleData.rawValue] as? Data
    geofenceRuleData = record[FieldKey.geofenceRuleData.rawValue] as? Data
    startTriggersData = record[FieldKey.startTriggersData.rawValue] as? Data
    stopConditionsData = record[FieldKey.stopConditionsData.rawValue] as? Data
    startScheduleData = record[FieldKey.startScheduleData.rawValue] as? Data
    stopScheduleData = record[FieldKey.stopScheduleData.rawValue] as? Data
    startNFCTagId = record[FieldKey.startNFCTagId.rawValue] as? String
    startQRCodeId = record[FieldKey.startQRCodeId.rawValue] as? String
    stopNFCTagId = record[FieldKey.stopNFCTagId.rawValue] as? String
    stopQRCodeId = record[FieldKey.stopQRCodeId.rawValue] as? String
    disableBackgroundStops = record[FieldKey.disableBackgroundStops.rawValue] as? Bool ?? false
    isManaged = record[FieldKey.isManaged.rawValue] as? Bool ?? false
    managedByChildId = record[FieldKey.managedByChildId.rawValue] as? String
    self.lastModified = lastModified
    self.originDeviceId = originDeviceId
    self.version = version
    // Default to schema version 1 (legacy) if not present - older devices don't send this field
    profileSchemaVersion = record[FieldKey.profileSchemaVersion.rawValue] as? Int ?? 1
    scheduleLastStoppedAt = record[FieldKey.scheduleLastStoppedAt.rawValue] as? Date
  }

  // MARK: - Initialization from BlockedProfiles

  init(
    from profile: BlockedProfiles,
    originDeviceId: String
  ) {
    profileId = profile.id
    name = profile.name
    createdAt = profile.createdAt
    updatedAt = profile.updatedAt
    blockingStrategyId = profile.blockingStrategyId
    strategyData = profile.strategyData
    order = profile.order
    enableLiveActivity = profile.enableLiveActivity
    reminderTimeInSeconds = profile.reminderTimeInSeconds
    customReminderMessage = profile.customReminderMessage
    enableBreaks = profile.enableBreaks
    breakTimeInMinutes = profile.breakTimeInMinutes
    enableStrictMode = profile.enableStrictMode
    enableAllowMode = profile.enableAllowMode
    enableAllowModeDomains = profile.enableAllowModeDomains
    enableSafariBlocking = profile.enableSafariBlocking
    preActivationReminderTimesData = profile.preActivationReminderTimesData
    physicalUnblockNFCTagId = profile.physicalUnblockNFCTagId
    physicalUnblockQRCodeId = profile.physicalUnblockQRCodeId
    domains = profile.domains
    disableBackgroundStops = profile.disableBackgroundStops
    isManaged = profile.isManaged
    managedByChildId = profile.managedByChildId
    lastModified = Date()
    self.originDeviceId = originDeviceId
    version = profile.syncVersion
    profileSchemaVersion = profile.profileSchemaVersion

    // Encode schedule and geofence rule (legacy scheduleData still written for backwards compat)
    if let schedule = profile.schedule {
      scheduleData = try? JSONEncoder().encode(schedule)
    } else {
      scheduleData = nil
    }

    if let geofenceRule = profile.geofenceRule {
      geofenceRuleData = try? JSONEncoder().encode(geofenceRule)
    } else {
      geofenceRuleData = nil
    }

    // V2 trigger fields
    startTriggersData = try? JSONEncoder().encode(profile.startTriggers)
    stopConditionsData = try? JSONEncoder().encode(profile.stopConditions)
    if let startSchedule = profile.startSchedule {
      startScheduleData = try? JSONEncoder().encode(startSchedule)
    }
    if let stopSchedule = profile.stopSchedule {
      stopScheduleData = try? JSONEncoder().encode(stopSchedule)
    }
    startNFCTagId = profile.startNFCTagId
    startQRCodeId = profile.startQRCodeId
    stopNFCTagId = profile.stopNFCTagId
    stopQRCodeId = profile.stopQRCodeId
    scheduleLastStoppedAt = profile.scheduleLastStoppedAt
  }

  // MARK: - Decode Schedule and Geofence

  var schedule: BlockedProfileSchedule? {
    guard let data = scheduleData else { return nil }
    return try? JSONDecoder().decode(BlockedProfileSchedule.self, from: data)
  }

  var geofenceRule: ProfileGeofenceRule? {
    guard let data = geofenceRuleData else { return nil }
    return try? JSONDecoder().decode(ProfileGeofenceRule.self, from: data)
  }

  var startTriggers: ProfileStartTriggers? {
    guard let data = startTriggersData else { return nil }
    return try? JSONDecoder().decode(ProfileStartTriggers.self, from: data)
  }

  var stopConditions: ProfileStopConditions? {
    guard let data = stopConditionsData else { return nil }
    return try? JSONDecoder().decode(ProfileStopConditions.self, from: data)
  }

  var startSchedule: ProfileScheduleTime? {
    guard let data = startScheduleData else { return nil }
    return try? JSONDecoder().decode(ProfileScheduleTime.self, from: data)
  }

  var stopSchedule: ProfileScheduleTime? {
    guard let data = stopScheduleData else { return nil }
    return try? JSONDecoder().decode(ProfileScheduleTime.self, from: data)
  }

  var preActivationReminderTimes: [UInt8] {
    guard let data = preActivationReminderTimesData else { return [] }
    return (try? JSONDecoder().decode([UInt8].self, from: data)) ?? []
  }
}

// MARK: - SyncedSession (Legacy)

/// Legacy session record type - kept only for cleanup of old records
enum LegacySyncedSession {
  static let recordType = "SyncedSession"
}

// MARK: - SyncedLocation

/// CloudKit record representation of a saved location for same-user multi-device sync.
struct SyncedLocation: Codable, Equatable {
  var locationId: UUID
  var name: String
  var latitude: Double
  var longitude: Double
  var defaultRadiusMeters: Double
  var isLocked: Bool
  var lastModified: Date

  // MARK: - CloudKit Record Type

  static let recordType = "SyncedLocation"

  // MARK: - CloudKit Field Keys

  enum FieldKey: String {
    case locationId
    case name
    case latitude
    case longitude
    case defaultRadiusMeters
    case isLocked
    case lastModified
  }

  // MARK: - CloudKit Conversion

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: locationId.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: SyncedLocation.recordType, recordID: recordID)
    updateCKRecord(record)
    return record
  }

  /// Update an existing CKRecord with this location's values
  func updateCKRecord(_ record: CKRecord) {
    record[FieldKey.locationId.rawValue] = locationId.uuidString
    record[FieldKey.name.rawValue] = name
    record[FieldKey.latitude.rawValue] = latitude
    record[FieldKey.longitude.rawValue] = longitude
    record[FieldKey.defaultRadiusMeters.rawValue] = defaultRadiusMeters
    record[FieldKey.isLocked.rawValue] = isLocked
    record[FieldKey.lastModified.rawValue] = lastModified
  }

  init?(from record: CKRecord) {
    guard record.recordType == SyncedLocation.recordType,
      let locationIdString = record[FieldKey.locationId.rawValue] as? String,
      let locationId = UUID(uuidString: locationIdString),
      let name = record[FieldKey.name.rawValue] as? String,
      let latitude = record[FieldKey.latitude.rawValue] as? Double,
      let longitude = record[FieldKey.longitude.rawValue] as? Double,
      let defaultRadiusMeters = record[FieldKey.defaultRadiusMeters.rawValue] as? Double,
      let lastModified = record[FieldKey.lastModified.rawValue] as? Date
    else {
      return nil
    }

    self.locationId = locationId
    self.name = name
    self.latitude = latitude
    self.longitude = longitude
    self.defaultRadiusMeters = defaultRadiusMeters
    isLocked = record[FieldKey.isLocked.rawValue] as? Bool ?? false
    self.lastModified = lastModified
  }

  init(
    locationId: UUID,
    name: String,
    latitude: Double,
    longitude: Double,
    defaultRadiusMeters: Double,
    isLocked: Bool,
    lastModified: Date
  ) {
    self.locationId = locationId
    self.name = name
    self.latitude = latitude
    self.longitude = longitude
    self.defaultRadiusMeters = defaultRadiusMeters
    self.isLocked = isLocked
    self.lastModified = lastModified
  }

  // MARK: - Initialization from SavedLocation

  init(from location: SavedLocation) {
    locationId = location.id
    name = location.name
    latitude = location.latitude
    longitude = location.longitude
    defaultRadiusMeters = location.defaultRadiusMeters
    isLocked = location.isLocked
    lastModified = location.updatedAt
  }
}

// MARK: - Synced Emergency Settings

/// CloudKit record representation of emergency unblock settings for same-user multi-device sync.
/// One record per user (fixed record name), version-based conflict resolution.
struct SyncedEmergencySettings: Codable, Equatable {
  var unblocksRemaining: Int
  var resetPeriodInDays: Int
  var lastResetDate: Date
  var settingsLocked: Bool
  var version: Int
  var lastModified: Date
  var originDeviceId: String

  // MARK: - CloudKit Record Type

  static let recordType = "EmergencySettings"
  static let recordName = "emergency-settings"

  // MARK: - CloudKit Field Keys

  enum FieldKey: String {
    case unblocksRemaining
    case resetPeriodInDays
    case lastResetDate
    case settingsLocked
    case version
    case lastModified
    case originDeviceId
  }

  // MARK: - Defaults

  static func defaults(deviceId: String) -> SyncedEmergencySettings {
    SyncedEmergencySettings(
      unblocksRemaining: 3,
      resetPeriodInDays: 28,
      lastResetDate: Date(),
      settingsLocked: false,
      version: 0,
      lastModified: Date(),
      originDeviceId: deviceId
    )
  }

  // MARK: - CloudKit Conversion

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: Self.recordName, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    updateCKRecord(record)
    return record
  }

  func updateCKRecord(_ record: CKRecord) {
    record[FieldKey.unblocksRemaining.rawValue] = unblocksRemaining
    record[FieldKey.resetPeriodInDays.rawValue] = resetPeriodInDays
    record[FieldKey.lastResetDate.rawValue] = lastResetDate
    record[FieldKey.settingsLocked.rawValue] = settingsLocked
    record[FieldKey.version.rawValue] = version
    record[FieldKey.lastModified.rawValue] = lastModified
    record[FieldKey.originDeviceId.rawValue] = originDeviceId
  }

  init?(from record: CKRecord) {
    guard record.recordType == Self.recordType,
      let unblocksRemaining = record[FieldKey.unblocksRemaining.rawValue] as? Int,
      let resetPeriodInDays = record[FieldKey.resetPeriodInDays.rawValue] as? Int,
      let lastResetDate = record[FieldKey.lastResetDate.rawValue] as? Date,
      let version = record[FieldKey.version.rawValue] as? Int,
      let lastModified = record[FieldKey.lastModified.rawValue] as? Date
    else {
      return nil
    }

    self.unblocksRemaining = unblocksRemaining
    self.resetPeriodInDays = resetPeriodInDays
    self.lastResetDate = lastResetDate
    self.settingsLocked = record[FieldKey.settingsLocked.rawValue] as? Bool ?? false
    self.version = version
    self.lastModified = lastModified
    self.originDeviceId = record[FieldKey.originDeviceId.rawValue] as? String ?? ""
  }

  init(
    unblocksRemaining: Int,
    resetPeriodInDays: Int,
    lastResetDate: Date,
    settingsLocked: Bool,
    version: Int,
    lastModified: Date,
    originDeviceId: String
  ) {
    self.unblocksRemaining = unblocksRemaining
    self.resetPeriodInDays = resetPeriodInDays
    self.lastResetDate = lastResetDate
    self.settingsLocked = settingsLocked
    self.version = version
    self.lastModified = lastModified
    self.originDeviceId = originDeviceId
  }
}

// MARK: - Synced Emergency Reset Epoch

/// The current emergency-unblock reset epoch, synced as a single fixed-name record and merged by
/// max() so all devices converge on one agreed epoch boundary (#221). This deliberately does not
/// ride the versioned emergency-settings config record.
struct SyncedEmergencyEpoch: Codable, Equatable {
  var epoch: Int

  static let recordType = "EmergencyResetEpoch"
  static let recordName = "emergency-reset-epoch"

  enum FieldKey: String {
    case epoch
  }

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let record = CKRecord(
      recordType: Self.recordType,
      recordID: CKRecord.ID(recordName: Self.recordName, zoneID: zoneID))
    updateCKRecord(record)
    return record
  }

  func updateCKRecord(_ record: CKRecord) {
    record[FieldKey.epoch.rawValue] = epoch
  }

  init(epoch: Int) {
    self.epoch = epoch
  }

  init?(from record: CKRecord) {
    guard record.recordType == Self.recordType,
      let epoch = record[FieldKey.epoch.rawValue] as? Int
    else {
      return nil
    }
    self.epoch = epoch
  }
}

// MARK: - Synced Emergency Unblock Event

/// One immutable record per consumed emergency unblock. Union-merged across devices (write-once,
/// unique recordName), so concurrent unblocks never collide (#221).
struct SyncedEmergencyUnblockEvent: Codable, Equatable {
  var id: UUID
  var deviceId: String
  var consumedAt: Date
  var resetEpoch: Int

  static let recordType = "EmergencyUnblockEvent"
  static let recordNamePrefix = "EmergencyUnblock_"
  var recordName: String { Self.recordNamePrefix + id.uuidString }

  enum FieldKey: String {
    case id
    case deviceId
    case consumedAt
    case resetEpoch
  }

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let record = CKRecord(
      recordType: Self.recordType,
      recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
    updateCKRecord(record)
    return record
  }

  func updateCKRecord(_ record: CKRecord) {
    record[FieldKey.id.rawValue] = id.uuidString
    record[FieldKey.deviceId.rawValue] = deviceId
    record[FieldKey.consumedAt.rawValue] = consumedAt
    record[FieldKey.resetEpoch.rawValue] = resetEpoch
  }

  init(id: UUID, deviceId: String, consumedAt: Date, resetEpoch: Int) {
    self.id = id
    self.deviceId = deviceId
    self.consumedAt = consumedAt
    self.resetEpoch = resetEpoch
  }

  init?(from record: CKRecord) {
    guard record.recordType == Self.recordType,
      let idString = record[FieldKey.id.rawValue] as? String,
      let id = UUID(uuidString: idString),
      let consumedAt = record[FieldKey.consumedAt.rawValue] as? Date,
      let resetEpoch = record[FieldKey.resetEpoch.rawValue] as? Int
    else {
      return nil
    }
    self.id = id
    self.deviceId = record[FieldKey.deviceId.rawValue] as? String ?? ""
    self.consumedAt = consumedAt
    self.resetEpoch = resetEpoch
  }
}

// MARK: - Sync Reset Request

/// CloudKit record for requesting a sync reset across devices.
struct SyncResetRequest: Codable, Equatable {
  var requestId: UUID
  var clearRemoteAppSelections: Bool
  var requestedAt: Date
  var originDeviceId: String

  // MARK: - CloudKit Record Type

  static let recordType = "SyncResetRequest"

  // MARK: - CloudKit Field Keys

  enum FieldKey: String {
    case requestId
    case clearRemoteAppSelections
    case requestedAt
    case originDeviceId
  }

  // MARK: - CloudKit Conversion

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: requestId.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: SyncResetRequest.recordType, recordID: recordID)

    record[FieldKey.requestId.rawValue] = requestId.uuidString
    record[FieldKey.clearRemoteAppSelections.rawValue] = clearRemoteAppSelections
    record[FieldKey.requestedAt.rawValue] = requestedAt
    record[FieldKey.originDeviceId.rawValue] = originDeviceId

    return record
  }

  init?(from record: CKRecord) {
    guard record.recordType == SyncResetRequest.recordType,
      let requestIdString = record[FieldKey.requestId.rawValue] as? String,
      let requestId = UUID(uuidString: requestIdString),
      let clearRemoteAppSelections = record[FieldKey.clearRemoteAppSelections.rawValue] as? Bool,
      let requestedAt = record[FieldKey.requestedAt.rawValue] as? Date,
      let originDeviceId = record[FieldKey.originDeviceId.rawValue] as? String
    else {
      return nil
    }

    self.requestId = requestId
    self.clearRemoteAppSelections = clearRemoteAppSelections
    self.requestedAt = requestedAt
    self.originDeviceId = originDeviceId
  }

  init(clearRemoteAppSelections: Bool, originDeviceId: String) {
    requestId = UUID()
    self.clearRemoteAppSelections = clearRemoteAppSelections
    requestedAt = Date()
    self.originDeviceId = originDeviceId
  }
}
