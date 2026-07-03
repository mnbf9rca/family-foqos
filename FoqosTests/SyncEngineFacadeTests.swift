import Combine
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineFacadeTests: XCTestCase {
  var testSuiteName: String!
  var manager: ProfileSyncManager!
  var mock: MockSyncEngineControlling!
  private var savedEnabled = false
  private var savedController: (any SyncEngineControlling)?

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "SyncEngineFacadeTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: testSuiteName)!)
    manager = ProfileSyncManager.shared
    savedEnabled = manager.isEnabled
    savedController = manager.engineController
    mock = MockSyncEngineControlling()
    manager.engineController = mock
    manager.isEnabled = false
  }

  override func tearDown() async throws {
    manager.engineController = savedController
    manager.isEnabled = savedEnabled
    UserDefaults().removePersistentDomain(forName: testSuiteName)
    try await super.tearDown()
  }

  func testGivenController_WhenToggledOn_ThenStartIsCalledAndPersisted() {
    manager.isEnabled = true

    XCTAssertEqual(mock.startCount, 1)
    XCTAssertEqual(mock.stopCount, 0)
    XCTAssertTrue(SharedData.deviceSyncEnabled)
    XCTAssertEqual(manager.syncStatus, .idle)
  }

  func testGivenController_WhenToggledOffAfterOn_ThenStopIsCalled() {
    manager.isEnabled = true
    manager.isEnabled = false

    XCTAssertEqual(mock.startCount, 1)
    XCTAssertEqual(mock.stopCount, 1)
    XCTAssertFalse(SharedData.deviceSyncEnabled)
    XCTAssertEqual(manager.syncStatus, .disabled)
  }

  func testGivenController_WhenFacadeVerbsCalled_ThenTheyForward() {
    let id = UUID()
    manager.syncNow()
    manager.resetSync(clearRemoteAppSelections: true)
    manager.enqueueProfileSave(id)
    manager.enqueueProfileDelete(id)
    manager.enqueueLocationSave(id)
    manager.enqueueLocationDelete(id)
    manager.enqueueEmergencySettingsSave()

    XCTAssertEqual(mock.requestSyncCount, 1)
    XCTAssertEqual(mock.beginResetCalls, [true])
    XCTAssertEqual(mock.enqueuedProfileSaves, [id])
    XCTAssertEqual(mock.enqueuedProfileDeletes, [id])
    XCTAssertEqual(mock.enqueuedLocationSaves, [id])
    XCTAssertEqual(mock.enqueuedLocationDeletes, [id])
    XCTAssertEqual(mock.enqueuedEmergencySaves, 1)
  }
}
