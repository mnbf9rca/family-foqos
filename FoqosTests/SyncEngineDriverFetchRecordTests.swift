import CloudKit
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineDriverFetchRecordTests: XCTestCase {
  private let zoneID = CKRecordZone.ID(
    zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

  func testGivenConfiguredResults_WhenFetchRecord_ThenReturnsResultAndRecordsID() async {
    let driver = MockSyncEngineDriver()
    let id = CKRecord.ID(recordName: "abc", zoneID: zoneID)
    let record = CKRecord(recordType: SyncedProfile.recordType, recordID: id)
    driver.fetchRecordResults["abc"] = .found(record, changeTag: "tag-m")
    driver.defaultFetchRecordResult = .notFound

    let hit = await driver.fetchRecord(id)
    let miss = await driver.fetchRecord(CKRecord.ID(recordName: "zzz", zoneID: zoneID))

    guard case .found(let got, let tag) = hit else { return XCTFail("expected .found") }
    XCTAssertEqual(got.recordID.recordName, "abc")
    XCTAssertEqual(tag, "tag-m")
    guard case .notFound = miss else { return XCTFail("expected .notFound") }
    XCTAssertEqual(driver.fetchedRecordIDs.map { $0.recordName }, ["abc", "zzz"])
  }
}
