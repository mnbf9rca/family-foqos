import XCTest

@testable import FoqosShared

final class UninstallProtectionTests: XCTestCase {
  private let suiteName = "UninstallProtectionTests-\(UUID().uuidString)"

  override func setUp() {
    super.setUp()
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
  }

  override func tearDown() {
    SharedData.resetLockPath()
    UserDefaults().removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  private func profile(strict: Bool, now: Date) -> SharedData.ProfileSnapshot {
    SharedData.ProfileSnapshot(
      id: UUID(), name: "P", selectedActivity: .init(), createdAt: now, updatedAt: now,
      order: 0, enableLiveActivity: false, enableBreaks: true, enableStrictMode: strict,
      enableAllowMode: false, enableAllowModeDomains: false, enableSafariBlocking: true)
  }

  func testGivenStrictAndNonStrictProfiles_WhenGrantsOpenAndSessionEnds_ThenRemovalPolicyFollowsPin() throws {
    let now = Date()
    for strict in [true, false] {
      for isBreak in [true, false] {
        let pinned = profile(strict: strict, now: now)
        SharedData.createActiveSharedSession(
          for: .init(
            id: "s", tag: "t", blockedProfileId: pinned.id, startTime: now,
            forceStarted: false))
        let spy = RecordingRestrictionApplier()
        spy.activateRestrictions(for: pinned)
        let open = isBreak ? SharedData.openBreakGrant : SharedData.openOneMoreMinuteGrant
        XCTAssertTrue(open(now, now.addingTimeInterval(60), "s", pinned, spy))
        XCTAssertEqual(spy.calls.last, .deactivate)
        XCTAssertEqual(spy.denyAppRemoval, strict)

        var conflictingLive = pinned
        conflictingLive.enableStrictMode = !strict
        for process: RestrictionProcess in [.mainApp, .monitorExtension] {
          SharedData.reconcileExpiredGrants(
            process: process, now: now, liveSnapshot: conflictingLive,
            breakDurationMinutes: 1, applier: spy)
          XCTAssertEqual(spy.calls.last, .deactivate)
          XCTAssertEqual(spy.denyAppRemoval, strict)
        }

        var ended = try XCTUnwrap(SharedData.getActiveSharedSession())
        ended.endTime = now.addingTimeInterval(1)
        SharedData.createActiveSharedSession(for: ended)
        SharedData.applyRestrictionsForCurrentState(
          process: .mainApp, liveSnapshot: conflictingLive, applier: spy)
        XCTAssertFalse(spy.denyAppRemoval)
        XCTAssertNil(SharedData.getActiveSharedSession())

        spy.activateRestrictions(for: pinned)
        SharedData.applyRestrictionsForCurrentState(
          process: .mainApp, liveSnapshot: pinned, applier: spy)
        XCTAssertFalse(spy.denyAppRemoval)

        // Strategies and timer session ends use the unconditional reset.
        spy.activateRestrictions(for: pinned)
        spy.deactivateRestrictions()
        XCTAssertFalse(spy.denyAppRemoval)
      }
    }
  }

  func testGivenMissingPin_WhenOpenGrantReconcilesWithStrictLiveProfile_ThenDoesNotInventProtection() {
    let now = Date()
    let live = profile(strict: true, now: now)
    SharedData.createActiveSharedSession(
      for: .init(
        id: "s", tag: "t", blockedProfileId: live.id, startTime: now,
        breakStartTime: now, forceStarted: false,
        breakEndDeadline: now.addingTimeInterval(60)))
    let spy = RecordingRestrictionApplier()
    SharedData.applyRestrictionsForCurrentState(
      process: .mainApp, liveSnapshot: live, applier: spy)
    XCTAssertEqual(spy.calls, [.deactivate])
    XCTAssertFalse(spy.denyAppRemoval)
  }

  func testGivenStrictBreakAndOMM_WhenOMMCloses_ThenBreakKeepsRemovalDenied() {
    let now = Date()
    let pinned = profile(strict: true, now: now)
    SharedData.createActiveSharedSession(
      for: .init(
        id: "s", tag: "t", blockedProfileId: pinned.id, startTime: now,
        breakStartTime: now, forceStarted: false, oneMoreMinuteStartTime: now,
        breakEndDeadline: now.addingTimeInterval(300),
        oneMoreMinuteDeadline: now.addingTimeInterval(60), pinnedProfileConfig: pinned))
    let spy = RecordingRestrictionApplier()
    XCTAssertTrue(
      SharedData.closeOneMoreMinuteGrantIfExpired(
        expectedSessionId: "s", now: now, process: .monitorExtension,
        liveSnapshot: nil, applier: spy))
    XCTAssertEqual(spy.calls, [.deactivate])
    XCTAssertTrue(spy.denyAppRemoval)
    XCTAssertNil(SharedData.getActiveSharedSession()?.oneMoreMinuteStartTime)
  }

  func testGivenManagedSettings_WhenStrictBreakOpens_ThenOnlyRemovalProtectionRemains() {
    let now = Date()
    let pinned = profile(strict: true, now: now)
    let applier = AppBlockerUtil()
    defer { applier.deactivateRestrictions() }
    applier.store.shield.applications = []
    applier.store.shield.applicationCategories = .all()
    applier.store.shield.webDomains = []
    applier.store.shield.webDomainCategories = .all()
    applier.store.webContent.blockedByFilter = .all()
    applier.store.application.denyAppRemoval = true
    XCTAssertEqual(applier.store.application.denyAppRemoval, true)
    XCTAssertNotNil(applier.store.shield.applicationCategories)
    XCTAssertNotNil(applier.store.webContent.blockedByFilter)
    SharedData.createActiveSharedSession(
      for: .init(
        id: "s", tag: "t", blockedProfileId: pinned.id, startTime: now,
        forceStarted: false))

    XCTAssertTrue(
      SharedData.openBreakGrant(
        startDate: now, deadline: now.addingTimeInterval(60), expectedSessionId: "s",
        liveSnapshot: pinned, applier: applier))
    XCTAssertNil(applier.store.shield.applications)
    XCTAssertNil(applier.store.shield.applicationCategories)
    XCTAssertNil(applier.store.shield.webDomains)
    XCTAssertNil(applier.store.shield.webDomainCategories)
    XCTAssertNil(applier.store.webContent.blockedByFilter)
    XCTAssertEqual(applier.store.application.denyAppRemoval, true)

    applier.deactivateRestrictions()
    XCTAssertNotEqual(applier.store.application.denyAppRemoval, true)
  }
}
