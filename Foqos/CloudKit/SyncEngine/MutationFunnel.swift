import CloudKit
import Foundation
import SwiftData

/// The single API for every locally-originated create/update/delete of a synced entity (I2).
/// Save path: bump the entity's version inside the same persisted write, then enqueue a
/// `.saveRecord`. Delete path (added in later tasks): persist a delete-intent tombstone before
/// the entity delete, roll it back on failure, then enqueue a `.deleteRecord`.
///
/// Runs on the sync paths' own `ModelContext` (design §2, round-6) so a rollback can never
/// discard unrelated uncommitted user edits.
@MainActor
final class MutationFunnel {

  enum MutationFunnelError: Error, Equatable {
    case entityNotFound
  }

  private let modelContext: ModelContext
  private let store: SyncEngineStore
  private let driver: SyncEngineDriver
  private let deviceId: String
  private let scheduleProfileDeleteCommit: (@escaping @MainActor () -> Void) -> Void
  /// Test seam: overrides the durable save so deferred-delete rollback is exercisable.
  var saveOverride: (() throws -> Void)?

  init(
    modelContext: ModelContext,
    store: SyncEngineStore,
    driver: SyncEngineDriver,
    deviceId: String,
    scheduleProfileDeleteCommit: @escaping (@escaping @MainActor () -> Void) -> Void =
      BlockedProfiles.scheduleProfileDeleteCommit
  ) {
    self.modelContext = modelContext
    self.store = store
    self.driver = driver
    self.deviceId = deviceId
    self.scheduleProfileDeleteCommit = scheduleProfileDeleteCommit
  }

