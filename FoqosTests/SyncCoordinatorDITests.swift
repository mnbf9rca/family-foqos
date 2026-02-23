import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncCoordinatorDITests: XCTestCase {

  private var previousDelegate: SyncEventDelegate?

  override func setUp() async throws {
    try await super.setUp()
    previousDelegate = ProfileSyncManager.shared.syncEventDelegate
  }

  override func tearDown() async throws {
    ProfileSyncManager.shared.syncEventDelegate = previousDelegate
    try await super.tearDown()
  }

  func testGivenMockSessionController_WhenInitialized_ThenAcceptsMock() {
    // Verifies init doesn't crash with mock injection (no StrategyManager.shared needed)
    let mock = MockSessionController()
    _ = SyncCoordinator(sessionController: mock)
  }

  func testGivenSharedSyncManager_WhenInitialized_ThenSetsDelegate() {
    let syncManager = ProfileSyncManager.shared
    let mock = MockSessionController()
    let coordinator = SyncCoordinator(sessionController: mock, syncManager: syncManager)

    XCTAssertTrue(syncManager.syncEventDelegate === coordinator)
  }
}
