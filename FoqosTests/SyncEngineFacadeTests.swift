import Combine
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineFacadeTests: XCTestCase {
  var testSuiteName: String!
  var manager: ProfileSyncManager!
  var mock: MockSyncEngineControlling!
  private var savedEnabled = false
  private var savedIsSyncReady = false
  private var savedController: (any SyncEngineControlling)?

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "SyncEngineFacadeTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: testSuiteName)!)
    manager = ProfileSyncManager.shared
    savedEnabled = manager.isEnabled
    savedIsSyncReady = manager.isSyncReady
    savedController = manager.engineController
    mock = MockSyncEngineControlling()
    manager.engineController = mock
    manager.isSyncReady = false
    manager.isEnabled = false
  }

  override func tearDown() async throws {
    manager.engineController = savedController
    manager.isSyncReady = savedIsSyncReady
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
    manager.isSyncReady = true

    try manager.syncNow()
    try manager.resetSync(clearRemoteAppSelections: true)
    try manager.enqueueProfileSave(id)
    try manager.enqueueProfileDelete(id)
    try manager.enqueueLocationSave(id)
    try manager.enqueueLocationDelete(id)
    try manager.enqueueEmergencySettingsSave()

    XCTAssertEqual(
      mock.requestSyncCount, 6,
      "syncNow (1) + five enqueue verbs each flush once when ready (5)")
    XCTAssertEqual(mock.beginResetCalls, [true])
    XCTAssertEqual(mock.enqueuedProfileSaves, [id])
    XCTAssertEqual(mock.enqueuedProfileDeletes, [id])
    XCTAssertEqual(mock.enqueuedLocationSaves, [id])
    XCTAssertEqual(mock.enqueuedLocationDeletes, [id])
    XCTAssertEqual(mock.enqueuedEmergencySaves, 1)
  }

  func testGivenReadyController_WhenEnqueueProfileSave_ThenRequestSyncIsScheduled() throws {
    manager.isSyncReady = true
    let id = UUID()

    try manager.enqueueProfileSave(id)

    XCTAssertEqual(mock.enqueuedProfileSaves, [id], "the save is forwarded to the engine")
    XCTAssertEqual(
      mock.requestSyncCount, 1,
      "a ready engine flushes a user-initiated save promptly, not on the next foreground")
  }

  func testGivenNotAttached_WhenEnqueueProfileSave_ThenIdIsDeferredAndReEnqueuedOnReady() throws {
    let id = UUID()
    manager.engineController = nil

    XCTAssertThrowsError(try manager.enqueueProfileSave(id)) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }

    let attached = MockSyncEngineControlling()
    manager.engineController = attached
    manager.markSyncReadyAndFlush()

    XCTAssertEqual(attached.enqueuedProfileSaves, [id], "the dropped save is retried on attach")
    XCTAssertEqual(attached.requestSyncCount, 1, "exactly one flush covers all drained mutations")
    XCTAssertTrue(manager.hasNoDeferredMutations, "the deferred sets are cleared after draining")
  }

  func testGivenNotAttached_WhenEnqueueLocationSave_ThenIdIsDeferredAndReEnqueuedOnReady() throws {
    let id = UUID()
    manager.engineController = nil

    XCTAssertThrowsError(try manager.enqueueLocationSave(id)) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }

    let attached = MockSyncEngineControlling()
    manager.engineController = attached
    manager.markSyncReadyAndFlush()

    XCTAssertEqual(attached.enqueuedLocationSaves, [id], "the dropped location save is retried on attach")
    XCTAssertEqual(attached.requestSyncCount, 1, "exactly one flush covers all drained mutations")
    XCTAssertTrue(manager.hasNoDeferredMutations, "the deferred sets are cleared after draining")
  }

  func testGivenNotAttached_WhenEnqueueEmergencySettingsSave_ThenSaveIsDeferredAndReEnqueuedOnReady()
    throws
  {
    manager.engineController = nil

    XCTAssertThrowsError(try manager.enqueueEmergencySettingsSave()) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }

    let attached = MockSyncEngineControlling()
    manager.engineController = attached
    manager.markSyncReadyAndFlush()

    XCTAssertEqual(attached.enqueuedEmergencySaves, 1, "the dropped emergency save is retried on attach")
    XCTAssertEqual(attached.requestSyncCount, 1, "exactly one flush covers all drained mutations")
    XCTAssertTrue(manager.hasNoDeferredMutations, "the deferred sets are cleared after draining")
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
