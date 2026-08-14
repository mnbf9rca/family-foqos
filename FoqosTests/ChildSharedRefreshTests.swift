import CloudKit
import UIKit
import XCTest

@testable import FamilyFoqos

@MainActor
final class ChildSharedRefreshTests: XCTestCase {
  private func makeCode(id: UUID = UUID(), code: String = "1234") -> FamilyLockCode {
    FamilyLockCode(id: id, code: code, scope: .allChildren)
  }

  func testGivenTransientAuthorizationFailure_WhenClassifying_ThenResultIsIndeterminate() {
    let networkError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
    let unknownError = NSError(domain: "test", code: 1)

    XCTAssertEqual(
      AuthorizationVerifier.verificationDisposition(for: .networkError(networkError)),
      .indeterminate)
    XCTAssertEqual(
      AuthorizationVerifier.verificationDisposition(for: .unknownError(unknownError)),
      .indeterminate)
  }

  func testGivenFamilyControlsAuthorizationFailure_WhenClassifying_ThenResultIsIndeterminate() {
    XCTAssertEqual(
      AuthorizationVerifier.verificationDisposition(for: .notChildDevice),
      .indeterminate)
    XCTAssertEqual(
      AuthorizationVerifier.verificationDisposition(for: .notAuthorized),
      .indeterminate)
  }

  func testGivenPersistedChildAuthorization_WhenResolvingSharedRefresh_ThenSkipsVerification()
    async
  {
    var didVerify = false

    let result = await LockCodeManager.sharedRefreshAuthorizationResult(
      persisted: .child
    ) {
      didVerify = true
      return .notAuthorized
    }

    XCTAssertFalse(didVerify)
    guard case .authorized = result else {
      return XCTFail("Persisted Child authorization must skip verification")
    }
  }

  func testGivenMissingPersistedAuthorization_WhenResolvingSharedRefresh_ThenVerifiesOnce() async {
    var verificationCount = 0

    let result = await LockCodeManager.sharedRefreshAuthorizationResult(
      persisted: .none
    ) {
      verificationCount += 1
      return .authorized
    }

    XCTAssertEqual(verificationCount, 1)
    guard case .authorized = result else {
      return XCTFail("Successful bootstrap verification must authorize refresh")
    }
  }

  func testGivenConflictDuringBootstrap_WhenRefreshingSharedData_ThenStateAndCacheArePreserved()
    async
  {
    let appModeManager = AppModeManager.shared
    let cloudKitManager = CloudKitManager.shared
    let pendingAcceptance = PendingShareAcceptance.shared
    let originalMode = appModeManager.currentMode
    let originalConnected = cloudKitManager.isConnectedToFamily
    let originalShowConfirmation = pendingAcceptance.showConfirmation
    let originalError = LockCodeManager.shared.error
    let suiteName = "ChildSharedRefreshTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(
      try! JSONEncoder().encode([FamilyLockCode(code: "test-code", scope: .allChildren)]),
      forKey: "family_foqos_child_lock_codes")
    LockCodeManager.shared.overrideDefaults(defaults)
    defer {
      LockCodeManager.shared.overrideDefaults(nil)
      defaults.removePersistentDomain(forName: suiteName)
      appModeManager.selectMode(originalMode)
      cloudKitManager.isConnectedToFamily = originalConnected
      pendingAcceptance.showConfirmation = originalShowConfirmation
      LockCodeManager.shared.error = originalError
    }

    appModeManager.selectMode(.child)
    cloudKitManager.isConnectedToFamily = true
    pendingAcceptance.showConfirmation = false

    let result = await LockCodeManager.shared.refreshSharedLockCodesForVerification(
      authorizationType: .none
    ) {
      .authorizationConflict
    }

