import Darwin
import XCTest

@testable import FamilyFoqos
@testable import FoqosShared

final class SharedDataC2SeamTests: XCTestCase {
  private static let testSuiteName = "SharedDataC2SeamTests-\(UUID().uuidString)"

  override func setUp() {
    super.setUp()
    SharedData.configure(suite: UserDefaults(suiteName: Self.testSuiteName)!)
  }

  override func tearDown() {
    SharedData.resetLockPath()
    UserDefaults().removePersistentDomain(forName: Self.testSuiteName)
    super.tearDown()
  }

  private func session(_ id: String) -> SharedData.SessionSnapshot {
    SharedData.SessionSnapshot(
      id: id,
      tag: "t",
      blockedProfileId: UUID(),
      startTime: Date(),
      forceStarted: false)
  }

  private enum Boom: Error {
    case boom
  }

  func testGivenEncodeFails_WhenRawCommit_ThenStorageUntouchedAndReturnsFalse() {
    SharedData.createActiveSharedSession(for: session("original"))
    let ok = SharedData.rawCommitActiveSession(
      session("replacement"),
      encode: { _ in
        throw Boom.boom
      })
    XCTAssertFalse(ok)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, "original")
  }

  func testGivenEncodeSucceeds_WhenRawCommit_ThenStorageUpdatedReturnsTrue() {
    SharedData.createActiveSharedSession(for: session("original"))
    let ok = SharedData.rawCommitActiveSession(session("replacement"))
    XCTAssertTrue(ok)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, "replacement")
  }

  func testGivenNilLockPath_WhenWithLockStatus_ThenReportsDegraded() {
    SharedData.configureLockPath(nil)
    let outcome = SharedData.withLockStatus(blocking: true) { $0 }
    XCTAssertEqual(outcome, .degraded)
  }

  func testGivenNormalLockPath_WhenWithLockStatus_ThenReportsAcquired() {
    let outcome = SharedData.withLockStatus(blocking: true) { $0 }
    XCTAssertEqual(outcome, .acquired)
  }

  func testGivenHeldLock_WhenNonBlockingAcquire_ThenDegradesWithinBoundedCeiling() {
    let path = NSTemporaryDirectory() + "c2-lock-\(UUID().uuidString)"
    SharedData.configureLockPath(path)
    let holder = open(path, O_CREAT | O_RDWR, 0o644)
    XCTAssertGreaterThanOrEqual(holder, 0)
    XCTAssertEqual(flock(holder, LOCK_EX), 0)
    let start = Date()
    let outcome = SharedData.withLockStatus(blocking: false) { $0 }
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertEqual(outcome, .degraded)
    XCTAssertLessThan(elapsed, 2.0)
    flock(holder, LOCK_UN)
    close(holder)
  }
}
