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

  init(
    modelContext: ModelContext,
    store: SyncEngineStore,
    driver: SyncEngineDriver,
    deviceId: String
  ) {
    self.modelContext = modelContext
    self.store = store
    self.driver = driver
    self.deviceId = deviceId
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
      Log.info(
        "MutationFunnel skipping save for newer-schema profile '\(profile.name)'",
        category: .sync
      )
      return
    }
    profile.syncVersion += 1
    do {
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
    let recordID = CKRecord.ID(recordName: profileId.uuidString, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
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
  }

  /// Bump the emergency-settings version and enqueue the single fixed-name record (I2, §2).
  /// Not `throws`: nothing inside can fail (#9) — the facade layer above still throws for
  /// the "engine not attached" case (see `SyncEngineController+Cutover`).
  func enqueueEmergencySettingsSave() {
    EmergencyUnblockManager.shared.incrementEmergencySettingsVersionForSync()
    let recordID = CKRecord.ID(recordName: SyncedEmergencySettings.recordName, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
  }

  // MARK: - Delete paths

  /// Persist a delete-intent tombstone (recordName -> last-known server change tag, nil if never
  /// synced) BEFORE the entity delete; require the delete to succeed; then enqueue one
  /// `.deleteRecord` (I12, §2). On any failure, the tombstone is removed and the context rolled
  /// back before the error is rethrown — a lingering tombstone for an entity that was never
  /// actually deleted would later kill the live record family-wide (round-4/5).
  func enqueueDelete(profileId: UUID) throws {
    let recordName = profileId.uuidString
    let changeTag = Self.changeTag(fromSystemFields: store.systemFields(for: recordName))
    store.setTombstone(recordName: recordName, changeTag: changeTag)
    do {
      guard let profile = try BlockedProfiles.findProfile(byID: profileId, in: modelContext) else {
        throw MutationFunnelError.entityNotFound
      }
      Log.debug("[#285 PROBE] Funnel profile delete begin recordName=\(recordName)", category: .sync)
      try BlockedProfiles.deleteProfile(profile, in: modelContext)
      Log.debug(
        "[#285 PROBE] Funnel profile delete marked; scheduling deferred save recordName=\(recordName)",
        category: .sync
      )
      let deleteZoneID = zoneID
      Task { @MainActor [modelContext, store, driver, recordName, deleteZoneID] in
        try? await Task.sleep(for: .milliseconds(50))
        do {
          Log.debug("[#285 PROBE] Funnel deferred save begin recordName=\(recordName)", category: .sync)
          try modelContext.save()
          let recordID = CKRecord.ID(recordName: recordName, zoneID: deleteZoneID)
          driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
          Log.debug(
            "[#285 PROBE] Funnel deferred save + enqueue complete recordName=\(recordName)",
            category: .sync
          )
        } catch {
          store.clearTombstone(recordName: recordName)
          modelContext.rollback()
          Log.error(
            "[#285 PROBE] Funnel deferred save failed recordName=\(recordName): \(error.localizedDescription)",
            category: .sync
          )
        }
      }
      return
    } catch {
      store.clearTombstone(recordName: recordName)
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
    do {
      guard let location = try SavedLocation.find(byID: locationId, in: modelContext) else {
        throw MutationFunnelError.entityNotFound
      }
      try SavedLocation.delete(location, in: modelContext)
    } catch {
      store.clearTombstone(recordName: recordName)
      modelContext.rollback()
      throw error
    }
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
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
