import XCTest

@testable import FamilyFoqos

@MainActor
final class LockCodeFailClosedTests: XCTestCase {
  private func makeCode() -> FamilyLockCode {
    FamilyLockCode(code: "1234", scope: .allChildren)
  }

  // Connected results are trusted: they replace both the verification cache and the store.
  func testGivenConnectedNonEmptyFetch_WhenResolving_ThenCacheAndStoreUseFetched() {
    let fetched = [makeCode()]
    let result = LockCodeManager.resolveLockCodes(
      fetched: fetched, isConnected: true, persisted: [])
    XCTAssertEqual(result.cache.count, 1)
    XCTAssertEqual(result.persist.count, 1)
  }

  // Connected + empty = parent genuinely cleared the PIN -> cache and store clear (unlock).
  func testGivenConnectedEmptyFetch_WhenResolving_ThenClearsCachedCode() {
    let result = LockCodeManager.resolveLockCodes(
      fetched: [], isConnected: true, persisted: [makeCode()])
    XCTAssertTrue(result.cache.isEmpty)
    XCTAssertTrue(result.persist.isEmpty)
  }

  // Disconnected (offline / CloudKit error) -> ignore the empty network result, verify
  // against the last-synced persisted code. This is the airplane-mode bypass being closed.
  func testGivenOfflineFetch_WhenResolving_ThenVerifiesAgainstLastSyncedCode() {
    let persisted = [makeCode()]
    let result = LockCodeManager.resolveLockCodes(
      fetched: [], isConnected: false, persisted: persisted)
    XCTAssertEqual(result.cache.count, 1, "offline must verify against the last-synced cached code")
    XCTAssertEqual(result.persist.count, 1, "offline must not clear the persisted code")
  }

  // No code ever synced + offline -> nothing to verify (no managed lock exists yet).
  func testGivenNeverSyncedAndOffline_WhenResolving_ThenNoCachedCode() {
    let result = LockCodeManager.resolveLockCodes(
      fetched: [], isConnected: false, persisted: [])
    XCTAssertTrue(result.cache.isEmpty)
  }

  func testGivenRecordFailure_WhenResolvingNetworkFetch_ThenReportsDisconnected() {
    let result = CloudKitNetworkService.resolveSharedLockCodeFetch(
      codes: [], hasRecordFailures: true)
    XCTAssertTrue(result.codes.isEmpty)
    XCTAssertFalse(result.isConnected)
  }

  func testGivenDecodeFailure_WhenResolvingNetworkFetch_ThenReportsDisconnected() {
    let result = CloudKitNetworkService.resolveSharedLockCodeFetch(
      codes: [], hasRecordFailures: true)
    XCTAssertTrue(result.codes.isEmpty)
    XCTAssertFalse(result.isConnected)
  }
}
