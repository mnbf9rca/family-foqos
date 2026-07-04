import CloudKit
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineLegacyCleanupTests: XCTestCase {
  var testSuiteName: String!
  var store: SyncEngineStore!
  var driver: CutoverRecordingDriver!
  var coordinator: LegacyCleanupCoordinator!

  private var zoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
  }

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "SyncEngineLegacyCleanupTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: testSuiteName)!)
    store = SyncEngineStore(userRecordName: "user-A", defaults: UserDefaults(suiteName: testSuiteName)!)
    driver = CutoverRecordingDriver()
    coordinator = LegacyCleanupCoordinator(store: store, driver: driver)
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: testSuiteName)
    try await super.tearDown()
  }

  private func legacyRecord(_ name: String) -> CKRecord {
    CKRecord(
      recordType: LegacySyncedSession.recordType,
      recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
  }

  func testGivenLegacyRecordsFetched_WhenIdentified_ThenIdsPersistedDeletesEnqueuedAndFlagUnset() {
    let recs = [legacyRecord("sess-1"), legacyRecord("sess-2")]

    coordinator.identify(modifications: recs)

    XCTAssertEqual(store.legacyCleanupIds, ["sess-1", "sess-2"])
    XCTAssertEqual(Set(driver.enqueuedDeleteNames), ["sess-1", "sess-2"])
    XCTAssertFalse(store.legacyCleanupDone)
  }

  func testGivenFlagAlreadyDone_WhenIdentified_ThenNoOp() {
    store.legacyCleanupDone = true
    coordinator.identify(modifications: [legacyRecord("sess-9")])

    XCTAssertTrue(store.legacyCleanupIds.isEmpty)
    XCTAssertTrue(driver.enqueuedDeleteNames.isEmpty)
  }

  func testGivenNonLegacyRecords_WhenIdentified_ThenIgnored() {
    let profile = CKRecord(
      recordType: SyncedProfile.recordType,
      recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
    coordinator.identify(modifications: [profile])

    XCTAssertTrue(store.legacyCleanupIds.isEmpty)
    XCTAssertTrue(driver.enqueuedDeleteNames.isEmpty)
  }
}
