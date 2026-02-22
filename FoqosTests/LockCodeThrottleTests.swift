import XCTest

@testable import FamilyFoqos

@MainActor
final class LockCodeThrottleTests: XCTestCase {

  override func setUp() {
    super.setUp()
    MainActor.assumeIsolated {
      let defaults = UserDefaults(suiteName: "LockCodeThrottleTests")!
      defaults.removePersistentDomain(forName: "LockCodeThrottleTests")
      LockCodeManager.shared.overrideDefaults(defaults)
      LockCodeManager.shared.resetThrottle()
    }
  }

  override func tearDown() {
    MainActor.assumeIsolated {
      LockCodeManager.shared.resetThrottle()
      LockCodeManager.shared.overrideDefaults(nil)
    }
    super.tearDown()
  }

  // MARK: - Throttle schedule

  func testGivenNoFailures_WhenCheckingLockout_ThenNotLockedOut() {
    XCTAssertFalse(LockCodeManager.shared.isLockedOut)
    XCTAssertEqual(LockCodeManager.shared.failedAttempts, 0)
  }

  func testGivenTwoFailures_WhenCheckingLockout_ThenNotLockedOut() {
    let now = Date()
    LockCodeManager.shared.recordFailedAttempt(now: now)
    LockCodeManager.shared.recordFailedAttempt(now: now)

    XCTAssertEqual(LockCodeManager.shared.failedAttempts, 2)
    XCTAssertFalse(LockCodeManager.shared.isLockedOut(now: now))
  }

  func testGivenThreeFailures_WhenCheckingLockout_ThenLockedOut30Seconds() {
    let now = Date()
    for _ in 0..<3 {
      LockCodeManager.shared.recordFailedAttempt(now: now)
    }

    XCTAssertTrue(LockCodeManager.shared.isLockedOut(now: now))
    // Should expire after 30 seconds
    let after30 = now.addingTimeInterval(31)
    XCTAssertFalse(LockCodeManager.shared.isLockedOut(now: after30))
  }

  func testGivenFiveFailures_WhenCheckingLockout_ThenLockedOut2Minutes() {
    let now = Date()
    for _ in 0..<5 {
      LockCodeManager.shared.recordFailedAttempt(now: now)
    }

    XCTAssertTrue(LockCodeManager.shared.isLockedOut(now: now))
    // Still locked after 30 seconds
    let after30 = now.addingTimeInterval(31)
    XCTAssertTrue(LockCodeManager.shared.isLockedOut(now: after30))
    // Unlocked after 2 minutes
    let after2min = now.addingTimeInterval(121)
    XCTAssertFalse(LockCodeManager.shared.isLockedOut(now: after2min))
  }

  func testGivenSevenFailures_WhenCheckingLockout_ThenLockedOut5Minutes() {
    let now = Date()
    for _ in 0..<7 {
      LockCodeManager.shared.recordFailedAttempt(now: now)
    }

    let after2min = now.addingTimeInterval(121)
    XCTAssertTrue(LockCodeManager.shared.isLockedOut(now: after2min))
    let after5min = now.addingTimeInterval(301)
    XCTAssertFalse(LockCodeManager.shared.isLockedOut(now: after5min))
  }

  func testGivenTenFailures_WhenCheckingLockout_ThenLockedOut15Minutes() {
    let now = Date()
    for _ in 0..<10 {
      LockCodeManager.shared.recordFailedAttempt(now: now)
    }

    let after5min = now.addingTimeInterval(301)
    XCTAssertTrue(LockCodeManager.shared.isLockedOut(now: after5min))
    let after15min = now.addingTimeInterval(901)
    XCTAssertFalse(LockCodeManager.shared.isLockedOut(now: after15min))
  }

  // MARK: - Reset

  func testGivenFailures_WhenReset_ThenCounterAndLockoutCleared() {
    let now = Date()
    for _ in 0..<5 {
      LockCodeManager.shared.recordFailedAttempt(now: now)
    }
    XCTAssertTrue(LockCodeManager.shared.isLockedOut(now: now))

    LockCodeManager.shared.resetThrottle()

    XCTAssertEqual(LockCodeManager.shared.failedAttempts, 0)
    XCTAssertFalse(LockCodeManager.shared.isLockedOut(now: now))
  }

  // MARK: - Remaining time

  func testGivenLockout_WhenCheckingRemaining_ThenReturnsCorrectInterval() {
    let now = Date()
    for _ in 0..<3 {
      LockCodeManager.shared.recordFailedAttempt(now: now)
    }

    let remaining = LockCodeManager.shared.lockoutRemaining(now: now)
    XCTAssertGreaterThan(remaining, 29)
    XCTAssertLessThanOrEqual(remaining, 30)
  }

  func testGivenNoLockout_WhenCheckingRemaining_ThenReturnsZero() {
    XCTAssertEqual(LockCodeManager.shared.lockoutRemaining(now: Date()), 0)
  }

  // MARK: - Persistence

  func testGivenFailures_WhenReadingFromDefaults_ThenStateRestored() {
    let now = Date()
    for _ in 0..<3 {
      LockCodeManager.shared.recordFailedAttempt(now: now)
    }

    // Simulate reading from persisted state
    LockCodeManager.shared.loadThrottleState()

    XCTAssertEqual(LockCodeManager.shared.failedAttempts, 3)
    XCTAssertTrue(LockCodeManager.shared.isLockedOut(now: now))
  }
}
