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

  func testGivenPendingRevocationNotice_WhenStoreIsRecreated_ThenStartupMessageIsRestoredUntilCleared() {
    let suiteName = "ChildRevocationTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let backgroundStore = FamilyRevocationNoticeStore(defaults: defaults)
    backgroundStore.markPending()

    let relaunchedStore = FamilyRevocationNoticeStore(defaults: defaults)
    XCTAssertTrue(relaunchedStore.isPending)
    XCTAssertEqual(
      CloudKitManager.initialFamilyRevocationMessage(pendingNoticeStore: relaunchedStore),
      CloudKitManager.familyRevocationAlertMessage)

    relaunchedStore.clearPending()

    let dismissedStore = FamilyRevocationNoticeStore(defaults: defaults)
    XCTAssertFalse(dismissedStore.isPending)
    XCTAssertNil(
      CloudKitManager.initialFamilyRevocationMessage(pendingNoticeStore: dismissedStore))
  }

  func testGivenPendingRevocationNotice_WhenShareAcceptanceCompletes_ThenNextLaunchHasNoRevocationAlert() {
    let suiteName = "ChildRevocationTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = FamilyRevocationNoticeStore(defaults: defaults)
    store.markPending()
    let manager = CloudKitManager.makeForTesting(pendingNoticeStore: store)
    XCTAssertEqual(
      manager.familyRevocationMessage,
      CloudKitManager.familyRevocationAlertMessage)
    var steps: [String] = []

    let mode = applyAcceptedFamilyMode(
      role: .child,
      selectMode: {
        XCTAssertEqual($0, .child)
        steps.append("mode")
      },
      clearFamilyRevocationNotice: {
        manager.dismissFamilyRevocationMessage()
        steps.append("clear")
      })

    XCTAssertEqual(mode, .child)
    XCTAssertEqual(steps, ["mode", "clear"])
    XCTAssertNil(manager.familyRevocationMessage)
    let nextLaunchStore = FamilyRevocationNoticeStore(defaults: defaults)
    let nextLaunchManager = CloudKitManager.makeForTesting(
      pendingNoticeStore: nextLaunchStore)
    XCTAssertNil(nextLaunchManager.familyRevocationMessage)
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
    var steps: [String] = []

    manager.handleConfirmedFamilyRevocation(
      cleanup: {
        XCTAssertNil(manager.familyRevocationMessage)
        steps.append("cleanup")
      },
      markNoticePending: {
        XCTAssertNil(manager.familyRevocationMessage)
        steps.append("persist")
      })

    XCTAssertEqual(steps, ["cleanup", "persist"])
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

    manager.dismissFamilyRevocationMessage {
      XCTAssertNotNil(manager.familyRevocationMessage)
      steps.append("clear")
    }
    XCTAssertNil(manager.familyRevocationMessage)
    XCTAssertEqual(steps, ["cleanup", "persist", "clear"])
  }
}
