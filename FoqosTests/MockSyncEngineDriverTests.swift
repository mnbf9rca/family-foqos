import CloudKit
import XCTest

@testable import FamilyFoqos

@MainActor
private final class SpyDelegate: SyncEngineDriverDelegate {
  var received: [SyncEngineEvent] = []
  var batchScopes: [CKSyncEngine.SendChangesOptions.Scope?] = []
  var batchToReturn: [CKRecord]?
  func handle(_ event: SyncEngineEvent) { received.append(event) }
  func nextRecordZoneChangeBatch(
    scope: CKSyncEngine.SendChangesOptions.Scope?
  ) -> [CKRecord]? {
    batchScopes.append(scope)
    return batchToReturn
  }
}

@MainActor
final class MockSyncEngineDriverTests: XCTestCase {
  private func zoneID() -> CKRecordZone.ID {
    CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
  }

  func testGivenRecordChangeAddsAndRemoves_WhenApplied_ThenQueueAndLogReflectThem() {
    let driver = MockSyncEngineDriver()
    let id = CKRecord.ID(recordName: "p1", zoneID: zoneID())
    driver.add(pendingRecordZoneChanges: [.saveRecord(id)])
    XCTAssertEqual(driver.pendingRecordZoneChanges, [.saveRecord(id)])
    driver.remove(pendingRecordZoneChanges: [.saveRecord(id)])
    XCTAssertTrue(driver.pendingRecordZoneChanges.isEmpty)
    driver.add(pendingDatabaseChanges: [.deleteZone(zoneID())])
    XCTAssertEqual(driver.pendingDatabaseChanges.count, 1)

    XCTAssertEqual(driver.operations.count, 3)
    XCTAssertEqual(driver.operations[0], .addRecordChanges([.saveRecord(id)]))
    XCTAssertEqual(driver.operations[1], .removeRecordChanges([.saveRecord(id)]))
    guard case .addDatabaseChanges = driver.operations[2] else {
      return XCTFail("third op must be a database-change add")
    }
  }

  func testGivenFetchAndSend_WhenRequested_ThenCountsAndLogRecorded() {
    let driver = MockSyncEngineDriver()
    driver.fetchChanges()
    driver.sendChanges()
    driver.fetchChanges()
    XCTAssertEqual(driver.fetchChangesCount, 2)
    XCTAssertEqual(driver.sendChangesCount, 1)
    XCTAssertEqual(driver.operations, [.fetchChanges, .sendChanges, .fetchChanges])
  }

  func testGivenEvents_WhenDeliveredSerially_ThenDelegateReceivesInOrder() {
    let driver = MockSyncEngineDriver()
    let spy = SpyDelegate()
    driver.delegate = spy
    driver.deliverSerially([.willFetchChanges, .didFetchChanges])
    XCTAssertEqual(spy.received.count, 2)
    guard case .willFetchChanges = spy.received[0], case .didFetchChanges = spy.received[1]
    else { return XCTFail("events delivered out of order") }
  }

  func testGivenPullBatch_WhenRequested_ThenScopeForwardedAndRecordsReturned() {
    let driver = MockSyncEngineDriver()
    let spy = SpyDelegate()
    let rec = CKRecord(
      recordType: SyncedProfile.recordType,
      recordID: CKRecord.ID(recordName: "p1", zoneID: zoneID()))
    spy.batchToReturn = [rec]
    driver.delegate = spy
    let batch = driver.pullNextRecordZoneChangeBatch(scope: .zoneIDs([zoneID()]))
    XCTAssertEqual(batch?.first?.recordID, rec.recordID)
    XCTAssertEqual(spy.batchScopes.count, 1)
  }

  func testGivenRestoredPending_WhenInitialized_ThenExposedForStripAndNoAutoSend() {
    let id = CKRecord.ID(recordName: "p1", zoneID: zoneID())
    let driver = MockSyncEngineDriver(
      stateSerialization: Data([0x01]),
      pendingRecordZoneChanges: [.deleteRecord(id)],
      pendingDatabaseChanges: [.deleteZone(zoneID())])
    XCTAssertEqual(driver.stateSerialization, Data([0x01]))
    XCTAssertEqual(driver.pendingRecordZoneChanges, [.deleteRecord(id)])
    XCTAssertEqual(driver.pendingDatabaseChanges, [.deleteZone(zoneID())])
    XCTAssertEqual(driver.sendChangesCount, 0)  // AB-4: no send happens at init
    XCTAssertTrue(driver.operations.isEmpty)
  }

