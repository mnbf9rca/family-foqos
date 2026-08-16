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

  func testGivenPendingRevocationNoticeForCurrentAccount_WhenStoreIsRecreated_ThenStartupMessageIsRestoredUntilCleared() {
    let suiteName = "ChildRevocationTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let accountID = CKRecord.ID(recordName: "current-account")

    let backgroundStore = FamilyRevocationNoticeStore(defaults: defaults)
    backgroundStore.markPending(for: accountID)

    let relaunchedStore = FamilyRevocationNoticeStore(defaults: defaults)
    XCTAssertTrue(relaunchedStore.isPending)
    XCTAssertEqual(
      CloudKitManager.initialFamilyRevocationMessage(
        pendingNoticeStore: relaunchedStore,
        currentUserRecordID: accountID),
      CloudKitManager.familyRevocationAlertMessage)

    relaunchedStore.clearPending()

    let dismissedStore = FamilyRevocationNoticeStore(defaults: defaults)
    XCTAssertFalse(dismissedStore.isPending)
    XCTAssertNil(
      CloudKitManager.initialFamilyRevocationMessage(
        pendingNoticeStore: dismissedStore,
        currentUserRecordID: accountID))
  }

  func testGivenRestoredPendingNoticeForDifferentAccount_WhenResolvingStartupMessage_ThenNoticeIsClearedWithoutSurfacing() {
    let suiteName = "ChildRevocationTests-\(UUID().uuidString)"
    let restoredDefaults = UserDefaults(suiteName: suiteName)!
    defer { restoredDefaults.removePersistentDomain(forName: suiteName) }
    let backedUpAccountID = CKRecord.ID(recordName: "backed-up-account")
    let restoredDeviceAccountID = CKRecord.ID(recordName: "restored-device-account")

    FamilyRevocationNoticeStore(defaults: restoredDefaults).markPending(
      for: backedUpAccountID)

    let restoredStore = FamilyRevocationNoticeStore(defaults: restoredDefaults)
    XCTAssertNil(
      CloudKitManager.initialFamilyRevocationMessage(
        pendingNoticeStore: restoredStore,
        currentUserRecordID: restoredDeviceAccountID))
    XCTAssertFalse(restoredStore.isPending)
  }

  func testGivenMatchingPendingNoticeAfterModeChanged_WhenResolvingStartupMessage_ThenCopyDoesNotClaimIndividualMode() {
    let suiteName = "ChildRevocationTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let accountID = CKRecord.ID(recordName: "current-account")
    let store = FamilyRevocationNoticeStore(defaults: defaults)
    store.markPending(for: accountID)

    let message = CloudKitManager.initialFamilyRevocationMessage(
      pendingNoticeStore: store,
      currentUserRecordID: accountID)

    XCTAssertNotNil(message)
    XCTAssertFalse(message?.contains("Individual") == true)
    XCTAssertTrue(message?.contains("new invitation") == true)
  }

  func testGivenPendingRevocationNotice_WhenShareAcceptanceCompletes_ThenNextLaunchHasNoRevocationAlert() {
    let suiteName = "ChildRevocationTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let accountID = CKRecord.ID(recordName: "current-account")
    let store = FamilyRevocationNoticeStore(defaults: defaults)
    store.markPending(for: accountID)
    let manager = CloudKitManager.makeForTesting(
      pendingNoticeStore: store,
      currentUserRecordID: accountID)
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
      pendingNoticeStore: nextLaunchStore,
      currentUserRecordID: accountID)
    XCTAssertNil(nextLaunchManager.familyRevocationMessage)
  }

  func testGivenPendingRevocationNotice_WhenApplyingAcceptedModeWithDefaultClear_ThenRealManagerClearsIt() {
    let manager = CloudKitManager.shared
    let store = FamilyRevocationNoticeStore()
    let originalRecordID = manager.currentUserRecordID
    let originalMessage = manager.familyRevocationMessage
    defer {
      store.clearPending()
      manager.currentUserRecordID = originalRecordID
      manager.familyRevocationMessage = originalMessage
    }
    let accountID = CKRecord.ID(recordName: "default-clear-account")
    manager.currentUserRecordID = accountID
    store.markPending(for: accountID)
    manager.familyRevocationMessage = CloudKitManager.familyRevocationAlertMessage

    let mode = applyAcceptedFamilyMode(
      role: .child,
      selectMode: { XCTAssertEqual($0, .child) })

    XCTAssertEqual(mode, .child)
    XCTAssertFalse(store.isPending)
    XCTAssertNil(manager.familyRevocationMessage)
  }

  func testGivenPendingRevocationNotice_WhenAccountSwitchStateResets_ThenNoticeIsCleared() {
    let suiteName = "ChildRevocationTests-\(UUID().uuidString)"
    let emergencyDefaults = UserDefaults(suiteName: suiteName)!
    defer { emergencyDefaults.removePersistentDomain(forName: suiteName) }
    let manager = CloudKitManager.shared
    let store = FamilyRevocationNoticeStore()
    let originalRecordID = manager.currentUserRecordID
    let originalMessage = manager.familyRevocationMessage
    defer {
      store.clearPending()
      manager.currentUserRecordID = originalRecordID
      manager.familyRevocationMessage = originalMessage
    }
    let accountID = CKRecord.ID(recordName: "account-before-switch")
    manager.currentUserRecordID = accountID
    store.markPending(for: accountID)
    manager.familyRevocationMessage = CloudKitManager.familyRevocationAlertMessage
    let emergencyManager = EmergencyUnblockManager(defaults: emergencyDefaults)

    emergencyManager.resetAllStateForAccountSwitch()

    XCTAssertFalse(store.isPending)
    XCTAssertNil(manager.familyRevocationMessage)
  }

  func testGivenForegroundVerifierConfirmsRevocation_WhenHandlingTransition_ThenPublishesDedicatedNoticeAfterCleanup() {
    let manager = CloudKitManager.shared
    let originalRevocationMessage = manager.familyRevocationMessage
    let originalShareMessage = manager.shareAcceptedMessage
    let originalShareError = manager.shareAcceptanceIsError
    let originalRecordID = manager.currentUserRecordID
    defer {
      manager.familyRevocationMessage = originalRevocationMessage
      manager.shareAcceptedMessage = originalShareMessage
      manager.shareAcceptanceIsError = originalShareError
      manager.currentUserRecordID = originalRecordID
    }

    let accountID = CKRecord.ID(recordName: "revoked-account")
    manager.currentUserRecordID = accountID
    manager.familyRevocationMessage = nil
    manager.shareAcceptedMessage = "existing share state"
    manager.shareAcceptanceIsError = true
    var steps: [String] = []

    manager.handleConfirmedFamilyRevocation(
      cleanup: {
        XCTAssertNil(manager.familyRevocationMessage)
        steps.append("cleanup")
        manager.currentUserRecordID = nil
      },
      markNoticePending: { persistedAccountID in
        XCTAssertNil(manager.familyRevocationMessage)
        XCTAssertEqual(persistedAccountID, accountID)
        steps.append("persist")
      })

    XCTAssertEqual(steps, ["cleanup", "persist"])
    XCTAssertEqual(CloudKitManager.familyRevocationAlertTitle, "Family Connection Removed")
    XCTAssertEqual(
      manager.familyRevocationMessage,
      "This device is no longer connected to its Family Foqos family in iCloud. To reconnect, ask a parent to send a new invitation."
    )
    XCTAssertEqual(manager.shareAcceptedMessage, "existing share state")
    XCTAssertTrue(manager.shareAcceptanceIsError)

    let message = manager.familyRevocationMessage ?? ""
    XCTAssertTrue(message.contains("iCloud"))
    XCTAssertFalse(message.contains("Individual"))
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
