import XCTest

@testable import FamilyFoqos

final class SettingsFamilyControlsVisibilityTests: XCTestCase {
  func testFamilyDashboardVisibilityExcludesOnlyChildMode() {
    let renamedRoleFixtures: [(name: String, mode: AppMode, isVisible: Bool)] = [
      ("self-managed", .individual, true),
      ("family-owner", .parent, true),
      ("family-participant", .child, false),
    ]

    for fixture in renamedRoleFixtures {
      XCTAssertEqual(
        SettingsView.showsFamilyControlsDashboard(mode: fixture.mode),
        fixture.isVisible,
        "Unexpected Family Controls Dashboard visibility for \(fixture.name)"
      )
    }
  }
}
