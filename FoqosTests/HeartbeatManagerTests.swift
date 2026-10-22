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

  func testGivenForegroundNotReady_WhenCheckingIn_ThenDoesNotWriteOrArmThrottle() async {
    let now = Date()
    var writes: [DeviceHeartbeat] = []
    let manager = foregroundManager { writes.append($0) }
    var isReady = false
    await manager.writeHeartbeatOnForeground(now: { now }, isReady: { isReady })
    XCTAssertTrue(writes.isEmpty)

    isReady = true
    await manager.writeHeartbeatOnForeground(now: { now }, isReady: { isReady })

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

  func testGivenStatusChangesDuringWrite_WhenForegroundingAgain_ThenSendsChangedStatusAfterPendingWrite() async {
    let now = Date()
    var clock = now
    let started = expectation(description: "Heartbeat write started")
    let secondStarted = expectation(description: "Second foreground started")
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
    let first = Task {
      await manager.writeHeartbeatOnForeground(now: { clock }, isReady: { true })
    }
    await fulfillment(of: [started], timeout: 2)
    status = .denied
    clock = now.addingTimeInterval(1)

    let second = Task {
      secondStarted.fulfill()
      await manager.writeHeartbeatOnForeground(now: { clock }, isReady: { true })
    }
    await fulfillment(of: [secondStarted], timeout: 2)
    XCTAssertEqual(writes.count, 1)
    clock = now.addingTimeInterval(30)
    finishWrite?.resume()
    await first.value
    await second.value

    XCTAssertEqual(writes.map(\.authorizationStatus), ["approved", "denied"])
    XCTAssertEqual(writes.last?.lastHeartbeatAt, now.addingTimeInterval(30))
  }

  func testGivenReadinessChangesWhileWaiting_WhenPendingWriteFinishes_ThenDoesNotWriteAgain() async {
    let now = Date()
    let started = expectation(description: "Heartbeat write started")
    let secondReadyCheck = expectation(description: "Second foreground checked readiness")
    var isReady = true
    var checkedSecondReadiness = false
    var finishWrite: CheckedContinuation<Void, Never>?
    var writes: [DeviceHeartbeat] = []
    let manager = foregroundManager { heartbeat in
      writes.append(heartbeat)
      if writes.count == 1 {
        await withCheckedContinuation { continuation in
          finishWrite = continuation
          started.fulfill()
        }
      }
    }
    let first = Task { await self.foreground(manager, now: now) }
    await fulfillment(of: [started], timeout: 2)
    let second = Task {
      await manager.writeHeartbeatOnForeground(
        now: { now.addingTimeInterval(1) },
        isReady: {
          if !checkedSecondReadiness {
            checkedSecondReadiness = true
            secondReadyCheck.fulfill()
          }
          return isReady
        })
    }
    await fulfillment(of: [secondReadyCheck], timeout: 2)
    isReady = false
    finishWrite?.resume()
    await first.value
    await second.value

    XCTAssertEqual(writes.count, 1)
  }

  func testGivenSessionSavePending_WhenForegroundStatusChanges_ThenSavesAreOrdered() async {
    let now = Date()
    await assertOrderedSessionAndForeground(sessionFirst: true, now: now)
  }

  func testGivenForegroundSavePending_WhenSessionStatusChanges_ThenSavesAreOrdered() async {
    let now = Date()
    await assertOrderedSessionAndForeground(sessionFirst: false, now: now)
  }

  func testGivenRecentHeartbeat_WhenSessionStartsRepeat_ThenUnthrottledSavesUpdateForegroundBaseline() async {
    let now = Date()
    var status = AuthorizationStatus.approved
    var writes: [DeviceHeartbeat] = []
    let manager = foregroundManager(authorizationStatus: { status }, saveHeartbeat: { writes.append($0) })
    await foreground(manager, now: now)
    await manager.writeHeartbeat(now: { now.addingTimeInterval(1) }).value
    status = .denied
    await manager.writeHeartbeat(now: { now.addingTimeInterval(2) }).value
    await manager.writeHeartbeat(now: { now.addingTimeInterval(3) }).value
    status = .approved

    await foreground(manager, now: now.addingTimeInterval(4))

    XCTAssertEqual(writes.map(\.authorizationStatus), ["approved", "approved", "denied", "denied", "approved"])
    XCTAssertEqual(writes.last?.lastHeartbeatAt, now.addingTimeInterval(4))
  }

  private func assertOrderedSessionAndForeground(sessionFirst: Bool, now: Date) async {
    let started = expectation(description: "First heartbeat save started")
    let secondEntered = expectation(description: "Second heartbeat requested")
    let overlappingSave = expectation(description: "No overlapping save")
    overlappingSave.isInverted = true
    var firstIsPending = true
    var clock = now
    var finishWrite: CheckedContinuation<Void, Never>?
    var status = AuthorizationStatus.approved
    var completed: [DeviceHeartbeat] = []
    let manager = foregroundManager(
      authorizationStatus: { status },
      saveHeartbeat: { heartbeat in
        if heartbeat.authorizationStatus == "approved" {
          await withCheckedContinuation { continuation in
            finishWrite = continuation
            started.fulfill()
          }
          completed.append(heartbeat)
          firstIsPending = false
        } else {
          if firstIsPending { overlappingSave.fulfill() }
          completed.append(heartbeat)
        }
      })
    let first = Task {
      if sessionFirst {
        await manager.writeHeartbeat(now: { clock }).value
      } else {
        await manager.writeHeartbeatOnForeground(now: { clock }, isReady: { true })
      }
    }
    await fulfillment(of: [started], timeout: 2)
    status = .denied
    clock = now.addingTimeInterval(1)
    let second = Task {
      secondEntered.fulfill()
      if sessionFirst {
        await manager.writeHeartbeatOnForeground(now: { clock }, isReady: { true })
      } else {
        await manager.writeHeartbeat(now: { clock }).value
      }
    }
    await fulfillment(of: [secondEntered], timeout: 2)
    await fulfillment(of: [overlappingSave], timeout: 0.1)
    clock = now.addingTimeInterval(30)
    finishWrite?.resume()
    await first.value
    await second.value

    XCTAssertEqual(completed.map(\.authorizationStatus), ["approved", "denied"])
    XCTAssertEqual(completed.last?.lastHeartbeatAt, now.addingTimeInterval(30))
  }

  private func foreground(_ manager: HeartbeatManager, now: Date) async {
    await manager.writeHeartbeatOnForeground(now: { now }, isReady: { true })
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
