import XCTest

@testable import foqos

final class ProfileSessionRecordTests: XCTestCase {

  func testRecordIdIsDeterministicPerProfile() {
    let profileId = UUID()

    let record1 = ProfileSessionRecord(profileId: profileId)
    let record2 = ProfileSessionRecord(profileId: profileId)

    // Same profile should produce same record ID
    XCTAssertEqual(record1.recordName, record2.recordName)
    XCTAssertEqual(record1.recordName, "ProfileSession_\(profileId.uuidString)")
  }

  func testApplyUpdateRejectsLowerSequence() {
    var record = ProfileSessionRecord(profileId: UUID())

    // Apply start with seq=3
    let applied1 = record.applyUpdate(
      isActive: true,
      sequenceNumber: 3,
      deviceId: "device-a",
      startTime: Date()
    )
    XCTAssertTrue(applied1)
    XCTAssertTrue(record.isActive)

    // Try to apply stop with seq=2 (stale)
    let applied2 = record.applyUpdate(
      isActive: false,
      sequenceNumber: 2,
      deviceId: "device-b",
      endTime: Date()
    )
    XCTAssertFalse(applied2)
    XCTAssertTrue(record.isActive)  // Still active
  }

  func testApplyUpdateAcceptsHigherSequence() {
    var record = ProfileSessionRecord(profileId: UUID())

    // Start
    _ = record.applyUpdate(isActive: true, sequenceNumber: 1, deviceId: "a", startTime: Date())

    // Stop with higher sequence
    let applied = record.applyUpdate(
      isActive: false,
      sequenceNumber: 2,
      deviceId: "b",
      endTime: Date()
    )
    XCTAssertTrue(applied)
    XCTAssertFalse(record.isActive)
  }

  func testApplyUpdateRejectsEqualSequence() {
    var record = ProfileSessionRecord(profileId: UUID())

    // Apply start with seq=1
    _ = record.applyUpdate(isActive: true, sequenceNumber: 1, deviceId: "a", startTime: Date())

    // Try to apply another update with seq=1 (same sequence)
    let applied = record.applyUpdate(
      isActive: false,
      sequenceNumber: 1,
      deviceId: "b",
      endTime: Date()
    )
    XCTAssertFalse(applied)
    XCTAssertTrue(record.isActive)  // Still active
  }

  func testResetForNewSession() {
    var record = ProfileSessionRecord(profileId: UUID())

    // Start and then stop a session
    _ = record.applyUpdate(isActive: true, sequenceNumber: 1, deviceId: "a", startTime: Date())
    _ = record.applyUpdate(isActive: false, sequenceNumber: 2, deviceId: "a", endTime: Date())

    XCTAssertNotNil(record.endTime)

    // Reset for new session
    record.resetForNewSession()

    XCTAssertNil(record.startTime)
    XCTAssertNil(record.endTime)
    XCTAssertNil(record.breakStartTime)
    XCTAssertNil(record.breakEndTime)
    XCTAssertNil(record.sessionOriginDevice)
  }

  func testSessionOriginDeviceIsSetOnStart() {
    var record = ProfileSessionRecord(profileId: UUID())

    _ = record.applyUpdate(isActive: true, sequenceNumber: 1, deviceId: "device-a", startTime: Date())

    XCTAssertEqual(record.sessionOriginDevice, "device-a")
  }

  func testBreakTimesAreUpdated() {
    var record = ProfileSessionRecord(profileId: UUID())
    let breakStart = Date()
    let breakEnd = Date().addingTimeInterval(300)

    // Start session
    _ = record.applyUpdate(isActive: true, sequenceNumber: 1, deviceId: "a", startTime: Date())

    // Update with break times
    _ = record.applyUpdate(
      isActive: true,
      sequenceNumber: 2,
      deviceId: "a",
      breakStartTime: breakStart,
      breakEndTime: breakEnd
    )

    XCTAssertEqual(record.breakStartTime, breakStart)
    XCTAssertEqual(record.breakEndTime, breakEnd)
  }
}
