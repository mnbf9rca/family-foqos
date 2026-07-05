import CloudKit
import Foundation

@testable import FamilyFoqos

@MainActor
final class MockResetOutbox: ResetOutbox {
  var zoneDeleteCount = 0
  var zoneSaveCount = 0
  var removeZoneCount = 0
  var commandSaveCount = 0
  var removeCommandCount = 0
  var sendCount = 0

  func enqueueZoneDelete() { zoneDeleteCount += 1 }
  func enqueueZoneSave() { zoneSaveCount += 1 }
  func removeResetZoneChanges() { removeZoneCount += 1 }
  func enqueueCommandSave() { commandSaveCount += 1 }
  func removeCommandSave() { removeCommandCount += 1 }
  func requestSend() { sendCount += 1 }
}

@MainActor
final class MockResetSeeder: ResetSeeder {
  var purgeCount = 0
  var seedCount = 0
  var clearSelectionsCount = 0
  var clearSelectionsError: Error?
  /// Invoked inside seedAll() so tests can assert intent→apply→mark ordering.
  var onSeed: (() -> Void)?

  func performI6Purge() async { purgeCount += 1 }
  func seedAll() {
    seedCount += 1
    onSeed?()
  }
  func clearAllProfileSelections() throws {
    clearSelectionsCount += 1
    if let error = clearSelectionsError { throw error }
  }
}

@MainActor
final class MockRecordFetcher: RecordFetching {
  var result: Result<CKRecord?, Error> = .success(nil)
  var fetchCount = 0
  var lastRecordID: CKRecord.ID?

  func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord? {
    fetchCount += 1
    lastRecordID = recordID
    switch result {
    case .success(let record): return record
    case .failure(let error): throw error
    }
  }
}

@MainActor
final class MockResetConflictSurfacer: ResetConflictSurfacing {
  var surfaceCount = 0
  func surfaceResetSuperseded() { surfaceCount += 1 }
}
