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
    let exact = zoneID("FamilyPolicies")
    let fixture = [zoneID("OtherZone"), zoneID("FamilyPolicies-Renamed"), exact]

    XCTAssertEqual(
      CloudKitNetworkService.resolveSharedPolicyZoneLookup(
        zoneIDsFromSuccessfulLookup: fixture),
      .present(exact))
  }

  func testGivenOnlyMutatedPolicyName_WhenResolving_ThenRevocationIsConfirmed() {
    let mutatedFixture = [zoneID("FamilyPolicies-Renamed"), zoneID("OtherZone")]

    XCTAssertEqual(
      CloudKitNetworkService.resolveSharedPolicyZoneLookup(
        zoneIDsFromSuccessfulLookup: mutatedFixture),
      .confirmedAbsent)
  }

  func testGivenConfirmedAbsenceInChildMode_WhenResolvingMode_ThenEnforcesIndividual() {
    XCTAssertEqual(
      CloudKitNetworkService.enforcedMode(for: .confirmedAbsent, localMode: .child),
      .individual)
  }

  func testGivenConfirmedAbsenceOutsideChildMode_WhenResolvingMode_ThenDoesNotChangeMode() {
    XCTAssertNil(
      CloudKitNetworkService.enforcedMode(for: .confirmedAbsent, localMode: .parent))
    XCTAssertNil(
      CloudKitNetworkService.enforcedMode(for: .confirmedAbsent, localMode: .individual))
  }

  func testGivenIndeterminateLookupInChildMode_WhenResolvingMode_ThenDoesNotChangeMode() {
    XCTAssertNil(
      CloudKitNetworkService.enforcedMode(for: .indeterminate, localMode: .child))
  }

  func testGivenDisconnectedIndividualSignalInChildMode_WhenResolvingTrigger_ThenRevocationIsConfirmed() {
    XCTAssertEqual(
      CloudKitManager.confirmedRevocationTrigger(
        isConnected: false,
        enforcedMode: .individual,
        currentMode: .child),
      .confirmedCloudKitRevocation)
  }

  func testGivenDisconnectedIndividualSignalOutsideChildMode_WhenResolvingTrigger_ThenNoRevocation() {
    XCTAssertNil(
      CloudKitManager.confirmedRevocationTrigger(
        isConnected: false,
        enforcedMode: .individual,
        currentMode: .parent))
    XCTAssertNil(
      CloudKitManager.confirmedRevocationTrigger(
        isConnected: false,
        enforcedMode: .individual,
        currentMode: .individual))
  }

  func testGivenConnectedIndividualSignalInChildMode_WhenResolvingTrigger_ThenNoRevocation() {
    XCTAssertNil(
      CloudKitManager.confirmedRevocationTrigger(
        isConnected: true,
        enforcedMode: .individual,
        currentMode: .child))
  }
}
