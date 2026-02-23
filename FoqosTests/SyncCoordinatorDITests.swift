import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncCoordinatorDITests: XCTestCase {

  func testGivenMockSessionController_WhenInitialized_ThenAcceptsMock() {
    let mock = MockSessionController()
    let coordinator = SyncCoordinator(sessionController: mock)

    // Verify coordinator was created with injected mock (no crash, no StrategyManager.shared)
    XCTAssertNotNil(coordinator)
  }

  func testGivenMockSyncManager_WhenInitialized_ThenSetsDelegate() {
    let syncManager = ProfileSyncManager.shared
    let mock = MockSessionController()
    let coordinator = SyncCoordinator(sessionController: mock, syncManager: syncManager)

    // Verify coordinator set itself as delegate
    XCTAssertNotNil(coordinator)
    XCTAssertTrue(syncManager.syncEventDelegate === coordinator)
  }
}
