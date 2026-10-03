import CloudKit
import FoqosShared
import XCTest

@testable import FamilyFoqos

final class ProfileSessionRecordTests: XCTestCase {

  func testGivenSameProfileId_WhenCreatingRecords_ThenRecordIdsMatch() {
    let profileId = UUID()

    let record1 = ProfileSessionRecord(profileId: profileId)
    let record2 = ProfileSessionRecord(profileId: profileId)

    // Same profile should produce same record ID
    XCTAssertEqual(record1.recordName, record2.recordName)
    XCTAssertEqual(record1.recordName, "ProfileSession_\(profileId.uuidString)")
  }

  func testGivenHigherSequence_WhenApplyingLowerSequence_ThenRejectsUpdate() {
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

  func testGivenActiveSession_WhenApplyingHigherSequence_ThenAcceptsUpdate() {
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

  func testGivenActiveSession_WhenApplyingEqualSequence_ThenRejectsUpdate() {
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

  func testGivenCompletedSession_WhenResettingForNewSession_ThenClearsAllFields() {
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

  func testGivenNewSession_WhenStarting_ThenSetsSessionOriginDevice() {
    var record = ProfileSessionRecord(profileId: UUID())

    _ = record.applyUpdate(isActive: true, sequenceNumber: 1, deviceId: "device-a", startTime: Date())

    XCTAssertEqual(record.sessionOriginDevice, "device-a")
  }

  func testGivenActiveSession_WhenUpdatingBreakTimes_ThenSetsBreakStartAndEnd() {
    var record = ProfileSessionRecord(profileId: UUID())
    let now = Date()
    let breakStart = now
    let breakEnd = now.addingTimeInterval(300)

    // Start session
    _ = record.applyUpdate(isActive: true, sequenceNumber: 1, deviceId: "a", startTime: now)

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
  func testTimerDeadlineWireRoundTripClearingAndReaderGuard() throws {
    let now = Date()
    var session = ProfileSessionRecord(profileId: UUID())
    session.applyUpdate(
      isActive: true, sequenceNumber: 1, deviceId: "A", startTime: now,
      timerEndTime: now.addingTimeInterval(900))
    let record = session.toCKRecord(in: CKRecordZone.ID(zoneName: "Test"))
    XCTAssertEqual(ProfileSessionRecord(from: record)?.validTimerEndTime, now.addingTimeInterval(900))
    let decoded = try JSONDecoder().decode(ProfileSessionRecord.self, from: JSONEncoder().encode(session))
    XCTAssertEqual(decoded.validTimerEndTime, session.validTimerEndTime)
    session.applyUpdate(isActive: true, sequenceNumber: 2, deviceId: "A", breakStartTime: now)
    XCTAssertEqual(session.validTimerEndTime, now.addingTimeInterval(900))
    session.applyUpdate(isActive: false, sequenceNumber: 3, deviceId: "A", endTime: now)
    session.updateCKRecord(record)
    XCTAssertNil(record["timerEndTime"])
    session.resetForNewSession()
    session.applyUpdate(isActive: true, sequenceNumber: 4, deviceId: "B", startTime: now)
    session.updateCKRecord(record)
    XCTAssertNil(record["timerEndTime"])
    for value in [now as NSDate, now.addingTimeInterval(-1) as NSDate, "bad" as NSString] as [CKRecordValue] {
      record["timerEndTime"] = value
      XCTAssertNil(ProfileSessionRecord(from: record)?.validTimerEndTime)
    }
    record["timerEndTime"] = now.addingTimeInterval(100)
    record["isActive"] = false
    XCTAssertNil(ProfileSessionRecord(from: record)?.validTimerEndTime)
    record["isActive"] = true
    record["startTime"] = nil
    XCTAssertNil(ProfileSessionRecord(from: record)?.validTimerEndTime)
  }

  func testCompletionUsesSubsecondStartToleranceAndOwnerOnlyForCountdown() {
    let now = Date()
    var session = ProfileSessionRecord(profileId: UUID())
    session.applyUpdate(isActive: true, sequenceNumber: 1, deviceId: "A", startTime: now)
    XCTAssertTrue(session.matchesCompletion(expectedStart: now, deviceId: "B"))
    XCTAssertFalse(session.matchesCompletion(expectedStart: now.addingTimeInterval(2), deviceId: "B"))
    session.resetForNewSession()
    session.applyUpdate(isActive: true, sequenceNumber: 2, deviceId: "A", startTime: now, timerEndTime: now.addingTimeInterval(900))
    XCTAssertTrue(session.matchesCompletion(expectedStart: now.addingTimeInterval(0.4), deviceId: "A"))
    XCTAssertFalse(session.matchesCompletion(expectedStart: now, deviceId: "B"))
    XCTAssertFalse(session.matchesCompletion(expectedStart: now.addingTimeInterval(2), deviceId: "A"))
  }

  func testIdentityDeadlineRoundTripAndReset() throws {
    let now = Date()
    let id = UUID().uuidString
    for origin in [SessionOrigin(kind: .nfc, key: "UID", namespace: .nfcUID), .init(kind: .qr, key: "digest", namespace: .qrDigest), .init(kind: .manual), .init(kind: .schedule), .init(kind: .link), .init(kind: .shortcut)] {
      var session = ProfileSessionRecord(profileId: UUID())
      session.applyUpdate(isActive: true, sequenceNumber: 1, deviceId: "owner", startTime: now, timerEndTime: now.addingTimeInterval(2207), sessionId: id, origin: origin)
      let wire = session.toCKRecord(in: CKRecordZone.ID(zoneName: "Test"))
      let decoded = try XCTUnwrap(ProfileSessionRecord(from: wire))
      XCTAssertEqual(decoded.sessionId, id)
      XCTAssertEqual(decoded.origin, origin)
      XCTAssertEqual(try JSONDecoder().decode(ProfileSessionRecord.self, from: JSONEncoder().encode(decoded)).origin, origin)
      XCTAssertEqual(decoded.validTimerEndTime, now.addingTimeInterval(2207))
      wire["sessionOrigin"] = "{\"kind\":\"unknown\"}"
      let malformed = try XCTUnwrap(ProfileSessionRecord(from: wire))
      XCTAssertTrue(malformed.isActive)
      XCTAssertNil(malformed.origin)
      XCTAssertNil(malformed.sessionId)
      session.applyUpdate(isActive: false, sequenceNumber: 2, deviceId: "mirror", endTime: now)
      XCTAssertEqual(session.sessionId, id)
      XCTAssertNil(session.origin)
      XCTAssertNil(session.timerEndTime)
      session.resetForNewSession()
      XCTAssertNil(session.sessionId)
      XCTAssertNil(session.origin)
    }
  }

  func testOlderWriterNewStartCannotReusePreviousCanonicalIdentityOrSameKey() throws {
    let now = Date()
    let oldId = UUID().uuidString
    var session = ProfileSessionRecord(profileId: UUID())
    session.applyUpdate(
      isActive: true, sequenceNumber: 10, deviceId: "new-build", startTime: now,
      sessionId: oldId, origin: .init(kind: .nfc, key: "OLD", namespace: .nfcUID))
    let record = session.toCKRecord(in: CKRecordZone.ID(zoneName: "Test"))
    // Old clients change known fields but leave new, unknown fields on the fetched CKRecord.
    record["startTime"] = now.addingTimeInterval(600)
    record["sequenceNumber"] = 12
    record["lastModifiedBy"] = "old-build"
    let newerStart = try XCTUnwrap(ProfileSessionRecord(from: record))

    XCTAssertTrue(newerStart.isActive)
    XCTAssertNil(newerStart.sessionId)
    XCTAssertNil(newerStart.origin)
    XCTAssertEqual(newerStart.startTime, now.addingTimeInterval(600))
    record["isActive"] = false
    XCTAssertNil(ProfileSessionRecord(from: record)?.sessionId)
  }

}
