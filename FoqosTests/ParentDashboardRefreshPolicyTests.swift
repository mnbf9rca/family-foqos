import XCTest

@testable import FamilyFoqos

final class ParentDashboardRefreshPolicyTests: XCTestCase {
  func testOwnerDashboardRefreshExcludesOnlyChildMode() {
    let fixtures: [(mode: AppMode, isAllowed: Bool)] = [
      (.individual, true),
      (.parent, true),
      (.child, false),
    ]

    for fixture in fixtures {
      XCTAssertEqual(
        ParentDashboardView.allowsOwnerRefresh(mode: fixture.mode),
        fixture.isAllowed,
        "Unexpected owner refresh policy for \(fixture.mode)"
      )
    }
  }
}