  func testGivenFetchCycle_WhenDelivered_ThenDelimitersWrapRecordEvents_S37() {
    let driver = MockSyncEngineDriver()
    let spy = SpyDelegate()
    driver.delegate = spy
    let rec = CKRecord(
      recordType: SyncedProfile.recordType,
      recordID: CKRecord.ID(recordName: "p1", zoneID: zoneID()))
    driver.deliverFetchCycle([.fetchedRecordZoneChanges(modifications: [rec], deletions: [])])
    XCTAssertEqual(spy.received.count, 3)
    guard case .willFetchChanges = spy.received[0] else { return XCTFail() }
    guard case .fetchedRecordZoneChanges = spy.received[1] else { return XCTFail() }
    guard case .didFetchChanges = spy.received[2] else { return XCTFail() }
  }

  func testGivenDatabaseThenRecordSends_WhenEnqueued_ThenOrderObservableInLog_S25() {
    let driver = MockSyncEngineDriver()
    let id = CKRecord.ID(recordName: "p1", zoneID: zoneID())
    driver.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneName: CloudKitConstants.syncZoneName))])
    driver.add(pendingRecordZoneChanges: [.saveRecord(id)])
    driver.sendChanges()
    let dbIndex = driver.operations.firstIndex {
      if case .addDatabaseChanges = $0 { return true }
      return false
    }
    let recIndex = driver.operations.firstIndex {
      if case .addRecordChanges = $0 { return true }
      return false
    }
    XCTAssertNotNil(dbIndex)
    XCTAssertNotNil(recIndex)
    XCTAssertLessThan(dbIndex!, recIndex!)  // AB-1: database changes precede record changes
  }

  func testGivenStateUpdateBetweenTwoFetchEvents_WhenDeliveredSerially_ThenObservedInOrder_S26() {
    let driver = MockSyncEngineDriver()
    let spy = SpyDelegate()
    driver.delegate = spy
    let rec1 = CKRecord(
      recordType: SyncedProfile.recordType,
      recordID: CKRecord.ID(recordName: "p1", zoneID: zoneID()))
    let rec2 = CKRecord(
      recordType: SyncedProfile.recordType,
      recordID: CKRecord.ID(recordName: "p2", zoneID: zoneID()))
    driver.deliverSerially([
      .fetchedRecordZoneChanges(modifications: [rec1], deletions: []),
      .stateUpdate(serialization: Data([0x09])),
      .fetchedRecordZoneChanges(modifications: [rec2], deletions: []),
    ])
    XCTAssertEqual(spy.received.count, 3)
    guard case .stateUpdate = spy.received[1] else {
      return XCTFail("stateUpdate must interleave between the two fetch events")
    }
  }

  func testGivenRestoredPendingDeletes_WhenInitialized_ThenAvailableBeforeAnySend_S38() {
    let id = CKRecord.ID(recordName: "p1", zoneID: zoneID())
    let driver = MockSyncEngineDriver(
      stateSerialization: Data([0xFF]),
      pendingRecordZoneChanges: [.deleteRecord(id)],
      pendingDatabaseChanges: [.deleteZone(zoneID())])
    // The strip inspects restored pending changes with no send having occurred (AB-4).
    XCTAssertEqual(driver.sendChangesCount, 0)
    XCTAssertEqual(driver.pendingRecordZoneChanges, [.deleteRecord(id)])
    // Strip removes them; the mock records the removals, still without a send.
    driver.remove(pendingRecordZoneChanges: [.deleteRecord(id)])
    driver.remove(pendingDatabaseChanges: [.deleteZone(zoneID())])
    XCTAssertTrue(driver.pendingRecordZoneChanges.isEmpty)
    XCTAssertTrue(driver.pendingDatabaseChanges.isEmpty)
    XCTAssertEqual(driver.sendChangesCount, 0)
  }
}
