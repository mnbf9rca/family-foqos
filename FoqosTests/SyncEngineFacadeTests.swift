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

  func testGivenController_WhenFacadeVerbsCalled_ThenTheyForward() throws {
    let id = UUID()
    try manager.syncNow()
    try manager.resetSync(clearRemoteAppSelections: true)
    try manager.enqueueProfileSave(id)
    try manager.enqueueProfileDelete(id)
    try manager.enqueueLocationSave(id)
    try manager.enqueueLocationDelete(id)
    try manager.enqueueEmergencySettingsSave()

    XCTAssertEqual(mock.requestSyncCount, 1)
    XCTAssertEqual(mock.beginResetCalls, [true])
    XCTAssertEqual(mock.enqueuedProfileSaves, [id])
    XCTAssertEqual(mock.enqueuedProfileDeletes, [id])
    XCTAssertEqual(mock.enqueuedLocationSaves, [id])
    XCTAssertEqual(mock.enqueuedLocationDeletes, [id])
    XCTAssertEqual(mock.enqueuedEmergencySaves, 1)
  }

  // MARK: - Review fix: not-attached and genuine-throw propagation (findings #2–#6, #15)

  func testGivenNoEngineController_WhenSyncNow_ThenThrowsNotAttachedInsteadOfSilentNoOp() {
    manager.engineController = nil

    XCTAssertThrowsError(try manager.syncNow()) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }
  }

  func testGivenNoEngineController_WhenResetSync_ThenThrowsNotAttachedInsteadOfSilentNoOp() {
    manager.engineController = nil

    XCTAssertThrowsError(try manager.resetSync(clearRemoteAppSelections: false)) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }
  }

  func testGivenNoEngineController_WhenEnqueueProfileDelete_ThenThrowsNotAttachedInsteadOfSilentNoOp() {
    manager.engineController = nil

    XCTAssertThrowsError(try manager.enqueueProfileDelete(UUID())) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }
  }

  func testGivenEngineThrowsGenuineError_WhenEnqueueProfileDelete_ThenFacadePropagatesIt() {
    mock.errorToThrow = MutationFunnel.MutationFunnelError.entityNotFound

    XCTAssertThrowsError(try manager.enqueueProfileDelete(UUID())) { error in
      XCTAssertEqual(error as? MutationFunnel.MutationFunnelError, .entityNotFound)
    }
    XCTAssertTrue(mock.enqueuedProfileDeletes.isEmpty, "the throw must not be swallowed as a silent success")
  }
}
