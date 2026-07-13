import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineAccountChangeTests: XCTestCase {
  var suiteName: String!
  var defaults: UserDefaults!
  var container: ModelContainer!
  var context: ModelContext!
  var store: SyncEngineStore!
  var driver: MockSyncEngineDriver!
  var apply: SyncApplyService!
  var provider: RecordProvider!
  var emergencyManager: EmergencyUnblockManager!
  var sessionSync: MockSessionSyncFlushing!
  let deviceId = "device-A"
  let userRecordName = "user-A"

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "SyncEngineAccountChangeTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
    container = try TestModelContainer.create()
    context = container.mainContext
    store = SyncEngineStore(userRecordName: userRecordName, defaults: defaults)
    driver = MockSyncEngineDriver()
    emergencyManager = EmergencyUnblockManager(defaults: defaults)
    apply = SyncApplyService(
      modelContext: context, store: store, sessionController: MockSessionController(),
      emergencyManager: emergencyManager, deviceId: deviceId)
    provider = RecordProvider(
      modelContext: context, store: store, emergencyManager: emergencyManager, deviceId: deviceId)
    sessionSync = MockSessionSyncFlushing()
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func makeController() -> SyncEngineController {
    SyncEngineController(
      modelContext: context,
      store: store,
      driverFactory: { [driver] _ in driver! },
      apply: apply,
      provider: provider,
      sessionSync: sessionSync,
      deviceId: deviceId)
  }

  func testStopTransitionsToDisabled() throws {
    let controller = makeController()

    controller.start()
    XCTAssertNotEqual(controller.state, .disabled)

    controller.stop()

    XCTAssertEqual(controller.state, .disabled)
  }

  func testRequestSyncNoOpsWhenDisabledEvenWithLiveDriver() throws {
    let controller = makeController()
    controller.start()
    controller.forceStateForTest(.disabled)
    driver.reset()

    controller.requestSync()

    XCTAssertEqual(driver.fetchChangesCount, 0)
    XCTAssertEqual(driver.sendChangesCount, 0)
  }

  func testRequestSyncNoOpsWhileResolvingAccountChange() throws {
    let controller = makeController()
    controller.start()
    controller.forceStateForTest(.steady)
    controller.beginAccountResolution()
    driver.reset()

    controller.requestSync()

    XCTAssertEqual(driver.sendChangesCount, 0)

    controller.endAccountResolution()
    controller.requestSync()

    XCTAssertEqual(driver.sendChangesCount, 1)
  }

  func testStopNilsDriverAndShutsItDown() throws {
    let controller = makeController()
    controller.start()

    XCTAssertTrue(controller.hasLiveDriver)

    controller.stop()

    XCTAssertFalse(controller.hasLiveDriver)
    XCTAssertEqual(driver.shutdownCallCount, 1)
    XCTAssertGreaterThanOrEqual(driver.sendChangesCount, 1)
  }

  func testHandleIgnoresEventsAfterTeardown() throws {
    let controller = makeController()
    controller.start()
    controller.stop()

    controller.handle(.didFetchChanges)

    XCTAssertFalse(controller.hasLiveDriver)
  }

  func testSignInSuppressesButDoesNotTearDown() throws {
    let controller = makeController()
    controller.start()
    var seen: SyncEngineAccountChangeKind?
    controller.onAccountChange = { seen = $0 }

    controller.handle(.accountChange(kind: .signIn))

    XCTAssertTrue(controller.hasLiveDriver)
    XCTAssertTrue(controller.accountResolutionInFlight)
    XCTAssertEqual(seen, .signIn)
  }

  func testSignOutTearsDownAndSignals() throws {
    let controller = makeController()
    controller.start()
    var seen: SyncEngineAccountChangeKind?
    controller.onAccountChange = { seen = $0 }

    controller.handle(.accountChange(kind: .signOut))

    XCTAssertFalse(controller.hasLiveDriver)
    XCTAssertEqual(controller.state, .disabled)
    XCTAssertEqual(driver.shutdownCallCount, 1)
    XCTAssertEqual(seen, .signOut)
  }
}
