import FamilyControls
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

  func testGivenNoSessionActivation_WhenForegrounding_ThenWritesCurrentHeartbeat() async {
    let now = Date()
    var writes: [DeviceHeartbeat] = []
    let manager = foregroundManager { writes.append($0) }

    await foreground(manager, now: now)

    XCTAssertEqual(writes.count, 1)
    XCTAssertEqual(writes.first?.lastHeartbeatAt, now)
    XCTAssertEqual(writes.first?.childUserRecordName, "child1")
    XCTAssertEqual(writes.first?.authorizationStatus, "approved")
  }

  func testGivenOldHeartbeatWithoutNewActivation_WhenForegrounding_ThenRefreshesTimestamp() async {
    let now = Date()
    var writes: [DeviceHeartbeat] = []
    let manager = foregroundManager { writes.append($0) }
    await foreground(manager, now: now.addingTimeInterval(-2 * 24 * 3600))

    await foreground(manager, now: now)

    XCTAssertEqual(writes.count, 2)
    XCTAssertEqual(writes.last?.lastHeartbeatAt, now)
  }

  func testGivenSuccessfulForeground_WhenReturningBeforeAndAtThrottleBoundary_ThenWritesOnlyAtBoundary() async {
    let now = Date()
    var writes: [DeviceHeartbeat] = []
    let manager = foregroundManager { writes.append($0) }
    await foreground(manager, now: now)

    await foreground(manager, now: now.addingTimeInterval(899))
    XCTAssertEqual(writes.count, 1)
    await foreground(manager, now: now.addingTimeInterval(900))

    XCTAssertEqual(writes.count, 2)
    XCTAssertEqual(writes.last?.lastHeartbeatAt, now.addingTimeInterval(900))
  }

  func testGivenAuthorizationChangesWithinThrottle_WhenForegrounding_ThenWritesChangedStatusOnly() async {
    let now = Date()
    var status = AuthorizationStatus.approved
    var writes: [DeviceHeartbeat] = []
    let manager = foregroundManager(authorizationStatus: { status }, saveHeartbeat: { writes.append($0) })
    await foreground(manager, now: now)
    status = .denied

    await foreground(manager, now: now.addingTimeInterval(1))
    await foreground(manager, now: now.addingTimeInterval(2))

    XCTAssertEqual(writes.map(\.authorizationStatus), ["approved", "denied"])
    XCTAssertEqual(writes.last?.lastHeartbeatAt, now.addingTimeInterval(1))
  }

  func testGivenAccountChangesWithinThrottle_WhenForegrounding_ThenWritesForNewAccount() async {
    let now = Date()
    var account: String? = "child1"
    var writes: [DeviceHeartbeat] = []
    let manager = foregroundManager(userRecordName: { account }, saveHeartbeat: { writes.append($0) })
    await foreground(manager, now: now)
    account = "child2"

    await foreground(manager, now: now.addingTimeInterval(1))

    XCTAssertEqual(writes.map(\.childUserRecordName), ["child1", "child2"])
  }

  func testGivenWriteFails_WhenNextForegroundArrives_ThenRetriesWithoutWaitingForThrottle() async {
    struct WriteError: Error {}
    let now = Date()
    var attempts = 0
    var writes: [DeviceHeartbeat] = []
    let manager = foregroundManager { heartbeat in
      attempts += 1
      if attempts == 1 { throw WriteError() }
      writes.append(heartbeat)
    }
    await foreground(manager, now: now)

    await foreground(manager, now: now.addingTimeInterval(1))
    await foreground(manager, now: now.addingTimeInterval(2))

    XCTAssertEqual(attempts, 2)
    XCTAssertEqual(writes.first?.lastHeartbeatAt, now.addingTimeInterval(1))
  }

  func testGivenIneligibleForeground_WhenCheckingIn_ThenDoesNotWriteOrArmThrottle() async {
    let now = Date()
    var writes: [DeviceHeartbeat] = []
    let manager = foregroundManager { writes.append($0) }
    let states: [(AppMode, Bool, Bool, Bool)] = [
      (.individual, false, true, true), (.parent, false, true, true),
      (.child, true, true, true), (.child, false, false, true),
      (.child, false, true, false),
    ]
    for (mode, isHeld, isSignedIn, isConnected) in states {
      await manager.writeHeartbeatOnForeground(
        mode: mode, isRecoveryHeld: isHeld, isSignedIn: isSignedIn,
        isConnectedToFamily: isConnected, now: now)
      XCTAssertTrue(writes.isEmpty)
    }

    await foreground(manager, now: now)

    XCTAssertEqual(writes.count, 1)
  }

  func testGivenMissingAccountIdentity_WhenIdentityBecomesReady_ThenNextForegroundWrites() async {
    let now = Date()
    var account: String?
    var writes: [DeviceHeartbeat] = []
    let manager = foregroundManager(userRecordName: { account }, saveHeartbeat: { writes.append($0) })
    await foreground(manager, now: now)
    XCTAssertTrue(writes.isEmpty)
    account = "child1"

    await foreground(manager, now: now.addingTimeInterval(1))

    XCTAssertEqual(writes.count, 1)
  }

  func testGivenStatusChangesDuringWrite_WhenForegroundingAgain_ThenCoalescesAndSendsChangedStatus() async {
    let now = Date()
    let started = expectation(description: "Heartbeat write started")
    var finishWrite: CheckedContinuation<Void, Never>?
    var status = AuthorizationStatus.approved
    var writes: [DeviceHeartbeat] = []
    let manager = foregroundManager(
      authorizationStatus: { status },
      saveHeartbeat: { heartbeat in
        writes.append(heartbeat)
        if writes.count == 1 {
          await withCheckedContinuation { continuation in
            finishWrite = continuation
            started.fulfill()
          }
        }
      })
    let first = Task { await self.foreground(manager, now: now) }
    await fulfillment(of: [started], timeout: 2)
    status = .denied

    await foreground(manager, now: now.addingTimeInterval(1))
    XCTAssertEqual(writes.count, 1)
    finishWrite?.resume()
    await first.value
    await foreground(manager, now: now.addingTimeInterval(2))

    XCTAssertEqual(writes.map(\.authorizationStatus), ["approved", "denied"])
  }

  private func foreground(_ manager: HeartbeatManager, now: Date) async {
    await manager.writeHeartbeatOnForeground(
      mode: .child, isRecoveryHeld: false, isSignedIn: true,
      isConnectedToFamily: true, now: now)
  }

  private func foregroundManager(
    userRecordName: @escaping () -> String? = { "child1" },
    authorizationStatus: @escaping () -> AuthorizationStatus = { .approved },
    saveHeartbeat: @escaping (DeviceHeartbeat) async throws -> Void
  ) -> HeartbeatManager {
    HeartbeatManager(
      defaults: defaults, notificationScheduler: scheduler,
      userRecordName: userRecordName, authorizationStatus: authorizationStatus,
      saveHeartbeat: saveHeartbeat)
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
