import CloudKit
import XCTest

@testable import FamilyFoqos

final class DeviceHeartbeatTests: XCTestCase {

  func testRecordName_isDeterministic() {
    let name = DeviceHeartbeat.recordName(
      childUserRecordName: "child123",
      deviceIdentifier: "device456"
    )
    XCTAssertEqual(name, "heartbeat-child123-device456")
  }

  func testToCKRecord_setsAllFields() {
    let heartbeat = DeviceHeartbeat(
      childUserRecordName: "child123",
      deviceIdentifier: "device456",
      deviceName: "Emma's iPhone",
      lastHeartbeatAt: Date(timeIntervalSince1970: 1_000_000),
      authorizationStatus: "approved"
    )

    let zoneID = CKRecordZone.ID(
      zoneName: "FamilyPolicies",
      ownerName: CKCurrentUserDefaultName
    )
    let record = heartbeat.toCKRecord(in: zoneID)

    XCTAssertEqual(record.recordType, "DeviceHeartbeat")
    XCTAssertEqual(record["childUserRecordName"] as? String, "child123")
    XCTAssertEqual(record["deviceIdentifier"] as? String, "device456")
    XCTAssertEqual(record["deviceName"] as? String, "Emma's iPhone")
    XCTAssertEqual(record["lastHeartbeatAt"] as? Date, Date(timeIntervalSince1970: 1_000_000))
    XCTAssertEqual(record["authorizationStatus"] as? String, "approved")
    XCTAssertNotNil(record.parent)
  }

  func testInitFromCKRecord_roundTrips() {
    let zoneID = CKRecordZone.ID(
      zoneName: "FamilyPolicies",
      ownerName: CKCurrentUserDefaultName
    )
    let original = DeviceHeartbeat(
      childUserRecordName: "child123",
      deviceIdentifier: "device456",
      deviceName: "Emma's iPhone",
      lastHeartbeatAt: Date(timeIntervalSince1970: 1_000_000),
      authorizationStatus: "denied"
    )
    let record = original.toCKRecord(in: zoneID)
    let decoded = DeviceHeartbeat(from: record)

    XCTAssertNotNil(decoded)
    XCTAssertEqual(decoded?.childUserRecordName, "child123")
    XCTAssertEqual(decoded?.deviceIdentifier, "device456")
    XCTAssertEqual(decoded?.deviceName, "Emma's iPhone")
    XCTAssertEqual(decoded?.lastHeartbeatAt, Date(timeIntervalSince1970: 1_000_000))
    XCTAssertEqual(decoded?.authorizationStatus, "denied")
  }

  func testInitFromCKRecord_returnsNilForMissingFields() {
    let zoneID = CKRecordZone.ID(
      zoneName: "FamilyPolicies",
      ownerName: CKCurrentUserDefaultName
    )
    let recordID = CKRecord.ID(recordName: "heartbeat-x-y", zoneID: zoneID)
    let record = CKRecord(recordType: "DeviceHeartbeat", recordID: recordID)
    // Missing all fields
    let decoded = DeviceHeartbeat(from: record)
    XCTAssertNil(decoded)
  }
}
