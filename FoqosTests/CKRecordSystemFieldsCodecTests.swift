import CloudKit
import XCTest

@testable import FamilyFoqos

final class CKRecordSystemFieldsCodecTests: XCTestCase {
  func testGivenRecord_WhenEncodedAndDecoded_ThenRecordIDAndZonePreserved() {
    let zone = CKRecordZone.ID(zoneName: "DeviceSync", ownerName: "sentinel-owner")
    let recordID = CKRecord.ID(recordName: "abc-123", zoneID: zone)
    let record = CKRecord(recordType: SyncedProfile.recordType, recordID: recordID)
    record[SyncedProfile.FieldKey.name.rawValue] = "should-not-round-trip"

    let data = CKRecordSystemFieldsCodec.encode(record)
    let decoded = CKRecordSystemFieldsCodec.decode(data)

    XCTAssertNotNil(decoded)
    XCTAssertEqual(decoded?.recordID.recordName, "abc-123")
    XCTAssertEqual(decoded?.recordID.zoneID.zoneName, "DeviceSync")
    XCTAssertEqual(decoded?.recordID.zoneID.ownerName, "sentinel-owner")
    XCTAssertEqual(decoded?.recordType, SyncedProfile.recordType)
    // Only system fields are captured — user fields are NOT part of the archive.
    XCTAssertNil(decoded?[SyncedProfile.FieldKey.name.rawValue])
  }

  func testGivenGarbageData_WhenDecoded_ThenNil() {
    XCTAssertNil(CKRecordSystemFieldsCodec.decode(Data([0x00, 0x01, 0x02])))
  }
}