  private var zoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
  }

  // MARK: - Save paths

  /// Re-read the profile on the sync context, bump `syncVersion` in the same persisted write,
  /// require the write to succeed, then enqueue exactly one `.saveRecord` (I2, §9).
  func enqueueSave(profileId: UUID) throws {
    guard let profile = try BlockedProfiles.findProfile(byID: profileId, in: modelContext) else {
      throw MutationFunnelError.entityNotFound
    }
    // Never enqueue newer-schema profiles (I2; the newer device is authoritative — §5.4).
    guard !profile.isNewerSchemaVersion else {
      SyncDiagnostics.localProfileSaveSkippedNewerSchema(profileId: profile.id)
      return
    }
    profile.syncVersion += 1
    profile.physicalKeys = profile.physicalKeys
    do {
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
    let recordID = CKRecord.ID(recordName: profileId.uuidString, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    SyncDiagnostics.localProfileSaveEnqueued(profileId: profileId, syncVersion: profile.syncVersion)
  }

  /// Re-read the location on the sync context, advance `updatedAt` in the same persisted write
  /// (locations merge by client clock — §5.1/N6), then enqueue one `.saveRecord`.
  func enqueueSave(locationId: UUID) throws {
    guard let location = try SavedLocation.find(byID: locationId, in: modelContext) else {
      throw MutationFunnelError.entityNotFound
    }
    location.updatedAt = Date()
    do {
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
    let recordID = CKRecord.ID(recordName: locationId.uuidString, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    SyncDiagnostics.localLocationSaveEnqueued(locationId: locationId)
  }

  /// Bump the emergency-settings version and enqueue the single fixed-name record (I2, §2).
  /// Not `throws`: nothing inside can fail (#9) — the facade layer above still throws for
  /// the "engine not attached" case (see `SyncEngineController+Cutover`).
  func enqueueEmergencySettingsSave() {
    EmergencyUnblockManager.shared.incrementEmergencySettingsVersionForSync()
    let recordID = CKRecord.ID(recordName: SyncedEmergencySettings.recordName, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    SyncDiagnostics.localEmergencySettingsSaveEnqueued(recordName: SyncedEmergencySettings.recordName)
  }

  /// Enqueue a write-once emergency-unblock event (I2, #221). The event is already persisted by
  /// `EmergencyUnblockManager.consumeUnblockEvent`; this only schedules its CKSyncEngine save.
  func enqueueEmergencyUnblockEvent(_ event: SyncedEmergencyUnblockEvent) {
    let recordID = CKRecord.ID(recordName: event.recordName, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    SyncDiagnostics.localEmergencyUnblockEventSaveEnqueued(recordName: event.recordName)
  }

  /// Enqueue the fixed-name reset-epoch record. There is no version bump: the epoch value itself
  /// is merged by monotonic max on apply.
  func enqueueEmergencyEpochSave() {
    let recordID = CKRecord.ID(recordName: SyncedEmergencyEpoch.recordName, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    SyncDiagnostics.localEmergencyEpochSaveEnqueued(recordName: SyncedEmergencyEpoch.recordName)
  }

  /// Enqueue the fixed-name establishment record. The generation value itself is merged by
  /// monotonic max on save conflict/fetch.
  func enqueueEstablishmentSave() {
    let recordID = CKRecord.ID(recordName: SyncedEstablishment.recordName, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
  }

  // MARK: - Delete paths

  /// Persist a delete-intent tombstone (recordName -> last-known server change tag, nil if never
  /// synced) BEFORE the entity delete; require the delete to succeed; then enqueue one
  /// `.deleteRecord` (I12, §2). On any failure, the tombstone is removed and the context rolled
  /// back before the error is rethrown — a lingering tombstone for an entity that was never
  /// actually deleted would later kill the live record family-wide (round-4/5).
  func enqueueDelete(
    profileId: UUID,
    onPendingDeleteEnqueued: @escaping @MainActor () -> Void = {}
  ) throws {
    let recordName = profileId.uuidString
    let changeTag = Self.changeTag(fromSystemFields: store.systemFields(for: recordName))
    store.setTombstone(recordName: recordName, changeTag: changeTag)
    do {
      guard let profile = try BlockedProfiles.findProfile(byID: profileId, in: modelContext) else {
        throw MutationFunnelError.entityNotFound
      }
      store.setDeleteWatermark(recordName: recordName, value: Double(profile.syncVersion))
      try BlockedProfiles.deleteProfile(profile, in: modelContext)
      let deleteZoneID = zoneID
      let saveOverride = saveOverride
      scheduleProfileDeleteCommit {
        [
          modelContext, store, driver, profileId, recordName, deleteZoneID, saveOverride,
          onPendingDeleteEnqueued,
        ] in
        do {
          // The caller has already returned; post-boundary failures are logged and converted
          // back into tombstone cleanup plus rollback, and the remote delete is enqueued only
          // after the save and target-absence check both succeed.
          if let saveOverride {
            try saveOverride()
          } else {
            try modelContext.save()
          }
          guard try BlockedProfiles.findProfile(byID: profileId, in: modelContext) == nil else {
            store.clearTombstone(recordName: recordName)
            store.clearDeleteWatermark(recordName: recordName)
            Log.error(
              "Deferred profile delete save completed but \(recordName) is still present",
              category: .sync
            )
            return
          }
          let recordID = CKRecord.ID(recordName: recordName, zoneID: deleteZoneID)
          driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
          SyncDiagnostics.localProfileDeleteEnqueued(profileId: profileId)
          onPendingDeleteEnqueued()
        } catch {
          store.clearTombstone(recordName: recordName)
          store.clearDeleteWatermark(recordName: recordName)
          modelContext.rollback()
          if let restored = try? BlockedProfiles.findProfile(byID: profileId, in: modelContext) {
            BlockedProfiles.updateSnapshot(for: restored)
          }
          Log.error(
            "Deferred profile delete save failed for \(recordName): \(error.localizedDescription)",
            category: .sync
          )
        }
      }
      return
    } catch {
      store.clearTombstone(recordName: recordName)
      store.clearDeleteWatermark(recordName: recordName)
      modelContext.rollback()
      throw error
    }
  }

  /// Persist a delete-intent tombstone before the location delete; `SavedLocation.delete(_:in:)`
  /// performs its own persisted write, so on failure only the tombstone needs undoing (I12, §2).
  func enqueueDelete(locationId: UUID) throws {
    let recordName = locationId.uuidString
    let changeTag = Self.changeTag(fromSystemFields: store.systemFields(for: recordName))
    store.setTombstone(recordName: recordName, changeTag: changeTag)
    let repaired: [UUID]
    do {
      guard let location = try SavedLocation.find(byID: locationId, in: modelContext) else {
        throw MutationFunnelError.entityNotFound
      }
      store.setDeleteWatermark(
        recordName: recordName,
        value: location.updatedAt.timeIntervalSinceReferenceDate
      )
      repaired = try BlockedProfiles.removeLocationReference(locationId, in: modelContext)
      try SavedLocation.delete(location, in: modelContext)
    } catch {
      store.clearTombstone(recordName: recordName)
      store.clearDeleteWatermark(recordName: recordName)
      modelContext.rollback()
      throw error
    }
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
    SyncDiagnostics.localLocationDeleteEnqueued(locationId: locationId, repairedProfileIds: repaired)
    for profileId in repaired {
      do {
        try enqueueSave(profileId: profileId)
      } catch {
        Log.warning(
          "Location-delete profile repair re-push failed for \(profileId.uuidString): "
            + error.localizedDescription,
          category: .sync)
      }
    }
  }

  /// Enqueue a delete for a record whose model is already gone locally (a delete that fell
  /// back to a local delete while unattached, #294). Writes the tombstone and `.deleteRecord`;
  /// there is no persisted delete because the row no longer exists.
  func enqueueTombstoneDelete(recordName: String) {
    let changeTag = Self.changeTag(fromSystemFields: store.systemFields(for: recordName))
    store.setTombstone(recordName: recordName, changeTag: changeTag)
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
    SyncDiagnostics.localTombstoneDeleteEnqueued(recordName: recordName)
  }

  /// Delete a write-once emergency-unblock event through the explicit delete path (#221 GC).
  /// The facade's not-attached fallback reuses `enqueueTombstoneDelete(recordName:)`, so deferred
  /// drains share the existing tombstone/delete replay semantics.
  func enqueueEmergencyUnblockEventDelete(_ recordName: String) {
    enqueueTombstoneDelete(recordName: recordName)
  }

  // MARK: - System-fields change tag

  /// Decode the last-known server change tag from cached CKRecord system fields.
  /// Returns nil when there are no cached fields (never synced) or the blob cannot decode.
  static func changeTag(fromSystemFields data: Data?) -> String? {
    guard let data else { return nil }
    return CKRecordSystemFieldsCodec.decode(data)?.recordChangeTag
  }
}

extension MutationFunnel.MutationFunnelError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .entityNotFound:
      return "The item may have already been removed. Please try again."
    }
  }
}
