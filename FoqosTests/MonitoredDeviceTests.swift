import XCTest

@testable import FamilyFoqos

final class MonitoredDeviceTests: XCTestCase {

  func testId_isCompositeKey() {
    let device = MonitoredDevice(
      deviceIdentifier: "dev1",
      deviceName: "iPhone",
      childUserRecordName: "child1",
      lastSeenAt: Date(),
      isSuppressed: false,
      notificationIdentifier: nil
    )
    XCTAssertEqual(device.id, "child1|dev1")
  }

  func testId_distinguishesSameDeviceDifferentChildren() {
    let device1 = MonitoredDevice(
      deviceIdentifier: "sharedIPad",
      deviceName: "iPad",
      childUserRecordName: "child1",
      lastSeenAt: Date(),
      isSuppressed: false,
      notificationIdentifier: nil
    )
    let device2 = MonitoredDevice(
      deviceIdentifier: "sharedIPad",
      deviceName: "iPad",
      childUserRecordName: "child2",
      lastSeenAt: Date(),
      isSuppressed: false,
      notificationIdentifier: nil
    )
    XCTAssertNotEqual(device1.id, device2.id)
  }

  func testIsStale_returnsTrueWhenOlderThan24Hours() {
    let now = Date()
    let device = MonitoredDevice(
      deviceIdentifier: "dev1",
      deviceName: "iPhone",
      childUserRecordName: "child1",
      lastSeenAt: now.addingTimeInterval(-25 * 3600),
      isSuppressed: false,
      notificationIdentifier: nil
    )
    XCTAssertTrue(device.isStale(now: now))
  }

  func testIsStale_returnsFalseWhenWithin24Hours() {
    let now = Date()
    let device = MonitoredDevice(
      deviceIdentifier: "dev1",
      deviceName: "iPhone",
      childUserRecordName: "child1",
      lastSeenAt: now.addingTimeInterval(-23 * 3600),
      isSuppressed: false,
      notificationIdentifier: nil
    )
    XCTAssertFalse(device.isStale(now: now))
  }

  func testIsStale_exactlyAt24Hours_returnsTrue() {
    let now = Date()
    let device = MonitoredDevice(
      deviceIdentifier: "dev1",
      deviceName: "iPhone",
      childUserRecordName: "child1",
      lastSeenAt: now.addingTimeInterval(-24 * 3600),
      isSuppressed: false,
      notificationIdentifier: nil
    )
    XCTAssertTrue(device.isStale(now: now))
  }

  func testShouldAlert_falseWhenSuppressed() {
    let now = Date()
    let device = MonitoredDevice(
      deviceIdentifier: "dev1",
      deviceName: "iPhone",
      childUserRecordName: "child1",
      lastSeenAt: now.addingTimeInterval(-25 * 3600),
      isSuppressed: true,
      notificationIdentifier: nil
    )
    XCTAssertFalse(device.shouldAlert(now: now))
  }

  func testShouldAlert_trueWhenStaleAndNotSuppressed() {
    let now = Date()
    let device = MonitoredDevice(
      deviceIdentifier: "dev1",
      deviceName: "iPhone",
      childUserRecordName: "child1",
      lastSeenAt: now.addingTimeInterval(-25 * 3600),
      isSuppressed: false,
      notificationIdentifier: nil
    )
    XCTAssertTrue(device.shouldAlert(now: now))
  }

  func testShouldAlert_trueWhenAuthRevokedEvenIfNotStale() {
    let now = Date()
    let device = MonitoredDevice(
      deviceIdentifier: "dev1",
      deviceName: "iPhone",
      childUserRecordName: "child1",
      lastSeenAt: now.addingTimeInterval(-1 * 3600),  // 1 hour ago, not stale
      isSuppressed: false,
      notificationIdentifier: nil,
      authorizationStatus: "denied"
    )
    XCTAssertTrue(device.shouldAlert(now: now))
    XCTAssertTrue(device.isAuthRevoked)
  }

  func testShouldAlert_falseWhenAuthRevokedButSuppressed() {
    let now = Date()
    let device = MonitoredDevice(
      deviceIdentifier: "dev1",
      deviceName: "iPhone",
      childUserRecordName: "child1",
      lastSeenAt: now.addingTimeInterval(-1 * 3600),
      isSuppressed: true,
      notificationIdentifier: nil,
      authorizationStatus: "denied"
    )
    XCTAssertFalse(device.shouldAlert(now: now))
  }

