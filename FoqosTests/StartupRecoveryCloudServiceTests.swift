import XCTest

@testable import FamilyFoqos

final class StartupRecoveryCloudServiceTests: XCTestCase {
  func testMembershipObservationMapsOnlyConfirmedEvidenceToDefinitiveResults() {
    XCTAssertEqual(
      StartupRecoveryCloudService.resolveMembership(
        .recordRole(role: "parent", ownerUserRecordName: "owner-A")),
      .member(role: .parent, ownerUserRecordName: "owner-A"))
    XCTAssertEqual(
      StartupRecoveryCloudService.resolveMembership(
        .recordRole(role: "child", ownerUserRecordName: "owner-B")),
      .member(role: .child, ownerUserRecordName: "owner-B"))
    XCTAssertEqual(
      StartupRecoveryCloudService.resolveMembership(
        .zoneListSucceededWithoutPolicyZone(ownerUserRecordName: "owner-A")),
      .confirmedNone(ownerUserRecordName: "owner-A"))
    XCTAssertEqual(
      StartupRecoveryCloudService.resolveMembership(
        .recordAbsent(ownerUserRecordName: "owner-B")),
      .confirmedNone(ownerUserRecordName: "owner-B"))
  }

  func testMembershipObservationKeepsUnavailableOrInvalidEvidenceIndeterminate() {
    let observations: [StartupRecoveryMembershipObservation] = [
      .accountUnavailable,
      .accountIndeterminate,
      .sharedZoneIndeterminate,
      .recordFetchFailed,
      .recordZoneMissing,
      .recordRole(role: "owner", ownerUserRecordName: "owner-A"),
    ]

    for observation in observations {
      XCTAssertEqual(
        StartupRecoveryCloudService.resolveMembership(observation),
        .indeterminate,
        "Expected \(observation) to stay indeterminate")
    }
  }

  func testProfileFoldTracksMultiplePagesDeletionsUnrelatedTypesAndDuplicateCallbacks() {
    var fold = StartupRecoveryProfileRecordFold()

    fold.applyModification(recordName: "profile-a", recordType: SyncedProfile.recordType)
    fold.applyModification(recordName: "profile-b", recordType: SyncedProfile.recordType)
    fold.applyModification(recordName: "location", recordType: "SyncedLocation")
    fold.applyModification(recordName: "profile-a", recordType: SyncedProfile.recordType)

    fold.applyModification(recordName: "profile-c", recordType: SyncedProfile.recordType)
    fold.applyDeletion(recordName: "profile-b", recordType: SyncedProfile.recordType)
    fold.applyDeletion(recordName: "unknown", recordType: SyncedProfile.recordType)
    fold.applyDeletion(recordName: "profile-c", recordType: "SyncedLocation")

    XCTAssertEqual(fold.profileCount, 2)
  }

  func testProfileFetchOutcomeMapsOnlySuccessfulEvidenceToZero() {
    XCTAssertEqual(
      StartupRecoveryCloudService.resolveProfileCount(
        fold: StartupRecoveryProfileRecordFold(), outcome: .success),
      .confirmed(0))
    XCTAssertEqual(
      StartupRecoveryCloudService.resolveProfileCount(
        fold: StartupRecoveryProfileRecordFold(),
        outcome: .zoneListSucceededWithoutSyncZone),
      .confirmed(0))
  }

  func testProfileFetchMissingZoneErrorRemainsIndeterminateWithoutSuccessfulZoneList() {
    XCTAssertEqual(
      StartupRecoveryCloudService.resolveProfileCount(
        fold: StartupRecoveryProfileRecordFold(), outcome: .zoneFetchReportedMissing),
      .indeterminate)
  }

  func testProfileFetchOutcomeReturnsCountOnlyAfterSuccessfulFetch() {
    var fold = StartupRecoveryProfileRecordFold()
    fold.applyModification(recordName: "profile-a", recordType: SyncedProfile.recordType)
    fold.applyModification(recordName: "profile-b", recordType: SyncedProfile.recordType)

    XCTAssertEqual(
      StartupRecoveryCloudService.resolveProfileCount(fold: fold, outcome: .success),
      .confirmed(2))
    XCTAssertEqual(
      StartupRecoveryCloudService.resolveProfileCount(fold: fold, outcome: .indeterminate),
      .indeterminate)
  }
}
