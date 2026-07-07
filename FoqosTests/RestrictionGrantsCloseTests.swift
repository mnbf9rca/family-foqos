import XCTest

@testable import FamilyFoqos
@testable import FoqosShared

final class RestrictionGrantsCloseTests: XCTestCase {
  private static let testSuiteName = "RestrictionGrantsCloseTests-\(UUID().uuidString)"

  override func setUp() {
    super.setUp()
    SharedData.configure(suite: UserDefaults(suiteName: Self.testSuiteName)!)
  }

  override func tearDown() {
    SharedData.resetLockPath()
    UserDefaults().removePersistentDomain(forName: Self.testSuiteName)
    super.tearDown()
  }

  private func snap(
    _ pid: UUID,
    enableBreaks: Bool = true,
    breakMinutes: Int = 5
  ) -> SharedData.ProfileSnapshot {
    SharedData.ProfileSnapshot(
      id: pid,
      name: "P",
      selectedActivity: .init(),
      createdAt: Date(),
      updatedAt: Date(),
      order: 0,
      enableLiveActivity: false,
      enableBreaks: enableBreaks,
      breakTimeInMinutes: breakMinutes,
      enableStrictMode: false,
      enableAllowMode: false,
      enableAllowModeDomains: false,
      enableSafariBlocking: false)
  }

  @discardableResult
  private func seed(
    breakStart: Date? = nil,
    breakEnd: Date? = nil,
    breakDeadline: Date? = nil,
    omm: Date? = nil,
    ommDeadline: Date? = nil,
    ommUsed: Bool = false,
    pid: UUID = UUID(),
    pinned: SharedData.ProfileSnapshot? = nil
  ) -> (String, UUID) {
    let s = SharedData.SessionSnapshot(
      id: "sess-1",
      tag: "t",
      blockedProfileId: pid,
      startTime: Date(),
      breakStartTime: breakStart,
      breakEndTime: breakEnd,
      forceStarted: false,
      oneMoreMinuteUsed: ommUsed,
      oneMoreMinuteStartTime: omm,
      breakEndDeadline: breakDeadline,
      oneMoreMinuteDeadline: ommDeadline,
      pinnedProfileConfig: pinned)
    SharedData.createActiveSharedSession(for: s)
    return (s.id, pid)
  }

