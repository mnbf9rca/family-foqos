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

  func testGivenParticipantRecordName_WhenFormattingStatusLog_ThenIncludesOpaqueIdentifier() {
    XCTAssertEqual(
      ShareParticipantLog.statusMessage(
        userRecordName: "opaque-record-name",
        acceptanceStatus: 2
      ),
      "Participant opaque-record-name status: 2"
    )
  }

  func testGivenMissingParticipantRecordName_WhenFormattingStatusLog_ThenUsesUnknown() {
    XCTAssertEqual(
      ShareParticipantLog.statusMessage(userRecordName: nil, acceptanceStatus: 1),
      "Participant unknown status: 1"
    )
  }
}
