import XCTest

@testable import FamilyFoqos

@MainActor
final class FamilyCommandApplyTests: XCTestCase {

  override func setUp() {
    super.setUp()
    MainActor.assumeIsolated {
      let defaults = UserDefaults(suiteName: "FamilyCommandApplyTests")!
      defaults.removePersistentDomain(forName: "FamilyCommandApplyTests")
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

  func testGivenLockedOutChild_WhenResetThrottleCommandApplied_ThenThrottleCleared() {
    let now = Date()
    for _ in 0..<10 {
      LockCodeManager.shared.recordFailedAttempt(now: now)
    }
    XCTAssertTrue(LockCodeManager.shared.isLockedOut(now: now))

    let command = FamilyCommand(
      commandType: .resetLockCodeThrottle,
      targetChildId: "child-rec-1",
      createdBy: "parent-rec-1"
    )
    LockCodeManager.shared.applyCommand(command)

    XCTAssertEqual(LockCodeManager.shared.failedAttempts, 0)
    XCTAssertFalse(LockCodeManager.shared.isLockedOut(now: now))
  }
}
