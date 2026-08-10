import XCTest

@testable import FamilyFoqos

final class FamilyMemberLogRedactionTests: XCTestCase {
  func testGivenMember_WhenRedactedLogLabel_ThenUsesRoleAndStableIdWithoutName() {
    let id = UUID(uuidString: "3F2A9C1B-0000-4000-8000-000000000000")!
    let member = FamilyMember(
      id: id,
      userRecordName: "urn_abc",
      displayName: "Emma",
      role: .child
    )

    XCTAssertEqual(member.redactedLogLabel, "child·3F2A9C1B")
    XCTAssertFalse(member.redactedLogLabel.contains("Emma"), "must not leak displayName")
  }

  func testGivenParticipantRecordName_WhenFormattingStatusLog_ThenIncludesOpaqueIdentifier() {
    XCTAssertEqual(
      ShareParticipantLog.statusMessage(
        userRecordName: "opaque-record-name",
        acceptanceStatus: 2
      ),
      "Participant opaque-record-name status: 2"
    )
  }

  func testGivenMissingParticipantRecordName_WhenFormattingStatusLog_ThenUsesUnresolved() {
    XCTAssertEqual(
      ShareParticipantLog.statusMessage(userRecordName: nil, acceptanceStatus: 1),
      "Participant unresolved status: 1"
    )
  }
}
