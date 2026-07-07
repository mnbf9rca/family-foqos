@preconcurrency import FoqosShared
import XCTest

@testable import FamilyFoqos

final class HealExpiredLiftsTests: XCTestCase {
  private static let testSuiteName = "HealExpiredLiftsTests-\(UUID().uuidString)"

  override func setUp() {
    super.setUp()
    SharedData.configure(suite: UserDefaults(suiteName: Self.testSuiteName)!)
  }

  override func tearDown() {
    UserDefaults().removePersistentDomain(forName: Self.testSuiteName)
    super.tearDown()
  }

  private func snap(_ pid: UUID, breakMinutes: Int = 5) -> SharedData.ProfileSnapshot {
    SharedData.ProfileSnapshot(
      id: pid,
      name: "P",
      selectedActivity: .init(),
      createdAt: Date(),
      updatedAt: Date(),
      order: 0,
      enableLiveActivity: false,
      enableBreaks: true,
      breakTimeInMinutes: breakMinutes,
      enableStrictMode: false,
      enableAllowMode: false,
      enableAllowModeDomains: false,
      enableSafariBlocking: false)
  }

  @discardableResult
  private func seed(
    _ build: (inout SharedData.SessionSnapshot) -> Void,
    pid: UUID = UUID()
  ) -> (String, UUID) {
    var s = SharedData.SessionSnapshot(
      id: "s",
      tag: "t",
      blockedProfileId: pid,
      startTime: Date(),
      forceStarted: false)
    build(&s)
    SharedData.createActiveSharedSession(for: s)
    return (s.id, pid)
  }

  func testGivenExpiredBreak_WhenReconcile_ThenClosesAndReblocks() {
    let now = Date()
    let (_, pid) = seed {
      $0.breakStartTime = now.addingTimeInterval(-600)
      $0.breakEndDeadline = now.addingTimeInterval(-1)
    }
    let spy = RecordingRestrictionApplier()
    SharedData.reconcileExpiredGrants(
      process: .mainApp,
      now: now,
      liveSnapshot: snap(pid),
      breakDurationMinutes: 5,
      applier: spy)
    XCTAssertNotNil(SharedData.getActiveSharedSession()?.breakEndTime)
    XCTAssertTrue(spy.calls.contains(.activate(profileId: pid)))
  }

  func testGivenExpiredOMM_WhenReconcile_ThenClosesAndReblocks() {
    let now = Date()
    let (_, pid) = seed {
      $0.oneMoreMinuteStartTime = now.addingTimeInterval(-120)
      $0.oneMoreMinuteDeadline = now.addingTimeInterval(-60)
      $0.oneMoreMinuteUsed = true
    }
    let spy = RecordingRestrictionApplier()
    SharedData.reconcileExpiredGrants(
      process: .mainApp,
      now: now,
      liveSnapshot: snap(pid),
      breakDurationMinutes: 5,
      applier: spy)
    XCTAssertNil(SharedData.getActiveSharedSession()?.oneMoreMinuteStartTime)
    XCTAssertTrue(spy.calls.contains(.activate(profileId: pid)))
  }

  func testGivenExpiredOMMDuringBreak_WhenReconcile_ThenClosesOMMFieldsOnlyNoReblock() {
    let now = Date()
    let (_, pid) = seed {
      $0.breakStartTime = now.addingTimeInterval(-30)
      $0.breakEndDeadline = now.addingTimeInterval(270)
      $0.oneMoreMinuteStartTime = now.addingTimeInterval(-120)
      $0.oneMoreMinuteDeadline = now.addingTimeInterval(-60)
      $0.oneMoreMinuteUsed = true
    }
    let spy = RecordingRestrictionApplier()
    SharedData.reconcileExpiredGrants(
      process: .mainApp,
      now: now,
      liveSnapshot: snap(pid),
      breakDurationMinutes: 5,
      applier: spy)
    XCTAssertNil(SharedData.getActiveSharedSession()?.oneMoreMinuteStartTime)
    XCTAssertFalse(spy.calls.contains(.activate(profileId: pid)))
  }