  func testIsAuthRevoked_falseForApproved() {
    let device = MonitoredDevice(
      deviceIdentifier: "dev1",
      deviceName: "iPhone",
      childUserRecordName: "child1",
      lastSeenAt: Date(),
      isSuppressed: false,
      notificationIdentifier: nil,
      authorizationStatus: "approved"
    )
    XCTAssertFalse(device.isAuthRevoked)
  }

  func testPersistence_roundTrips() throws {
    let device = MonitoredDevice(
      deviceIdentifier: "dev1",
      deviceName: "iPhone",
      childUserRecordName: "child1",
      lastSeenAt: Date(timeIntervalSince1970: 1_000_000),
      isSuppressed: true,
      notificationIdentifier: "notif-123",
      authorizationStatus: "approved"
    )
    let data = try JSONEncoder().encode(device)
    let decoded = try JSONDecoder().decode(MonitoredDevice.self, from: data)

    XCTAssertEqual(decoded.deviceIdentifier, "dev1")
    XCTAssertEqual(decoded.isSuppressed, true)
    XCTAssertEqual(decoded.notificationIdentifier, "notif-123")
    XCTAssertEqual(decoded.authorizationStatus, "approved")
  }

  func testPersistence_backwardsCompatible_missingAuthStatus() throws {
    // Simulate a device saved before authorizationStatus was added
    let json = """
      {"deviceIdentifier":"dev1","deviceName":"iPhone","childUserRecordName":"child1",
       "lastSeenAt":1000000,"isSuppressed":false}
      """
    let data = json.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(MonitoredDevice.self, from: data)

    XCTAssertNil(decoded.authorizationStatus)
    XCTAssertFalse(decoded.isAuthRevoked)
  }

  func testShouldScheduleAuthRevokedAlert_trueWhenRevokedAndNeverNotified() {
    let now = Date()
    let device = MonitoredDevice(
      deviceIdentifier: "dev1",
      deviceName: "iPhone",
      childUserRecordName: "child1",
      lastSeenAt: now,
      isSuppressed: false,
      notificationIdentifier: nil,
      authorizationStatus: "denied",
      authRevokedNotifiedAt: nil
    )
    XCTAssertTrue(device.shouldScheduleAuthRevokedAlert())
  }

  func testShouldScheduleAuthRevokedAlert_falseWhenAlreadyNotified() {
    let now = Date()
    let device = MonitoredDevice(
      deviceIdentifier: "dev1",
      deviceName: "iPhone",
      childUserRecordName: "child1",
      lastSeenAt: now,
      isSuppressed: false,
      notificationIdentifier: nil,
      authorizationStatus: "denied",
      authRevokedNotifiedAt: now
    )
    XCTAssertFalse(device.shouldScheduleAuthRevokedAlert())
  }

  func testShouldScheduleAuthRevokedAlert_falseWhenApproved() {
    let now = Date()
    let device = MonitoredDevice(
      deviceIdentifier: "dev1",
      deviceName: "iPhone",
      childUserRecordName: "child1",
      lastSeenAt: now,
      isSuppressed: false,
      notificationIdentifier: nil,
      authorizationStatus: "approved",
      authRevokedNotifiedAt: nil
    )
    XCTAssertFalse(device.shouldScheduleAuthRevokedAlert())
  }

  func testCarriedAuthRevokedNotifiedAt_preservesMarkerWhileStillDenied() {
    let now = Date()
    let carried = MonitoredDevice.carriedAuthRevokedNotifiedAt(previous: now, newStatus: "denied")
    XCTAssertEqual(carried, now)
  }

  func testCarriedAuthRevokedNotifiedAt_clearsMarkerWhenBackToApproved() {
    let now = Date()
    let carried = MonitoredDevice.carriedAuthRevokedNotifiedAt(previous: now, newStatus: "approved")
    XCTAssertNil(carried, "Re-arm so a genuine re-revocation alerts again")
  }

  func testCarriedAuthRevokedNotifiedAt_clearsMarkerWhenStatusNil() {
    let now = Date()
    XCTAssertNil(MonitoredDevice.carriedAuthRevokedNotifiedAt(previous: now, newStatus: nil))
  }

  func testPersistence_backwardsCompatible_missingAuthRevokedNotifiedAt() throws {
    // A device saved before authRevokedNotifiedAt existed must decode with the field nil.
    let json = """
      {"deviceIdentifier":"dev1","deviceName":"iPhone","childUserRecordName":"child1",
       "lastSeenAt":1000000,"isSuppressed":false,"authorizationStatus":"denied"}
      """
    let data = json.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(MonitoredDevice.self, from: data)

    XCTAssertNil(decoded.authRevokedNotifiedAt)
    XCTAssertTrue(decoded.shouldScheduleAuthRevokedAlert(), "Legacy denied device alerts once")
  }
}
