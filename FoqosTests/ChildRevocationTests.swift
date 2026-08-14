import CloudKit
import XCTest

@testable import FamilyFoqos

final class ChildRevocationTests: XCTestCase {
  private func zoneID(_ name: String) -> CKRecordZone.ID {
    CKRecordZone.ID(zoneName: name, ownerName: "test-owner")
  }

  func testGivenSuccessfulEmptyLookup_WhenResolvingZone_ThenRevocationIsConfirmed() {
    XCTAssertEqual(
      CloudKitNetworkService.resolveSharedPolicyZoneLookup(
        zoneIDsFromSuccessfulLookup: []),
      .confirmedAbsent)
  }

  func testGivenFailedLookup_WhenResolvingZone_ThenResultIsIndeterminate() {
    XCTAssertEqual(
      CloudKitNetworkService.resolveSharedPolicyZoneLookup(
        zoneIDsFromSuccessfulLookup: nil),
      .indeterminate)
  }

  func testGivenExactPolicyZoneAmongOtherZones_WhenResolving_ThenExactZoneIsPresent() {
    let exact = zoneID(CloudKitConstants.policyZoneName)
    let fixture = [
      zoneID("OtherZone"),
      zoneID("\(CloudKitConstants.policyZoneName)-Renamed"),
      exact,
    ]

    XCTAssertEqual(
      CloudKitNetworkService.resolveSharedPolicyZoneLookup(
        zoneIDsFromSuccessfulLookup: fixture),
      .present(exact))
  }

  func testGivenOnlyMutatedPolicyName_WhenResolving_ThenRevocationIsConfirmed() {
    let mutatedFixture = [
      zoneID("\(CloudKitConstants.policyZoneName)-Renamed"),
      zoneID("OtherZone"),
    ]

    XCTAssertEqual(
      CloudKitNetworkService.resolveSharedPolicyZoneLookup(
        zoneIDsFromSuccessfulLookup: mutatedFixture),
      .confirmedAbsent)
  }

  func testGivenConfirmedAbsenceInChildMode_WhenResolvingMode_ThenEnforcesIndividual() {
    XCTAssertEqual(
      CloudKitNetworkService.enforcedMode(
        for: .confirmedAbsent,
        localMode: .child,
        accountIsSignedIn: true),
      .individual)
  }

  func testGivenConfirmedAbsenceOutsideChildMode_WhenResolvingMode_ThenDoesNotChangeMode() {
    XCTAssertNil(
      CloudKitNetworkService.enforcedMode(
        for: .confirmedAbsent,
        localMode: .parent,
        accountIsSignedIn: true))
    XCTAssertNil(
      CloudKitNetworkService.enforcedMode(
        for: .confirmedAbsent,
        localMode: .individual,
        accountIsSignedIn: true))
  }

  func testGivenIndeterminateLookupInChildMode_WhenResolvingMode_ThenDoesNotChangeMode() {
    XCTAssertNil(
      CloudKitNetworkService.enforcedMode(
        for: .indeterminate,
        localMode: .child,
        accountIsSignedIn: true))
  }

  func testGivenConfirmedAbsenceWhileSignedOut_WhenResolvingMode_ThenDoesNotChangeMode() {
    XCTAssertNil(
      CloudKitNetworkService.enforcedMode(
        for: .confirmedAbsent,
        localMode: .child,
        accountIsSignedIn: false))
  }

  func testGivenDisconnectedIndividualSignalInChildMode_WhenResolvingTrigger_ThenRevocationIsConfirmed() {
    XCTAssertEqual(
      CloudKitManager.confirmedRevocationTrigger(
        isConnected: false,
        isSignedIn: true,
        enforcedMode: .individual,
        currentMode: .child),
      .confirmedCloudKitRevocation)
  }

  func testGivenDisconnectedIndividualSignalOutsideChildMode_WhenResolvingTrigger_ThenNoRevocation() {
    XCTAssertNil(
      CloudKitManager.confirmedRevocationTrigger(
        isConnected: false,
        isSignedIn: true,
        enforcedMode: .individual,
        currentMode: .parent))
    XCTAssertNil(
      CloudKitManager.confirmedRevocationTrigger(
        isConnected: false,
        isSignedIn: true,
        enforcedMode: .individual,
        currentMode: .individual))
  }

  func testGivenConnectedIndividualSignalInChildMode_WhenResolvingTrigger_ThenNoRevocation() {
    XCTAssertNil(
      CloudKitManager.confirmedRevocationTrigger(
        isConnected: true,
        isSignedIn: true,
        enforcedMode: .individual,
        currentMode: .child))
  }

  func testGivenSignedOutIndividualSignalInChildMode_WhenResolvingTrigger_ThenNoRevocation() {
    XCTAssertNil(
      CloudKitManager.confirmedRevocationTrigger(
        isConnected: false,
        isSignedIn: false,
        enforcedMode: .individual,
        currentMode: .child))
  }
}