    XCTAssertEqual(result, .failed)
    XCTAssertEqual(appModeManager.currentMode, .child)
    XCTAssertTrue(cloudKitManager.isConnectedToFamily)
    XCTAssertTrue(LockCodeManager.shared.canVerifyCode)
    XCTAssertNotNil(defaults.data(forKey: "family_foqos_child_lock_codes"))
    XCTAssertTrue(LockCodeManager.shared.error?.lowercased().contains("try again") == true)
    XCTAssertFalse(pendingAcceptance.showConfirmation)
  }

  func testGivenColdBackgroundCommandFetch_WhenResolvingIdentity_ThenFetchesUserRecordID() async {
    let expected = CKRecord.ID(recordName: "child")
    var didResolve = false

    let resolved = await CloudKitManager.resolvePendingCommandUserRecordID(cached: nil) {
      didResolve = true
      return expected
    }

    XCTAssertTrue(didResolve)
    XCTAssertEqual(resolved, expected)
  }

  func testGivenMissingCommandIdentity_WhenResolvingFetch_ThenReportsDisconnected() {
    let result = CloudKitNetworkService.resolvePendingCommandFetch(
      commands: [],
      hasFailures: false,
      hasUserRecordID: false)

    XCTAssertFalse(result.isConnected)
  }

  func testGivenConnectedChangedLockCodes_WhenClassifying_ThenReportsNewData() {
    XCTAssertEqual(
      LockCodeManager.lockCodeRefreshResult(
        previous: [],
        refreshed: [makeCode()],
        isConnected: true),
      .newData)
  }

  func testGivenConnectedUnchangedLockCodes_WhenClassifying_ThenReportsNoData() {
    let code = makeCode()

    XCTAssertEqual(
      LockCodeManager.lockCodeRefreshResult(
        previous: [code],
        refreshed: [code],
        isConnected: true),
      .noData)
  }

  func testGivenConnectedReorderedLockCodes_WhenClassifying_ThenReportsNoData() {
    let first = makeCode()
    let second = makeCode()

    XCTAssertEqual(
      LockCodeManager.lockCodeRefreshResult(
        previous: [first, second],
        refreshed: [second, first],
        isConnected: true),
      .noData)
  }

  func testGivenDisconnectedLockCodeFetch_WhenClassifying_ThenReportsFailure() {
    XCTAssertEqual(
      LockCodeManager.lockCodeRefreshResult(
        previous: [],
        refreshed: [],
        isConnected: false),
      .failed)
  }

  func testGivenConnectedAppliedCommand_WhenClassifying_ThenReportsNewData() {
    XCTAssertEqual(
      LockCodeManager.commandRefreshResult(
        didApplyCommand: true,
        isConnected: true),
      .newData)
  }

  func testGivenConnectedNoCommand_WhenClassifying_ThenReportsNoData() {
    XCTAssertEqual(
      LockCodeManager.commandRefreshResult(
        didApplyCommand: false,
        isConnected: true),
      .noData)
  }

  func testGivenPartialCommandFetchFailure_WhenClassifying_ThenReportsFailure() {
    XCTAssertEqual(
      LockCodeManager.commandRefreshResult(
        didApplyCommand: true,
        isConnected: false),
      .failed)
  }

  func testGivenCommandDeletionFailure_WhenClassifying_ThenReportsFailure() {
    XCTAssertEqual(
      LockCodeManager.commandRefreshResult(
        didApplyCommand: true,
        isConnected: true,
        hasProcessingFailures: true),
      .failed)
  }

  func testGivenCommandRecordFailure_WhenResolvingFetch_ThenReportsDisconnected() {
    let result = CloudKitNetworkService.resolvePendingCommandFetch(
      commands: [],
      hasFailures: true)

    XCTAssertFalse(result.isConnected)
  }

  func testGivenLockCodesChangedAndNoCommands_WhenCombining_ThenReportsNewData() {
    XCTAssertEqual(
      ChildSharedDataRefreshResult.combine(.newData, .noData),
      .newData)
  }

  func testGivenNoChanges_WhenCombining_ThenReportsNoData() {
    XCTAssertEqual(
      ChildSharedDataRefreshResult.combine(.noData, .noData),
      .noData)
  }

  func testGivenEitherFetchFailed_WhenCombining_ThenReportsFailure() {
    XCTAssertEqual(
      ChildSharedDataRefreshResult.combine(.newData, .failed),
      .failed)
    XCTAssertEqual(
      ChildSharedDataRefreshResult.combine(.failed, .noData),
      .failed)
  }

  func testGivenRefreshOutcome_WhenMappingBackgroundResult_ThenPreservesMeaning() {
    XCTAssertEqual(ChildSharedDataRefreshResult.newData.backgroundFetchResult, .newData)
    XCTAssertEqual(ChildSharedDataRefreshResult.noData.backgroundFetchResult, .noData)
    XCTAssertEqual(ChildSharedDataRefreshResult.failed.backgroundFetchResult, .failed)
  }

  func testGivenSharedDatabasePushInChildMode_WhenRouting_ThenRefreshesSharedData() {
    XCTAssertTrue(
      AppDelegate.shouldRefreshChildSharedData(
        databaseScope: .shared,
        mode: .child))
  }

  func testGivenColdLaunchConfirmedRevocationDuringBackgroundRefresh_WhenRouting_ThenRefreshesAccountAndPublishesNotice()
    async
  {
    let manager = CloudKitManager.shared
    let originalMessage = manager.familyRevocationMessage
    defer { manager.familyRevocationMessage = originalMessage }
    manager.familyRevocationMessage = nil
    var steps: [String] = []
    var didRefreshSharedData = false

    let result = await AppDelegate.refreshChildSharedDataAfterMembershipVerification(
      refreshAccountStatus: {
        steps.append("account")
      },
      verifyMembership: {
        XCTAssertEqual(steps, ["account"])
        steps.append("membership")
        manager.handleConfirmedFamilyRevocation {}
        return true
      },
      refreshSharedData: {
        didRefreshSharedData = true
        return .failed
      })

    XCTAssertEqual(result, .newData)
    XCTAssertEqual(steps, ["account", "membership"])
    XCTAssertFalse(didRefreshSharedData)
    XCTAssertEqual(
      manager.familyRevocationMessage,
      CloudKitManager.familyRevocationAlertMessage)
  }

  func testGivenMembershipUnchangedDuringBackgroundRefresh_WhenRouting_ThenPreservesRefreshResult()
    async
  {
    var steps: [String] = []

    let result = await AppDelegate.refreshChildSharedDataAfterMembershipVerification(
      refreshAccountStatus: {
        steps.append("account")
      },
      verifyMembership: {
        steps.append("membership")
        return false
      },
      refreshSharedData: {
        steps.append("shared-data")
        return .noData
      })

    XCTAssertEqual(steps, ["account", "membership", "shared-data"])
    XCTAssertEqual(result, .noData)
  }

  func testGivenPrivatePushOrNonChildMode_WhenRouting_ThenDoesNotRefreshSharedData() {
    XCTAssertFalse(
      AppDelegate.shouldRefreshChildSharedData(
        databaseScope: .private,
        mode: .child))
    XCTAssertFalse(
      AppDelegate.shouldRefreshChildSharedData(
        databaseScope: .shared,
        mode: .parent))
    XCTAssertFalse(
      AppDelegate.shouldRefreshChildSharedData(
        databaseScope: nil,
        mode: .child))
  }
}
