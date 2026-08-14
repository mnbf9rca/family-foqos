import CloudKit
import UIKit
import XCTest

@testable import FamilyFoqos

@MainActor
final class ChildSharedRefreshTests: XCTestCase {
  private func makeCode(id: UUID = UUID(), code: String = "1234") -> FamilyLockCode {
    FamilyLockCode(id: id, code: code, scope: .allChildren)
  }

  func testGivenColdBackgroundCommandFetch_WhenResolvingIdentity_ThenFetchesUserRecordID() async throws {
    let expected = CKRecord.ID(recordName: "child")
    var didResolve = false

    let resolved = try await CloudKitManager.resolvePendingCommandUserRecordID(cached: nil) {
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