  func testGivenOpenUnexpiredGrant_WhenReconcile_ThenConvergesOff() {
    let now = Date()
    let (_, pid) = seed {
      $0.breakStartTime = now.addingTimeInterval(-30)
      $0.breakEndDeadline = now.addingTimeInterval(270)
    }
    let spy = RecordingRestrictionApplier()
    SharedData.reconcileExpiredGrants(
      process: .mainApp,
      now: now,
      liveSnapshot: snap(pid),
      breakDurationMinutes: 5,
      applier: spy)
    XCTAssertNil(SharedData.getActiveSharedSession()?.breakEndTime)
    XCTAssertEqual(spy.calls.last, .deactivate)
  }

  func testGivenClosedGrantRestrictionsOff_WhenReconcile_ThenConvergesOn() {
    let now = Date()
    let (_, pid) = seed {
      $0.breakStartTime = now.addingTimeInterval(-600)
      $0.breakEndTime = now.addingTimeInterval(-5)
    }
    let spy = RecordingRestrictionApplier()
    SharedData.reconcileExpiredGrants(
      process: .mainApp,
      now: now,
      liveSnapshot: snap(pid),
      breakDurationMinutes: 5,
      applier: spy)
    XCTAssertEqual(spy.calls.last, .activate(profileId: pid))
  }

  func testGivenNoSession_WhenExtensionReconcile_ThenBailPreserve() {
    let spy = RecordingRestrictionApplier()
    SharedData.reconcileExpiredGrants(
      process: .monitorExtension,
      now: Date(),
      liveSnapshot: nil,
      breakDurationMinutes: nil,
      applier: spy)
    XCTAssertTrue(spy.calls.isEmpty)
  }

  func testGivenExpiredBreakMissingLiveButPinned_WhenExtensionReconcile_ThenReblocksFromPin() {
    let now = Date()
    let pid = UUID()
    let pinned = snap(pid)
    seed(
      {
        $0.breakStartTime = now.addingTimeInterval(-600)
        $0.breakEndDeadline = now.addingTimeInterval(-1)
        $0.pinnedProfileConfig = pinned
      },
      pid: pid)
    let spy = RecordingRestrictionApplier()
    SharedData.reconcileExpiredGrants(
      process: .monitorExtension,
      now: now,
      liveSnapshot: nil,
      breakDurationMinutes: nil,
      applier: spy)
    XCTAssertTrue(spy.calls.contains(.activate(profileId: pid)))
  }

  func testGivenLegacyOpenBreakNoDeadlineNoPin_WhenCompleteMigration_ThenStampsAndPins() {
    let now = Date()
    let pid = UUID()
    let pinned = snap(pid)
    seed({ $0.breakStartTime = now.addingTimeInterval(-60) }, pid: pid)
    let changed = SharedData.completeGrantMigration(
      expectedSessionId: "s", breakDurationMinutes: 5, pinned: pinned, now: now)
    XCTAssertTrue(changed)
    let s = SharedData.getActiveSharedSession()
    XCTAssertEqual(s?.breakEndDeadline, now.addingTimeInterval(-60).addingTimeInterval(300))
    XCTAssertEqual(s?.pinnedProfileConfig?.id, pid)
  }

  func testGivenXAlreadyStampedDeadlineButNoPin_WhenCompleteMigration_ThenStillPins() {
    let now = Date()
    let pid = UUID()
    let pinned = snap(pid)
    seed(
      {
        $0.breakStartTime = now.addingTimeInterval(-60)
        $0.breakEndDeadline = now.addingTimeInterval(240)
      },
      pid: pid)
    let changed = SharedData.completeGrantMigration(
      expectedSessionId: "s", breakDurationMinutes: 5, pinned: pinned, now: now)
    XCTAssertTrue(changed)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.pinnedProfileConfig?.id, pid)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.breakEndDeadline, now.addingTimeInterval(240))
  }

  func testGivenFullyMigratedGrant_WhenCompleteMigration_ThenNoChange() {
    let now = Date()
    let pid = UUID()
    let pinned = snap(pid)
    seed(
      {
        $0.breakStartTime = now.addingTimeInterval(-60)
        $0.breakEndDeadline = now.addingTimeInterval(240)
        $0.pinnedProfileConfig = pinned
      },
      pid: pid)
    XCTAssertFalse(
      SharedData.completeGrantMigration(
        expectedSessionId: "s", breakDurationMinutes: 5, pinned: pinned, now: now))
  }
}
