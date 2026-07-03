import CloudKit

/// §11 legacy-cleanup one-shot. Identifies `LegacySyncedSession` ("SyncedSession")
/// records from any fetch cycle while `legacyCleanupDone` is unset, persists their ids
/// as the exemption carrier (`legacyCleanupIds`), and enqueues their deletes. This is
/// the one enumerated exception to I1's corollary / I2's whitelist, scoped to
/// `recordType == LegacySyncedSession` (design §11). Records are never applied locally.
@MainActor
final class LegacyCleanupCoordinator {
  private let store: SyncEngineStore
  private unowned let driver: SyncEngineDriver

  private var zoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
  }

  init(store: SyncEngineStore, driver: SyncEngineDriver) {
    self.store = store
    self.driver = driver
  }

  /// §5.1 legacy arm. Persist first, then enqueue (crash-durable carrier).
  func identify(modifications: [CKRecord]) {
    guard !store.legacyCleanupDone else { return }
    let ids = Set(
      modifications
        .filter { $0.recordType == LegacySyncedSession.recordType }
        .map { $0.recordID.recordName })
    guard !ids.isEmpty else { return }
    store.addLegacyCleanupIds(ids)
    enqueueDeletes(for: ids)
  }

  /// T1: re-enqueue any persisted ids after the strip while the flag is unset (§11).
  func reenqueuePending() {
    guard !store.legacyCleanupDone else { return }
    let ids = store.legacyCleanupIds
    guard !ids.isEmpty else { return }
    enqueueDeletes(for: ids)
  }

  /// §5.3 confirmation (deletedRecordIDs / U-delete / surfaced branch-F).
  /// Sets the done flag ONLY when the set empties (§11).
  func confirmDeleted(recordNames: [String]) {
    guard !store.legacyCleanupDone else { return }
    for name in recordNames { store.removeLegacyCleanupId(name) }
    if store.legacyCleanupIds.isEmpty {
      store.legacyCleanupDone = true
    }
  }

  /// Membership predicate for the T1-strip and §5.4 exemptions.
  func isExempt(recordName: String) -> Bool {
    store.legacyCleanupIds.contains(recordName)
  }

  private func enqueueDeletes(for ids: Set<String>) {
    let changes = ids.map {
      CKSyncEngine.PendingRecordZoneChange.deleteRecord(
        CKRecord.ID(recordName: $0, zoneID: zoneID))
    }
    driver.add(pendingRecordZoneChanges: changes)
  }
}
