import DeviceActivity
@preconcurrency import FoqosShared
import XCTest

@testable import FamilyFoqos

final class C2BackstopRoutingTests: XCTestCase {
  private static let testSuiteName = "C2BackstopRoutingTests-\(UUID().uuidString)"

  override func setUp() {
    super.setUp()
    SharedData.configure(suite: UserDefaults(suiteName: Self.testSuiteName)!)
  }

  override func tearDown() {
    UserDefaults().removePersistentDomain(forName: Self.testSuiteName)
    super.tearDown()
  }

  private func snap(_ pid: UUID) -> SharedData.ProfileSnapshot {
    SharedData.ProfileSnapshot(
      id: pid,
      name: "P",
      selectedActivity: .init(),
      createdAt: Date(),
      updatedAt: Date(),
      order: 0,
      enableLiveActivity: false,
      enableBreaks: true,
      breakTimeInMinutes: 5,
      enableStrictMode: false,
      enableAllowMode: false,
      enableAllowModeDomains: false,
      enableSafariBlocking: false)
  }

  private func seedExpiredBreak(pid: UUID) {
    let now = Date()
    SharedData.setSnapshot(snap(pid), for: pid.uuidString)
    SharedData.createActiveSharedSession(
      for: SharedData.SessionSnapshot(
        id: "sess",
        tag: "t",
        blockedProfileId: pid,
        startTime: now.addingTimeInterval(-600),
        breakStartTime: now.addingTimeInterval(-600),
        forceStarted: false,
        breakEndDeadline: now.addingTimeInterval(-1),
        pinnedProfileConfig: snap(pid)))
  }

  func testGivenExpiredBreak_WhenC2BackstopNameRouted_ThenGrantClosed() {
    let pid = UUID()
    seedExpiredBreak(pid: pid)
    TimerActivityUtil.stopTimerActivity(
      for: DeviceActivityName(rawValue: "\(BreakDeadlineBackstopActivity.id):\(pid.uuidString)"))
    XCTAssertNotNil(SharedData.getActiveSharedSession()?.breakEndTime)
  }

  func testGivenExpiredBreak_WhenLegacyNameRouted_ThenAlsoClosesGrant() {
    let pid = UUID()
    seedExpiredBreak(pid: pid)
    TimerActivityUtil.stopTimerActivity(
      for: DeviceActivityName(rawValue: "\(BreakTimerActivity.id):\(pid.uuidString)"))
    XCTAssertNotNil(SharedData.getActiveSharedSession()?.breakEndTime)
  }

  func testGivenC2Ids_WhenResolved_ThenAreDistinctFromLegacy() {
    XCTAssertEqual(BreakDeadlineBackstopActivity.id, "BreakDeadlineBackstop")
    XCTAssertEqual(OneMoreMinuteDeadlineBackstopActivity.id, "OneMoreMinuteDeadlineBackstop")
    XCTAssertNotEqual(BreakDeadlineBackstopActivity.id, BreakTimerActivity.id)
  }
}
