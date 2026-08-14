import CloudKit
import Foundation
import SwiftData

/// Materializes CKRecords for `nextRecordZoneChangeBatch` on cached system fields (fresh if none),
/// reusing the Synced* `toCKRecord`/`updateCKRecord` helpers. Returns nil for §5.4 removal
/// (entity absent, or `isNewerSchemaVersion` profile). Sessions are never materialized here (§6).
@MainActor
final class RecordProvider {
  private let modelContext: ModelContext
  private let store: SyncEngineStore
  private let emergencyManager: EmergencyUnblockManager
  private let deviceId: String
  private let zoneID = CKRecordZone.ID(
    zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

  init(
    modelContext: ModelContext,
    store: SyncEngineStore,
    emergencyManager: EmergencyUnblockManager,
    deviceId: String
  ) {
    self.modelContext = modelContext
    self.store = store
    self.emergencyManager = emergencyManager
    self.deviceId = deviceId
  }

  func record(forRecordName recordName: String) -> CKRecord? {
    if recordName == SyncedEstablishment.recordName {
      return establishmentRecord()
    }
    if recordName == SyncedEmergencySettings.recordName {
      return emergencyRecord()
    }
    if recordName == SyncedEmergencyEpoch.recordName {
      return emergencyEpochRecord()
    }
    if recordName.hasPrefix(SyncedEmergencyUnblockEvent.recordNamePrefix) {
      return emergencyUnblockEventRecord(recordName: recordName)
    }
    if recordName.hasPrefix("ProfileSession_") {
      // Session records are owned by SessionSyncService (CAS), never materialized here.
      return nil
    }
    guard let id = UUID(uuidString: recordName) else {
      return nil
    }
    if let profile = try? BlockedProfiles.findProfile(byID: id, in: modelContext) {
      return profileRecord(profile)
    }
    if let location = try? SavedLocation.find(byID: id, in: modelContext) {
      return locationRecord(location)
    }
    return nil
  }

  func restorableEmergencyRecordNames() -> [String] {
    [SyncedEmergencyEpoch.recordName] + emergencyManager.allUnblockEventRecordNames()
  }

  func establishmentRecord() -> CKRecord {
    let synced = SyncedEstablishment(
      generation: store.establishmentGeneration, establishedAt: Date())
    let record = materialize(
      recordName: SyncedEstablishment.recordName,
      recordType: SyncedEstablishment.recordType,
      freshRecordID: CKRecord.ID(recordName: SyncedEstablishment.recordName, zoneID: zoneID))
    synced.updateCKRecord(record)
    return record
  }

  private func profileRecord(_ profile: BlockedProfiles) -> CKRecord? {
    guard !profile.isNewerSchemaVersion else { return nil }
    let synced = SyncedProfile(
      from: profile, originDeviceId: deviceId, generation: store.establishmentGeneration)
    let record = materialize(
      recordName: profile.id.uuidString,
      recordType: SyncedProfile.recordType,
      freshRecordID: CKRecord.ID(recordName: profile.id.uuidString, zoneID: zoneID))
    synced.updateCKRecord(record)
    return record
  }

  private func locationRecord(_ location: SavedLocation) -> CKRecord? {
    let synced = SyncedLocation(from: location, generation: store.establishmentGeneration)
    let record = materialize(
      recordName: location.id.uuidString,
      recordType: SyncedLocation.recordType,
      freshRecordID: CKRecord.ID(recordName: location.id.uuidString, zoneID: zoneID))
    synced.updateCKRecord(record)
    return record
  }

  private func emergencyRecord() -> CKRecord? {
    let synced = emergencyManager.currentEmergencySettings(deviceId: deviceId)
    let record = materialize(
      recordName: SyncedEmergencySettings.recordName,
      recordType: SyncedEmergencySettings.recordType,
      freshRecordID: CKRecord.ID(recordName: SyncedEmergencySettings.recordName, zoneID: zoneID))
    synced.updateCKRecord(record)
    return record
  }

  private func emergencyEpochRecord() -> CKRecord? {
    let record = materialize(
      recordName: SyncedEmergencyEpoch.recordName,
      recordType: SyncedEmergencyEpoch.recordType,
      freshRecordID: CKRecord.ID(recordName: SyncedEmergencyEpoch.recordName, zoneID: zoneID))
    var epoch = emergencyManager.currentEpochRecord()
    epoch.generation = store.establishmentGeneration
    epoch.updateCKRecord(record)
    return record
  }

  private func emergencyUnblockEventRecord(recordName: String) -> CKRecord? {
    guard var event = emergencyManager.eventRecord(forRecordName: recordName) else { return nil }
    let record = materialize(
      recordName: recordName,
      recordType: SyncedEmergencyUnblockEvent.recordType,
      freshRecordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
    event.generation = store.establishmentGeneration
    event.updateCKRecord(record)
    return record
  }

  /// The CKRecord to write fields onto: decoded from cached system fields when present
  /// (change-tag-correct), else a fresh record (§5.4).
  private func materialize(
    recordName: String, recordType: String, freshRecordID: CKRecord.ID
  ) -> CKRecord {
    if let data = store.systemFields(for: recordName),
      let cached = CKRecordSystemFieldsCodec.decode(data)
    {
      return cached
    }
    return CKRecord(recordType: recordType, recordID: freshRecordID)
  }
}
