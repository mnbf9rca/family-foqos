import XCTest

@testable import FamilyFoqos

final class StartupRecoveryCloudServiceTests: XCTestCase {
  func testMembershipObservationMapsOnlyConfirmedEvidenceToDefinitiveResults() {
    XCTAssertEqual(
      StartupRecoveryCloudService.resolveMembership(.recordRole("parent")),
      .member(.parent))
    XCTAssertEqual(
      StartupRecoveryCloudService.resolveMembership(.recordRole("child")),
      .member(.child))
    XCTAssertEqual(
      StartupRecoveryCloudService.resolveMembership(.sharedZoneAbsent),
      .confirmedNone)
    XCTAssertEqual(
      StartupRecoveryCloudService.resolveMembership(.recordAbsent),
      .confirmedNone)
  }

  func testMembershipObservationKeepsUnavailableOrInvalidEvidenceIndeterminate() {
    let observations: [StartupRecoveryMembershipObservation] = [
      .accountUnavailable,
      .accountIndeterminate,
      .sharedZoneIndeterminate,
      .recordFailed,
      .recordRole("owner"),
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

  func testProfileFetchOutcomeMapsSuccessfulEmptyAndMissingZoneToZero() {
    XCTAssertEqual(
      StartupRecoveryCloudService.resolveProfileCount(
        fold: StartupRecoveryProfileRecordFold(), outcome: .success),
      .confirmed(0))
    XCTAssertEqual(
      StartupRecoveryCloudService.resolveProfileCount(
        fold: StartupRecoveryProfileRecordFold(), outcome: .zoneMissing),
      .confirmed(0))
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
