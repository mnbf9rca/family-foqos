import CloudKit
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

  // Physical unlock settings
  var physicalUnblockNFCTagId: String?
  var physicalUnblockQRCodeId: String?

  // Domains
  var domains: [String]?

  // Schedule and geofence (encoded as Data for CloudKit)
  var scheduleData: Data?
  var geofenceRuleData: Data?

  // Other settings
  var disableBackgroundStops: Bool

  // Managed profile fields
  var isManaged: Bool
  var managedByChildId: String?

  // Schema version
  var profileSchemaVersion: Int = 1

  // Sync metadata
  var lastModified: Date
  var originDeviceId: String
  var version: Int

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
    case physicalUnblockNFCTagId
    case physicalUnblockQRCodeId
    case domains
    case scheduleData
    case geofenceRuleData
    case disableBackgroundStops
    case isManaged
    case managedByChildId
    case profileSchemaVersion
    case lastModified
    case originDeviceId
    case version
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
    record[FieldKey.physicalUnblockNFCTagId.rawValue] = physicalUnblockNFCTagId
    record[FieldKey.physicalUnblockQRCodeId.rawValue] = physicalUnblockQRCodeId
    record[FieldKey.domains.rawValue] = domains
    record[FieldKey.scheduleData.rawValue] = scheduleData
    record[FieldKey.geofenceRuleData.rawValue] = geofenceRuleData
    record[FieldKey.disableBackgroundStops.rawValue] = disableBackgroundStops
    record[FieldKey.isManaged.rawValue] = isManaged
    record[FieldKey.managedByChildId.rawValue] = managedByChildId
    record[FieldKey.profileSchemaVersion.rawValue] = profileSchemaVersion
    record[FieldKey.lastModified.rawValue] = lastModified
    record[FieldKey.originDeviceId.rawValue] = originDeviceId
    record[FieldKey.version.rawValue] = version
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
    self.blockingStrategyId = record[FieldKey.blockingStrategyId.rawValue] as? String
    self.strategyData = record[FieldKey.strategyData.rawValue] as? Data
    self.order = record[FieldKey.order.rawValue] as? Int ?? 0
    self.enableLiveActivity = record[FieldKey.enableLiveActivity.rawValue] as? Bool ?? false
    if let reminderInt = record[FieldKey.reminderTimeInSeconds.rawValue] as? Int {
      self.reminderTimeInSeconds = UInt32(reminderInt)
    } else {
      self.reminderTimeInSeconds = nil
    }
    self.customReminderMessage = record[FieldKey.customReminderMessage.rawValue] as? String
    self.enableBreaks = record[FieldKey.enableBreaks.rawValue] as? Bool ?? false
    self.breakTimeInMinutes = record[FieldKey.breakTimeInMinutes.rawValue] as? Int ?? 15
    self.enableStrictMode = record[FieldKey.enableStrictMode.rawValue] as? Bool ?? false
    self.enableAllowMode = record[FieldKey.enableAllowMode.rawValue] as? Bool ?? false
    self.enableAllowModeDomains = record[FieldKey.enableAllowModeDomains.rawValue] as? Bool ?? false
    self.enableSafariBlocking = record[FieldKey.enableSafariBlocking.rawValue] as? Bool ?? true
    self.physicalUnblockNFCTagId = record[FieldKey.physicalUnblockNFCTagId.rawValue] as? String
    self.physicalUnblockQRCodeId = record[FieldKey.physicalUnblockQRCodeId.rawValue] as? String
    self.domains = record[FieldKey.domains.rawValue] as? [String]
    self.scheduleData = record[FieldKey.scheduleData.rawValue] as? Data
    self.geofenceRuleData = record[FieldKey.geofenceRuleData.rawValue] as? Data
    self.disableBackgroundStops = record[FieldKey.disableBackgroundStops.rawValue] as? Bool ?? false
    self.isManaged = record[FieldKey.isManaged.rawValue] as? Bool ?? false
    self.managedByChildId = record[FieldKey.managedByChildId.rawValue] as? String
    self.profileSchemaVersion = record[FieldKey.profileSchemaVersion.rawValue] as? Int ?? 1
    self.lastModified = lastModified
    self.originDeviceId = originDeviceId
    self.version = version
  }

  // MARK: - Initialization from BlockedProfiles

  init(
    from profile: BlockedProfiles,
    originDeviceId: String
  ) {
    self.profileId = profile.id
    self.name = profile.name
    self.createdAt = profile.createdAt
    self.updatedAt = profile.updatedAt
    self.blockingStrategyId = profile.blockingStrategyId
    self.strategyData = profile.strategyData
    self.order = profile.order
    self.enableLiveActivity = profile.enableLiveActivity
    self.reminderTimeInSeconds = profile.reminderTimeInSeconds
    self.customReminderMessage = profile.customReminderMessage
    self.enableBreaks = profile.enableBreaks
    self.breakTimeInMinutes = profile.breakTimeInMinutes
    self.enableStrictMode = profile.enableStrictMode
    self.enableAllowMode = profile.enableAllowMode
    self.enableAllowModeDomains = profile.enableAllowModeDomains
    self.enableSafariBlocking = profile.enableSafariBlocking
    self.physicalUnblockNFCTagId = profile.physicalUnblockNFCTagId
    self.physicalUnblockQRCodeId = profile.physicalUnblockQRCodeId
    self.domains = profile.domains
    self.disableBackgroundStops = profile.disableBackgroundStops
    self.isManaged = profile.isManaged
    self.managedByChildId = profile.managedByChildId
    self.profileSchemaVersion = profile.profileSchemaVersion
    self.lastModified = Date()
    self.originDeviceId = originDeviceId
    self.version = profile.syncVersion

    // Encode schedule and geofence rule
    if let schedule = profile.schedule {
      self.scheduleData = try? JSONEncoder().encode(schedule)
    } else {
      self.scheduleData = nil
    }

    if let geofenceRule = profile.geofenceRule {
      self.geofenceRuleData = try? JSONEncoder().encode(geofenceRule)
    } else {
      self.geofenceRuleData = nil
    }
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
    self.isLocked = record[FieldKey.isLocked.rawValue] as? Bool ?? false
    self.lastModified = lastModified
  }

  // MARK: - Initialization from SavedLocation

  init(from location: SavedLocation) {
    self.locationId = location.id
    self.name = location.name
    self.latitude = location.latitude
    self.longitude = location.longitude
    self.defaultRadiusMeters = location.defaultRadiusMeters
    self.isLocked = location.isLocked
    self.lastModified = location.updatedAt
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
    self.requestId = UUID()
    self.clearRemoteAppSelections = clearRemoteAppSelections
    self.requestedAt = Date()
    self.originDeviceId = originDeviceId
  }
}
