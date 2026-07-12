import UserNotifications
import XCTest

@testable import FamilyFoqos

@MainActor
final class HeartbeatManagerTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var scheduler: FakeHeartbeatNotificationScheduler!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "HeartbeatManagerTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    scheduler = FakeHeartbeatNotificationScheduler()
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
    scheduler = nil
    defaults = nil
    suiteName = nil
    try await super.tearDown()
  }

  func testGivenAuthRevokedAlertInFlight_WhenSchedulingAgain_ThenDoesNotScheduleDuplicate() {
    let manager = managerWithDeniedDevice()

    manager.scheduleNotifications()
    manager.scheduleNotifications()

    XCTAssertEqual(scheduler.addedRequests.count, 1)
    XCTAssertNil(manager.monitoredDevices.first?.authRevokedNotifiedAt)
  }

  func testGivenAuthRevokedAlertAddFails_WhenCompleted_ThenMarkerRemainsNilAndNextRefreshRetries() {
    let manager = managerWithDeniedDevice()

    manager.scheduleNotifications()
    scheduler.completeNextAdd(error: FakeHeartbeatNotificationScheduler.StubError())
    manager.scheduleNotifications()

    XCTAssertEqual(scheduler.addedRequests.count, 2)
    XCTAssertNil(manager.monitoredDevices.first?.authRevokedNotifiedAt)
  }

  func testGivenAuthRevokedAlertAddSucceeds_WhenCompleted_ThenMarkerIsPersisted() {
    let manager = managerWithDeniedDevice()

    manager.scheduleNotifications()
    scheduler.completeNextAdd(error: nil)

    XCTAssertNotNil(manager.monitoredDevices.first?.authRevokedNotifiedAt)
    XCTAssertEqual(manager.monitoredDevices.first?.notificationIdentifier, "heartbeat-child1|dev1")
  }

  private func managerWithDeniedDevice() -> HeartbeatManager {
    let manager = HeartbeatManager(defaults: defaults, notificationScheduler: scheduler)
    manager.monitoredDevices = [
      MonitoredDevice(
        deviceIdentifier: "dev1",
        deviceName: "iPhone",
        childUserRecordName: "child1",
        lastSeenAt: Date(),
        isSuppressed: false,
        notificationIdentifier: nil,
        authorizationStatus: "denied",
        authRevokedNotifiedAt: nil
      )
    ]
    return manager
  }
}

@MainActor
private final class FakeHeartbeatNotificationScheduler: HeartbeatNotificationScheduling {
  struct StubError: Error {}

  private(set) var addedRequests: [UNNotificationRequest] = []
  private var completions: [@MainActor @Sendable (Error?) -> Void] = []

  func requestAuthorization(
    options: UNAuthorizationOptions,
    completionHandler: @MainActor @Sendable @escaping (Bool, Error?) -> Void
  ) {
    completionHandler(true, nil)
  }

  func add(
    _ request: UNNotificationRequest,
    completionHandler: @MainActor @Sendable @escaping (Error?) -> Void
  ) {
    addedRequests.append(request)
    completions.append(completionHandler)
  }

  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}

  func completeNextAdd(error: Error?) {
    let completion = completions.removeFirst()
    completion(error)
  }
}
