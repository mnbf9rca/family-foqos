import CloudKit
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncedProfileDecodeBoundsTests: XCTestCase {

  /// Builds a minimally-valid SyncedProfile CKRecord (all required fields present) so the
  /// decode initializer reaches the optional-field assignments.
  private func minimalProfileRecord(now: Date, reminder: Int?) -> CKRecord {
    let zoneID = CKRecordZone.ID(
      zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
    let record = CKRecord(
      recordType: SyncedProfile.recordType,
      recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
    record["profileId"] = UUID().uuidString
    record["name"] = "Focus"
    record["createdAt"] = now
    record["updatedAt"] = now
    record["lastModified"] = now
    record["originDeviceId"] = "device-A"
    record["version"] = 1
    if let reminder { record["reminderTimeInSeconds"] = reminder }
    return record
  }

  func testGivenNegativeReminder_WhenDecoding_ThenDegradesToNilWithoutTrapping() {
    let now = Date()
    let record = minimalProfileRecord(now: now, reminder: -1)
    let synced = SyncedProfile(from: record)
    XCTAssertNotNil(synced, "an out-of-range reminder must not fail the whole decode")
    XCTAssertNil(synced?.reminderTimeInSeconds, "negative reminder degrades to no-reminder")
  }

  func testGivenOverflowingReminder_WhenDecoding_ThenDegradesToNilWithoutTrapping() {
    let now = Date()
    let record = minimalProfileRecord(now: now, reminder: Int(UInt32.max) + 1)
    let synced = SyncedProfile(from: record)
    XCTAssertNotNil(synced)
    XCTAssertNil(synced?.reminderTimeInSeconds, "overflowing reminder degrades to no-reminder")
  }

  func testGivenInRangeReminder_WhenDecoding_ThenPreservesValue() {
    let now = Date()
    let record = minimalProfileRecord(now: now, reminder: 3600)
    let synced = SyncedProfile(from: record)
    XCTAssertEqual(synced?.reminderTimeInSeconds, 3600)
  }
}
