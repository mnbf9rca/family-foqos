import CloudKit

/// Reason a DeviceSync zone deletion was reported (mirror of
/// CKDatabase.DatabaseChange.Deletion.Reason). Drives T5 vs T6 (§8.4, §5).
enum SyncEngineZoneDeletionReason: Equatable {
  case deleted
  case purged
  case encryptedDataReset
}

/// Account-change kind (mirror of CKSyncEngine.Event.AccountChange.ChangeType,
/// dropping the user record ids the controller does not consume). Drives T7.
enum SyncEngineAccountChangeKind: Equatable {
  case signIn
  case signOut
  case switchAccounts
}

/// Domain mirror of the CKSyncEngine.Event cases the controller consumes.
/// CKRecord / CKError / CKRecord.ID are test-constructible; CKSyncEngine.Event/State
/// are not — this enum keeps them out of the unit tests (§1.1, §5).
enum SyncEngineEvent {
  case stateUpdate(serialization: Data)  // T10; persist for fetch tokens (AB-2)
  case accountChange(kind: SyncEngineAccountChangeKind)  // T7
  case fetchedDatabaseChanges(
    modifiedZoneIDs: [CKRecordZone.ID],
    deletedZones: [(zoneID: CKRecordZone.ID, reason: SyncEngineZoneDeletionReason)])  // T5/T6
  case fetchedRecordZoneChanges(
    modifications: [CKRecord],
    deletions: [(recordID: CKRecord.ID, recordType: CKRecord.RecordType)])  // T3 §5.1/§5.2
  case sentRecordZoneChanges(
    savedRecords: [CKRecord],
    failedRecordSaves: [(record: CKRecord, error: CKError)],
    deletedRecordIDs: [CKRecord.ID],
    failedRecordDeletes: [(recordID: CKRecord.ID, error: CKError)])  // T4 §5.3
  case sentDatabaseChanges(
    savedZones: [CKRecordZone.ID],
    failedZoneSaves: [(zone: CKRecordZone, error: CKError)],
    deletedZoneIDs: [CKRecordZone.ID],
    failedZoneDeletes: [(zoneID: CKRecordZone.ID, error: CKError)])  // T4b §5.5
  case willFetchChanges  // AB-3 cycle delimiter
  case didFetchChanges  // T2; AB-3; drives §5.6 sweep + echo-guard drain
}
