import XCTest

@testable import FamilyFoqos

final class ParentDashboardRefreshPolicyTests: XCTestCase {
  func testLiveMemberNameMatchesExactIdentityAndFallsBackOnlyToRole() {
    let now = Date()
    let child = FamilyMember(userRecordName: "child-id", role: .child, enrolledAt: now)
    let parent = FamilyMember(userRecordName: "parent-id", role: .parent, enrolledAt: now)
    var emma = PersonNameComponents()
    emma.givenName = "Emma"
    var other = PersonNameComponents()
    other.givenName = "Other"
    var blank = PersonNameComponents()
    blank.givenName = " \n "
    XCTAssertEqual(
      ParentDashboardView.memberDisplayName(
        for: child, acceptedIdentities: [(nil, other), ("Child-id", other), ("child-id", emma)]),
      "Emma")
    for identities: [(recordName: String?, nameComponents: PersonNameComponents?)] in [
      [], [("someone-else", emma)], [("Child-id", emma)], [("child-id", nil)],
      [("child-id", PersonNameComponents())], [("child-id", blank)],
    ] {
      XCTAssertEqual(ParentDashboardView.memberDisplayName(for: child, acceptedIdentities: identities), "Child")
    }
    XCTAssertEqual(ParentDashboardView.memberDisplayName(for: parent, acceptedIdentities: []), "Parent")
  }

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
