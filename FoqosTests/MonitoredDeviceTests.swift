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

  func testPersistence_roundTrips() throws {
    let device = MonitoredDevice(
      deviceIdentifier: "dev1",
      deviceName: "iPhone",
      childUserRecordName: "child1",
      lastSeenAt: Date(timeIntervalSince1970: 1_000_000),
      isSuppressed: true,
      notificationIdentifier: "notif-123"
    )
    let data = try JSONEncoder().encode(device)
    let decoded = try JSONDecoder().decode(MonitoredDevice.self, from: data)

    XCTAssertEqual(decoded.deviceIdentifier, "dev1")
    XCTAssertEqual(decoded.isSuppressed, true)
    XCTAssertEqual(decoded.notificationIdentifier, "notif-123")
  }
}
