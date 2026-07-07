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
