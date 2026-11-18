import Darwin
@preconcurrency import FoqosShared
import XCTest

@testable import FamilyFoqos

final class RestrictionApplyCurrentStateTests: XCTestCase {
  private static let testSuiteName = "RestrictionApplyCurrentStateTests-\(UUID().uuidString)"

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
      enableStrictMode: false,
      enableAllowMode: false,
      enableAllowModeDomains: false,
      enableSafariBlocking: false)
  }

  func testAppEffectRunsUnlockedAndRepairsAReplacement() {
    let now = Date()
    let first = snap(UUID())
    let replacement = snap(UUID())
    SharedData.setSnapshot(first, for: first.id.uuidString, now: now)
    SharedData.setSnapshot(replacement, for: replacement.id.uuidString, now: now)
    SharedData.createActiveSharedSession(
      for: .init(
        id: UUID().uuidString, tag: "start", blockedProfileId: first.id, startTime: now, forceStarted: false))
    withSeparateLockDescriptor { descriptor in
      let spy = RecordingRestrictionApplier()
      spy.onActivate = { profile in
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        if profile.id == first.id {
          SharedData.createActiveSharedSession(
            for: .init(
              id: UUID().uuidString, tag: "replacement", blockedProfileId: replacement.id, startTime: now, forceStarted: false))
        }
      }

      _ = SharedData.applyRestrictionsForCurrentState(process: .mainApp, liveSnapshot: first, applier: spy)
      XCTAssertEqual(spy.calls, [.activate(profileId: first.id), .activate(profileId: replacement.id)])
    }
  }

  func testMonitorEffectRepairsSameIdentityGrantChange() {
    let now = Date()
    let profile = snap(UUID())
    SharedData.setSnapshot(profile, for: profile.id.uuidString, now: now)
    let session = SharedData.SessionSnapshot(
      id: UUID().uuidString, tag: "start", blockedProfileId: profile.id, startTime: now, forceStarted: false)
    SharedData.createActiveSharedSession(for: session)
    withSeparateLockDescriptor { descriptor in
      let spy = RecordingRestrictionApplier()
      spy.onActivate = { _ in
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        var granted = session
        granted.breakStartTime = now
        granted.breakEndDeadline = now.addingTimeInterval(300)
        granted.pinnedProfileConfig = profile
        SharedData.createActiveSharedSession(for: granted)
      }

      _ = SharedData.applyRestrictionsForCurrentState(process: .monitorExtension, liveSnapshot: profile, applier: spy)
      XCTAssertEqual(spy.calls, [.activate(profileId: profile.id), .deactivate])
      XCTAssertEqual(SharedData.getActiveSharedSession()?.id, session.id)
    }
  }

  private func withSeparateLockDescriptor(_ verify: (Int32) -> Void) {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("SessionEffect-\(UUID())")
    let descriptor = open(path.path, O_CREAT | O_RDWR, 0o600)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    guard descriptor >= 0 else { return }
    SharedData.configureLockPath(path.path)
    defer {
      SharedData.resetLockPath()
      close(descriptor)
      try? FileManager.default.removeItem(at: path)
    }
    verify(descriptor)
  }

  func testGivenNoSession_WhenMainAppApplies_ThenDeactivates() {
    let spy = RecordingRestrictionApplier()
    let d = SharedData.applyRestrictionsForCurrentState(
      process: .mainApp, liveSnapshot: nil, applier: spy)
    XCTAssertEqual(d, .deactivate)
    XCTAssertEqual(spy.calls, [.deactivate])
  }

  func testGivenNoSession_WhenExtensionApplies_ThenBailPreserve() {
    let spy = RecordingRestrictionApplier()
    let d = SharedData.applyRestrictionsForCurrentState(
      process: .monitorExtension, liveSnapshot: nil, applier: spy)
    XCTAssertEqual(d, .bailPreserve)
    XCTAssertTrue(spy.calls.isEmpty)
  }

  func testGivenEndedButPresent_WhenMainAppApplies_ThenFlushesAndDeactivates() {
    let now = Date()
    let pid = UUID()
    SharedData.createActiveSharedSession(
      for: SharedData.SessionSnapshot(
        id: "s",
        tag: "t",
        blockedProfileId: pid,
        startTime: now.addingTimeInterval(-60),
        endTime: now,
        forceStarted: false))
    let spy = RecordingRestrictionApplier()
    let d = SharedData.applyRestrictionsForCurrentState(
      process: .mainApp, liveSnapshot: nil, applier: spy)
    XCTAssertEqual(d, .deactivate)
    XCTAssertNil(SharedData.getActiveSharedSession())
  }

  func testGivenEndedButPresent_WhenExtensionApplies_ThenBailAndDoesNotFlush() {
    let now = Date()
    SharedData.createActiveSharedSession(
      for: SharedData.SessionSnapshot(
        id: "s",
        tag: "t",
        blockedProfileId: UUID(),
        startTime: now.addingTimeInterval(-60),
        endTime: now,
        forceStarted: false))
    let d = SharedData.applyRestrictionsForCurrentState(
      process: .monitorExtension, liveSnapshot: nil, applier: RecordingRestrictionApplier())
    XCTAssertEqual(d, .bailPreserve)
    XCTAssertNotNil(SharedData.getActiveSharedSession())
  }

  func testGivenSessionNoGrantWithSnapshot_WhenApplies_ThenActivate() {
    let pid = UUID()
    SharedData.createActiveSharedSession(
      for: SharedData.SessionSnapshot(
        id: "s",
        tag: "t",
        blockedProfileId: pid,
        startTime: Date(),
        forceStarted: false))
    let spy = RecordingRestrictionApplier()
    _ = SharedData.applyRestrictionsForCurrentState(
      process: .mainApp, liveSnapshot: snap(pid), applier: spy)
    XCTAssertEqual(spy.calls, [.activate(profileId: pid)])
  }
}
