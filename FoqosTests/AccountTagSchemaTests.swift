import CloudKit
import XCTest

@testable import FamilyFoqos

final class AccountTagSchemaTests: XCTestCase {
  func testCurrentProfileSchemaIsThree() {
    XCTAssertEqual(BlockedProfiles.currentSchemaVersion, 3)
  }

  func testVersionThreeDecodeIgnoresAllSixLegacyKeys() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Profile", createdAt: now, updatedAt: now)
    profile.profileSchemaVersion = 3
    let zone = CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName)
    let record = SyncedProfile(from: profile, originDeviceId: "test-device").toCKRecord(in: zone)
    for key in [
      "startNFCTagId", "startQRCodeId", "stopNFCTagId", "stopQRCodeId",
      "physicalUnblockNFCTagId", "physicalUnblockQRCodeId",
    ] {
      record[key] = "old-value"
    }
    let decoded = try XCTUnwrap(SyncedProfile(from: record))
    XCTAssertNil(decoded.startNFCTagId)
    XCTAssertNil(decoded.startQRCodeId)
    XCTAssertNil(decoded.stopNFCTagId)
    XCTAssertNil(decoded.stopQRCodeId)
    XCTAssertNil(decoded.physicalUnblockNFCTagId)
    XCTAssertNil(decoded.physicalUnblockQRCodeId)
  }
}
