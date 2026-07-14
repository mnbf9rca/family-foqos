import XCTest

@testable import FamilyFoqos

final class FamilyMemberLogRedactionTests: XCTestCase {
  func testGivenMember_WhenRedactedLogLabel_ThenIsUUIDAndContainsNoName() {
    let id = UUID()
    let member = FamilyMember(
      id: id,
      userRecordName: "urn_abc",
      displayName: "Emma",
      role: .child
    )

    XCTAssertEqual(member.redactedLogLabel, id.uuidString)
    XCTAssertFalse(member.redactedLogLabel.contains("Emma"), "must not leak displayName")
  }
}
