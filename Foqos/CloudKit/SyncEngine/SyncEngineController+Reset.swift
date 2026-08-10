import CloudKit
import Foundation

/// Concrete ResetOutbox over the CKSyncEngine driver. Uses the fixed-name command record
/// and the DeviceSync zone. Wired to the controller's driver at cutover (Phase F).
@MainActor
final class DriverResetOutbox: ResetOutbox {
  private let driver: SyncEngineDriver
  private let zoneID: CKRecordZone.ID

  init(driver: SyncEngineDriver, zoneID: CKRecordZone.ID) {
    self.driver = driver
    self.zoneID = zoneID
  }

  private var commandRecordID: CKRecord.ID {
    CKRecord.ID(recordName: ResetController.commandRecordName, zoneID: zoneID)
  }
  private var establishmentRecordID: CKRecord.ID {
    CKRecord.ID(recordName: SyncedEstablishment.recordName, zoneID: zoneID)
  }

  func enqueueZoneDelete() {
    Log.info("Reset sync: enqueue zone delete", category: .sync)
    driver.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
  }
  func enqueueZoneSave() {
    Log.info("Reset sync: enqueue zone save", category: .sync)
    driver.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
  }
  func removeResetZoneChanges() {
    driver.remove(
      pendingDatabaseChanges: [.deleteZone(zoneID), .saveZone(CKRecordZone(zoneID: zoneID))])
  }
  func enqueueCommandSave() {
    Log.info("Reset sync: enqueue reset command", category: .sync)
    driver.add(pendingRecordZoneChanges: [.saveRecord(commandRecordID)])
  }
  func enqueueEstablishmentSave() {
    Log.info("Reset sync: enqueue establishment record", category: .sync)
    driver.add(pendingRecordZoneChanges: [.saveRecord(establishmentRecordID)])
  }
  func removeCommandSave() {
    driver.remove(pendingRecordZoneChanges: [.saveRecord(commandRecordID)])
  }
  func removeEstablishmentSave() {
    driver.remove(pendingRecordZoneChanges: [.saveRecord(establishmentRecordID)])
  }
  func requestSend() {
    // The outer Task only defers to a later main-actor turn; the §1.1/task-local CKSyncEngine
    // boundary is inside the driver, where sendChanges() crosses Task.detached before awaiting.
    Log.debug("Reset sync: request send", category: .sync)
    Task { @MainActor in self.driver.sendChanges() }
  }
  func clearPendingChangesForReset() {
    Log.info("Reset sync: clearing pending engine changes before zone reset", category: .sync)
    driver.remove(pendingRecordZoneChanges: driver.pendingRecordZoneChanges)
    driver.remove(pendingDatabaseChanges: driver.pendingDatabaseChanges)
  }
}

/// Direct record fetch by CKRecord.ID (I5-compatible). nil ⇒ unknownItem (absent).
@MainActor
final class DatabaseRecordFetcher: RecordFetching {
  private let database: CKDatabase

  init(database: CKDatabase) {
    self.database = database
  }

  func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord? {
    do {
      return try await database.record(for: recordID)
    } catch let error as CKError where error.code == .unknownItem {
      return nil
    }
  }
}

/// Direct record fetch by CKRecord.ID over the controller's `SyncEngineDriver` seam
/// (I5-compatible). The controller has no direct `CKDatabase` reference — the driver's
/// own `fetchRecord(_:)` is the fetch source — so this adapts `FetchRecordResult` to
/// `RecordFetching` rather than using `DatabaseRecordFetcher` above.
@MainActor
final class DriverRecordFetcher: RecordFetching {
  private let driver: SyncEngineDriver

  init(driver: SyncEngineDriver) {
    self.driver = driver
  }

  func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord? {
    switch await driver.fetchRecord(recordID) {
    case .found(let record, _):
      return record
    case .notFound:
      return nil
    case .zoneNotFound:
      throw CKError(.zoneNotFound)
    case .transientError(let error):
      throw error
    }
  }
}

/// Surfaces a "your reset did not run" conflict via the existing conflict manager.
@MainActor
final class ConflictManagerResetSurfacer: ResetConflictSurfacing {
  func surfaceResetSuperseded() {
    SyncConflictManager.shared.addResetSupersededConflict()
  }
}
