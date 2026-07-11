import CloudKit
import FoqosShared
import Foundation
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineStoreTombstoneTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "SyncEngineStoreTombstoneTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: UserDefaults(suiteName: "\(suiteName!)-shared")!)
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: suiteName)
    UserDefaults().removePersistentDomain(forName: "\(suiteName!)-shared")
    try await super.tearDown()
  }

  private func encodedSystemFields(recordName: String) -> Data {
    let record = CKRecord(
      recordType: SyncedProfile.recordType,
      recordID: CKRecord.ID(
        recordName: recordName,
        zoneID: CKRecordZone.ID(
          zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)))
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archiver)
    archiver.finishEncoding()
    return archiver.encodedData
  }

  func testGivenCachedSystemFields_WhenDisabledTombstoneWritten_ThenTagMatchesDecoder() {
    let store = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    let systemFields = encodedSystemFields(recordName: "p1")
    store.setSystemFields(systemFields, for: "p1")

    let expectedTag = MutationFunnel.changeTag(fromSystemFields: store.systemFields(for: "p1"))
    store.setTombstone(recordName: "p1", changeTag: expectedTag)

    let reloaded = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    XCTAssertTrue(reloaded.deleteTombstones.keys.contains("p1"))
    XCTAssertEqual(reloaded.deleteTombstones["p1"] ?? nil, expectedTag)
  }

  func testGivenNeverSyncedRecord_WhenDisabledTombstoneWritten_ThenNilTagKeyPresent() {
    let store = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    store.setTombstone(
      recordName: "p2",
      changeTag: MutationFunnel.changeTag(fromSystemFields: store.systemFields(for: "p2")))

    let map = SyncEngineStore(userRecordName: "userA", defaults: defaults).deleteTombstones
    XCTAssertTrue(map.keys.contains("p2"))
    XCTAssertNil(map["p2"] ?? nil)
  }

  func testGivenTombstones_WhenSetWithNilAndNonNilTags_ThenRoundTripAndClear() {
    let store = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    store.setTombstone(recordName: "p1", changeTag: "tagX")
    store.setTombstone(recordName: "p2", changeTag: nil)  // never synced

    let reloaded = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    let map = reloaded.deleteTombstones
    XCTAssertEqual(map.count, 2)
    XCTAssertEqual(map["p1"] ?? nil, "tagX")
    XCTAssertTrue(map.keys.contains("p2"))  // key present...
    XCTAssertNil(map["p2"] ?? nil)  // ...with a nil change tag

    reloaded.clearTombstone(recordName: "p1")
    let after = SyncEngineStore(userRecordName: "userA", defaults: defaults).deleteTombstones
    XCTAssertFalse(after.keys.contains("p1"))
    XCTAssertTrue(after.keys.contains("p2"))
  }

  func testGivenFailedApplies_WhenAddedAndSupersededByName_ThenClearedByName() {
    let store = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    let upsert = FailedApply(recordName: "p1", recordType: SyncedProfile.recordType, op: .upsert)
    let del = FailedApply(recordName: "p2", recordType: SyncedProfile.recordType, op: .delete)
    store.addFailedApply(upsert)
    store.addFailedApply(del)
    store.addFailedApply(upsert)  // Set dedupes
    XCTAssertEqual(store.failedApplies.count, 2)

    store.removeFailedApply(recordName: "p1")  // supersession clears by name
    let reloaded = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    XCTAssertEqual(reloaded.failedApplies, [del])
  }

  func testGivenLegacyCleanup_WhenIdsTrackedAndFlagSet_ThenReusePreExistingKey() {
    let store = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    XCTAssertFalse(store.legacyCleanupDone)
    store.addLegacyCleanupIds(["s1", "s2"])
    store.removeLegacyCleanupId("s1")
    XCTAssertEqual(store.legacyCleanupIds, ["s2"])

    store.legacyCleanupDone = true
    // Must reuse the pre-existing per-user key (do not orphan it).
    XCTAssertTrue(
      defaults.bool(forKey: "family_foqos_legacy_session_cleanup_complete_userA"))
    XCTAssertTrue(
      SyncEngineStore(userRecordName: "userA", defaults: defaults).legacyCleanupDone)
  }

  func testGivenTransaction_WhenCompoundWriteUnderSingleLock_ThenAllPersistNoReentrancyDeadlock() {
    let store = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    let cmdId = UUID()
    store.transaction { s in
      s.resetIntent = ResetIntent(id: UUID(), clear: false, stage: .deleting, priorCommandId: nil)
      s.pendingSeedIntent = true
      s.setTombstone(recordName: "p9", changeTag: "t9")  // nested mutator must not re-lock
      s.markProcessed(cmdId)
    }
    let reloaded = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    XCTAssertNotNil(reloaded.resetIntent)
    XCTAssertTrue(reloaded.pendingSeedIntent)
    XCTAssertEqual(reloaded.deleteTombstones["p9"] ?? nil, "t9")
    XCTAssertEqual(reloaded.processedResetCommandIds, [cmdId])
  }

  func testGivenTwoUsers_WhenTombstonesAndLegacySet_ThenIsolated() {
    let a = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    let b = SyncEngineStore(userRecordName: "userB", defaults: defaults)
    a.setTombstone(recordName: "p1", changeTag: "t")
    a.legacyCleanupDone = true
    XCTAssertTrue(b.deleteTombstones.isEmpty)
    XCTAssertFalse(b.legacyCleanupDone)
  }
}
