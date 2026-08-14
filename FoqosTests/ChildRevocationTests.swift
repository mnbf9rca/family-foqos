import CloudKit
import XCTest

@testable import FamilyFoqos

@MainActor
final class ChildRevocationTests: XCTestCase {
  private func zoneID(_ name: String) -> CKRecordZone.ID {
    CKRecordZone.ID(zoneName: name, ownerName: "test-owner")
  }

  func testPolicyZoneNameMatchesShippedWireValue() {
    XCTAssertEqual(
      CloudKitConstants.policyZoneName,
      "FamilyPolicies",
      "Live CloudKit data contract; renaming orphans existing shared zones")
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
    XCTAssertTrue(
      CloudKitManager.isConfirmedRevocation(
        isConnected: false,
        isSignedIn: true,
        enforcedMode: .individual,
        currentMode: .child))
  }

  func testGivenDisconnectedIndividualSignalOutsideChildMode_WhenResolvingTrigger_ThenNoRevocation() {
    XCTAssertFalse(
      CloudKitManager.isConfirmedRevocation(
        isConnected: false,
        isSignedIn: true,
        enforcedMode: .individual,
        currentMode: .parent))
    XCTAssertFalse(
      CloudKitManager.isConfirmedRevocation(
        isConnected: false,
        isSignedIn: true,
        enforcedMode: .individual,
        currentMode: .individual))
  }

  func testGivenConnectedIndividualSignalInChildMode_WhenResolvingTrigger_ThenNoRevocation() {
    XCTAssertFalse(
      CloudKitManager.isConfirmedRevocation(
        isConnected: true,
        isSignedIn: true,
        enforcedMode: .individual,
        currentMode: .child))
  }

  func testGivenSignedOutIndividualSignalInChildMode_WhenResolvingTrigger_ThenNoRevocation() {
    XCTAssertFalse(
      CloudKitManager.isConfirmedRevocation(
        isConnected: false,
        isSignedIn: false,
        enforcedMode: .individual,
        currentMode: .child))
  }

  func testGivenForegroundVerifierConfirmsRevocation_WhenHandlingTransition_ThenPublishesDedicatedNoticeAfterCleanup() {
    let manager = CloudKitManager.shared
    let originalRevocationMessage = manager.familyRevocationMessage
    let originalShareMessage = manager.shareAcceptedMessage
    let originalShareError = manager.shareAcceptanceIsError
    defer {
      manager.familyRevocationMessage = originalRevocationMessage
      manager.shareAcceptedMessage = originalShareMessage
      manager.shareAcceptanceIsError = originalShareError
    }

    manager.familyRevocationMessage = nil
    manager.shareAcceptedMessage = "existing share state"
    manager.shareAcceptanceIsError = true
    var didCleanup = false

    manager.handleConfirmedFamilyRevocation {
      XCTAssertNil(manager.familyRevocationMessage)
      didCleanup = true
    }

    XCTAssertTrue(didCleanup)
    XCTAssertEqual(CloudKitManager.familyRevocationAlertTitle, "Family Connection Removed")
    XCTAssertEqual(
      manager.familyRevocationMessage,
      "This device is no longer connected to its Family Foqos family in iCloud, so it switched to Individual mode. To reconnect, ask a parent to send a new invitation."
    )
    XCTAssertEqual(manager.shareAcceptedMessage, "existing share state")
    XCTAssertTrue(manager.shareAcceptanceIsError)

    let message = manager.familyRevocationMessage ?? ""
    XCTAssertTrue(message.contains("iCloud"))
    XCTAssertTrue(message.contains("Individual"))
    XCTAssertTrue(message.contains("new invitation"))
    XCTAssertFalse(message.contains("Screen Time"))
    XCTAssertFalse(message.contains("Family Sharing"))

    manager.dismissFamilyRevocationMessage()
    XCTAssertNil(manager.familyRevocationMessage)
  }
}
