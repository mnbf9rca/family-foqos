import XCTest

@testable import FamilyFoqos

final class MonitoredDeviceTests: XCTestCase {

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
}