  func testGivenExpiredBreak_WhenClose_ThenClosesOnceAndReblocks() {
    let now = Date()
    let (sid, pid) = seed(
      breakStart: now.addingTimeInterval(-600), breakDeadline: now.addingTimeInterval(-1))
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid,
      explicit: false,
      now: now,
      process: .mainApp,
      durationMinutes: nil,
      liveSnapshot: snap(pid),
      applier: spy)
    XCTAssertTrue(ok)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.breakEndTime, now)
    XCTAssertEqual(spy.calls, [.activate(profileId: pid)])

    let again = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid,
      explicit: false,
      now: now,
      process: .mainApp,
      durationMinutes: nil,
      liveSnapshot: snap(pid),
      applier: RecordingRestrictionApplier())
    XCTAssertFalse(again)
  }

  func testGivenIdentityMismatch_WhenCloseBreak_ThenFalseNoChange() {
    let now = Date()
    let (_, pid) = seed(
      breakStart: now.addingTimeInterval(-600), breakDeadline: now.addingTimeInterval(-1))
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: "stale",
      explicit: false,
      now: now,
      process: .mainApp,
      durationMinutes: nil,
      liveSnapshot: snap(pid),
      applier: spy)
    XCTAssertFalse(ok)
    XCTAssertNil(SharedData.getActiveSharedSession()?.breakEndTime)
    XCTAssertTrue(spy.calls.isEmpty)
  }

  func testGivenUnexpiredBreak_WhenCloseNonExplicit_ThenNoOp() {
    let now = Date()
    let (sid, pid) = seed(
      breakStart: now.addingTimeInterval(-60), breakDeadline: now.addingTimeInterval(240))
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid,
      explicit: false,
      now: now,
      process: .mainApp,
      durationMinutes: nil,
      liveSnapshot: snap(pid),
      applier: spy)
    XCTAssertFalse(ok)
    XCTAssertNil(SharedData.getActiveSharedSession()?.breakEndTime)
    XCTAssertTrue(spy.calls.isEmpty)
  }

  func testGivenUnexpiredBreak_WhenExplicitEarlyEnd_ThenClosesAndReblocks() {
    let now = Date()
    let (sid, pid) = seed(
      breakStart: now.addingTimeInterval(-60), breakDeadline: now.addingTimeInterval(240))
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid,
      explicit: true,
      now: now,
      process: .mainApp,
      durationMinutes: nil,
      liveSnapshot: snap(pid),
      applier: spy)
    XCTAssertTrue(ok)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.breakEndTime, now)
    XCTAssertEqual(spy.calls, [.activate(profileId: pid)])
  }

  func testGivenLegacyNilDeadline_WhenCloseWithDuration_ThenStampsOnceThenGates() {
    let now = Date()
    let (sid, pid) = seed(breakStart: now.addingTimeInterval(-360), breakDeadline: nil)
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid,
      explicit: false,
      now: now,
      process: .mainApp,
      durationMinutes: 5,
      liveSnapshot: snap(pid),
      applier: spy)
    XCTAssertTrue(ok)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.breakEndTime, now)
  }

  func testGivenLegacyNilDeadlineNotYetExpired_WhenClose_ThenStampPersistsAndNoClose() {
    let now = Date()
    let (sid, pid) = seed(breakStart: now.addingTimeInterval(-60), breakDeadline: nil)
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid,
      explicit: false,
      now: now,
      process: .mainApp,
      durationMinutes: 5,
      liveSnapshot: snap(pid),
      applier: RecordingRestrictionApplier())
    XCTAssertFalse(ok)
    let stamped = SharedData.getActiveSharedSession()?.breakEndDeadline
    XCTAssertEqual(stamped, now.addingTimeInterval(-60).addingTimeInterval(300))

    _ = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid,
      explicit: false,
      now: now,
      process: .mainApp,
      durationMinutes: 1,
      liveSnapshot: snap(pid, breakMinutes: 1),
      applier: RecordingRestrictionApplier())
    XCTAssertEqual(SharedData.getActiveSharedSession()?.breakEndDeadline, stamped)
  }

  func testGivenLegacyNilDeadlineUnstampableInExtension_WhenClose_ThenNotExpiredNoClose() {
    let now = Date()
    let (sid, _) = seed(breakStart: now.addingTimeInterval(-3600), breakDeadline: nil)
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid,
      explicit: false,
      now: now,
      process: .monitorExtension,
      durationMinutes: nil,
      liveSnapshot: nil,
      applier: RecordingRestrictionApplier())
    XCTAssertFalse(ok)
    XCTAssertNil(SharedData.getActiveSharedSession()?.breakEndTime)
    XCTAssertNil(SharedData.getActiveSharedSession()?.breakEndDeadline)
  }

  func testGivenEnableBreaksOffMidGrant_WhenExpiredBreakClose_ThenStillClosesNormally() {
    let now = Date()
    let (sid, pid) = seed(
      breakStart: now.addingTimeInterval(-600), breakDeadline: now.addingTimeInterval(-1))
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid,
      explicit: false,
      now: now,
      process: .mainApp,
      durationMinutes: nil,
      liveSnapshot: snap(pid, enableBreaks: false),
      applier: spy)
    XCTAssertTrue(ok)
    XCTAssertEqual(spy.calls, [.activate(profileId: pid)])
  }

  func testGivenExpiredOMM_WhenClose_ThenClearsAndReblocksUsedStaysTrue() {
    let now = Date()
    let (sid, pid) = seed(
      omm: now.addingTimeInterval(-120),
      ommDeadline: now.addingTimeInterval(-60),
      ommUsed: true)
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.closeOneMoreMinuteGrantIfExpired(
      expectedSessionId: sid,
      now: now,
      process: .mainApp,
      liveSnapshot: snap(pid),
      applier: spy)
    XCTAssertTrue(ok)
    XCTAssertNil(SharedData.getActiveSharedSession()?.oneMoreMinuteStartTime)
    XCTAssertTrue(SharedData.getActiveSharedSession()?.oneMoreMinuteUsed ?? false)
    XCTAssertEqual(spy.calls, [.activate(profileId: pid)])
  }

  func testGivenBreakOpen_WhenOMMCloserFires_ThenClearsOMMButDoesNotReblock() {
    let now = Date()
    let (sid, pid) = seed(
      breakStart: now.addingTimeInterval(-30),
      breakDeadline: now.addingTimeInterval(270),
      omm: now.addingTimeInterval(-120),
      ommDeadline: now.addingTimeInterval(-60),
      ommUsed: true)
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.closeOneMoreMinuteGrantIfExpired(
      expectedSessionId: sid,
      now: now,
      process: .mainApp,
      liveSnapshot: snap(pid),
      applier: spy)
    XCTAssertTrue(ok)
    XCTAssertNil(SharedData.getActiveSharedSession()?.oneMoreMinuteStartTime)
    XCTAssertFalse(spy.calls.contains(.activate(profileId: pid)))
  }

  func testGivenAlreadyClosedBreak_WhenClose_ThenNoOp() {
    let now = Date()
    let (sid, pid) = seed(
      breakStart: now.addingTimeInterval(-600),
      breakEnd: now.addingTimeInterval(-5),
      breakDeadline: now.addingTimeInterval(-300))
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid,
      explicit: false,
      now: now,
      process: .mainApp,
      durationMinutes: nil,
      liveSnapshot: snap(pid),
      applier: RecordingRestrictionApplier())
    XCTAssertFalse(ok)
  }

  func testGivenCommitFails_WhenCloseBreak_ThenFalseNoReblock() {
    let now = Date()
    let (sid, pid) = seed(
      breakStart: now.addingTimeInterval(-600), breakDeadline: now.addingTimeInterval(-1))
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid,
      explicit: false,
      now: now,
      process: .mainApp,
      durationMinutes: nil,
      liveSnapshot: snap(pid),
      applier: spy,
      commit: { _ in false })
    XCTAssertFalse(ok)
    XCTAssertTrue(spy.calls.isEmpty)
  }

  func testGivenDegradedLockInExtension_WhenExpiredBreak_ThenStillClosesBestEffort() {
    let now = Date()
    let (sid, pid) = seed(
      breakStart: now.addingTimeInterval(-600),
      breakDeadline: now.addingTimeInterval(-1),
      pinned: snap(UUID()))
    SharedData.configureLockPath(nil)
    let spy = RecordingRestrictionApplier()
    let ok = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: sid,
      explicit: false,
      now: now,
      process: .monitorExtension,
      durationMinutes: nil,
      liveSnapshot: snap(pid),
      applier: spy)
    XCTAssertTrue(ok)
  }
}
