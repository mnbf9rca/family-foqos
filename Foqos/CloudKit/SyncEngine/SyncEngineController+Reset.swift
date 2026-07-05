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

  func enqueueZoneDelete() {
    driver.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
  }
  func enqueueZoneSave() {
    driver.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
  }
  func removeResetZoneChanges() {
    driver.remove(
      pendingDatabaseChanges: [.deleteZone(zoneID), .saveZone(CKRecordZone(zoneID: zoneID))])
  }
  func enqueueCommandSave() {
    driver.add(pendingRecordZoneChanges: [.saveRecord(commandRecordID)])
  }
  func removeCommandSave() {
    driver.remove(pendingRecordZoneChanges: [.saveRecord(commandRecordID)])
  }
  func requestSend() {
    // §1.1: schedule sendChanges() in a Task AFTER the current handler returns.
    Task { @MainActor in self.driver.sendChanges() }
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
