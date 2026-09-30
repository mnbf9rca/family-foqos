import XCTest

@testable import FamilyFoqos

final class ParticipantRemovalDecisionTests: XCTestCase {

  private func member(_ recordName: String) -> FamilyMember {
    FamilyMember(userRecordName: recordName, role: .child)
  }

  func testGivenAllResolved_WhenMemberAbsentFromParticipants_ThenMemberRemoved() {
    let existing = [member("rec-A"), member("rec-B")]
    let accepted: Set<String> = ["rec-A"]

    let toRemove = CloudKitNetworkService.familyMembersToRemove(
      from: existing,
      acceptedParticipantRecordNames: accepted,
      hasUnresolvedAcceptedParticipant: false
    )

    XCTAssertEqual(toRemove.map { $0.userRecordName }, ["rec-B"])
  }

  func testGivenUnresolvedParticipant_WhenMemberAbsentFromParticipants_ThenNothingRemoved() {
    let existing = [member("rec-A"), member("rec-B")]
    let accepted: Set<String> = ["rec-A"]

    let toRemove = CloudKitNetworkService.familyMembersToRemove(
      from: existing,
      acceptedParticipantRecordNames: accepted,
      hasUnresolvedAcceptedParticipant: true
    )

    XCTAssertTrue(
      toRemove.isEmpty,
      "Must not delete any member while any accepted participant is unresolved")
  }

  func testGivenAllResolvedAndAllPresent_WhenNoDepartures_ThenNothingRemoved() {
    let existing = [member("rec-A"), member("rec-B")]
    let accepted: Set<String> = ["rec-A", "rec-B"]

    let toRemove = CloudKitNetworkService.familyMembersToRemove(
      from: existing,
      acceptedParticipantRecordNames: accepted,
      hasUnresolvedAcceptedParticipant: false
    )

    XCTAssertTrue(toRemove.isEmpty)
  }

  func testGivenNoExistingMembers_ThenNothingRemoved() {
    let toRemove = CloudKitNetworkService.familyMembersToRemove(
      from: [],
      acceptedParticipantRecordNames: [],
      hasUnresolvedAcceptedParticipant: false
    )

    XCTAssertTrue(toRemove.isEmpty)
  }
}
