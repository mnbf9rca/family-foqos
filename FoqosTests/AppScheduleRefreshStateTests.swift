import SwiftUI
import XCTest

@testable import FamilyFoqos

final class AppScheduleRefreshStateTests: XCTestCase {
  func testGivenInitialSetupCompleted_WhenInitialActiveArrives_ThenRefreshIsSkipped() {
    var state = AppScheduleRefreshState()
    XCTAssertTrue(state.shouldPerformInitialRefresh())

    XCTAssertFalse(state.shouldRefresh(for: .active))
  }

  func testGivenInitialInactiveArrivesBeforeSetup_WhenInitialActiveArrives_ThenRefreshIsSkipped() {
    var state = AppScheduleRefreshState()
    XCTAssertFalse(state.shouldRefresh(for: .inactive))
    XCTAssertTrue(state.shouldPerformInitialRefresh())

    XCTAssertFalse(state.shouldRefresh(for: .active))
  }

  func testGivenInitialSetupCompleted_WhenAppReturnsFromInactive_ThenRefreshRunsOnce() {
    var state = AppScheduleRefreshState()
    XCTAssertTrue(state.shouldPerformInitialRefresh())

    XCTAssertFalse(state.shouldRefresh(for: .inactive))
    XCTAssertTrue(state.shouldRefresh(for: .active))
    XCTAssertFalse(state.shouldRefresh(for: .active))
  }

  func testGivenInitialSetupCompleted_WhenAppReturnsFromBackground_ThenRefreshRunsOnce() {
    var state = AppScheduleRefreshState()
    XCTAssertTrue(state.shouldPerformInitialRefresh())

    XCTAssertFalse(state.shouldRefresh(for: .background))
    XCTAssertFalse(state.shouldRefresh(for: .inactive))
    XCTAssertTrue(state.shouldRefresh(for: .active))
  }

  func testGivenInitialRefreshAlreadyPerformed_WhenRootAppearsAgain_ThenRefreshIsSkipped() {
    var state = AppScheduleRefreshState()

    XCTAssertTrue(state.shouldPerformInitialRefresh())
    XCTAssertFalse(state.shouldPerformInitialRefresh())
  }
}
