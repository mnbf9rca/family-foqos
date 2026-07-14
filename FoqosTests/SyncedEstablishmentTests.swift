import CloudKit
import XCTest

@testable import FamilyFoqos

final class SyncedEstablishmentTests: XCTestCase {
  private let zoneID = CKRecordZone.ID(
    zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

  func testGivenRecord_WhenRoundTripped_ThenGenerationAndDatePreserved() {
    let now = Date()
    let model = SyncedEstablishment(generation: 3, establishedAt: now)

    let record = model.toCKRecord(in: zoneID)
    let decoded = SyncedEstablishment(from: record)

    XCTAssertEqual(record.recordID.recordName, "sync-establishment")
    XCTAssertEqual(record.recordType, "SyncEstablishment")
    XCTAssertEqual(decoded?.generation, 3)
    XCTAssertEqual(
      decoded?.establishedAt.timeIntervalSinceReferenceDate ?? 0,
      now.timeIntervalSinceReferenceDate,
      accuracy: 0.001)
  }

  func testGivenRecordMissingGeneration_WhenDecoded_ThenNil() {
    let record = CKRecord(
      recordType: "SyncEstablishment",
      recordID: CKRecord.ID(recordName: "sync-establishment", zoneID: zoneID))

    XCTAssertNil(SyncedEstablishment(from: record))
  }
}
