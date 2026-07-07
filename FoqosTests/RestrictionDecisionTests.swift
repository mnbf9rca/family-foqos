@preconcurrency import FoqosShared
import XCTest

@testable import FamilyFoqos

final class RestrictionDecisionTests: XCTestCase {
  private func session(
    id: String = "s",
    pid: UUID = UUID(),
    endTime: Date? = nil,
    breakStart: Date? = nil,
    breakEnd: Date? = nil,
    omm: Date? = nil,
    pinned: SharedData.ProfileSnapshot? = nil
  ) -> SharedData.SessionSnapshot {
    SharedData.SessionSnapshot(
      id: id,
      tag: "t",
      blockedProfileId: pid,
      startTime: Date(),
      endTime: endTime,
      breakStartTime: breakStart,
      breakEndTime: breakEnd,
      forceStarted: false,
      oneMoreMinuteStartTime: omm,
      pinnedProfileConfig: pinned)
  }

  private func snapshot(_ pid: UUID) -> SharedData.ProfileSnapshot {
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

  func testGivenNoSession_WhenDerivingPerProcess_ThenMainDeactivatesExtensionBails() {
    XCTAssertEqual(
      SharedData.deriveRestriction(session: nil, liveSnapshot: nil, process: .mainApp),
      .deactivate)
    XCTAssertEqual(
      SharedData.deriveRestriction(session: nil, liveSnapshot: nil, process: .monitorExtension),
      .bailPreserve)
  }

  func testGivenOpenBreak_WhenDeriving_ThenBothProcessesDeactivate() {
    let now = Date()
    let s = session(breakStart: now)
    XCTAssertEqual(
      SharedData.deriveRestriction(session: s, liveSnapshot: nil, process: .mainApp),
      .deactivate)
    XCTAssertEqual(
      SharedData.deriveRestriction(session: s, liveSnapshot: nil, process: .monitorExtension),
      .deactivate)
  }

  func testGivenOpenOMM_WhenDeriving_ThenBothProcessesDeactivate() {
    let s = session(omm: Date())
    XCTAssertEqual(
      SharedData.deriveRestriction(session: s, liveSnapshot: nil, process: .mainApp),
      .deactivate)
    XCTAssertEqual(
      SharedData.deriveRestriction(session: s, liveSnapshot: nil, process: .monitorExtension),
      .deactivate)
  }

  func testGivenNoGrantWithLiveSnapshot_WhenDeriving_ThenActivateWithLive() {
    let pid = UUID()
    let s = session(pid: pid)
    let live = snapshot(pid)
    XCTAssertEqual(
      SharedData.deriveRestriction(session: s, liveSnapshot: live, process: .mainApp),
      .activate(live))
    XCTAssertEqual(
      SharedData.deriveRestriction(session: s, liveSnapshot: live, process: .monitorExtension),
      .activate(live))
  }

  func testGivenNoGrantNoLiveNoPin_WhenDeriving_ThenBailPreserveBothProcesses() {
    let s = session()
    XCTAssertEqual(
      SharedData.deriveRestriction(session: s, liveSnapshot: nil, process: .mainApp),
      .bailPreserve)
    XCTAssertEqual(
      SharedData.deriveRestriction(session: s, liveSnapshot: nil, process: .monitorExtension),
      .bailPreserve)
  }

  func testGivenNoGrantNoLiveButPinned_WhenDeriving_ThenActivateWithPinned() {
    let pid = UUID()
    let pinned = snapshot(pid)
    let s = session(pid: pid, pinned: pinned)
    XCTAssertEqual(
      SharedData.deriveRestriction(session: s, liveSnapshot: nil, process: .mainApp),
      .activate(pinned))
  }

  func testGivenLiveAndPinnedBothPresent_WhenDeriving_ThenLiveWins() {
    let pid = UUID()
    let live = snapshot(pid)
    var pinned = snapshot(pid)
    pinned.name = "Pinned"
    let s = session(pid: pid, pinned: pinned)
    XCTAssertEqual(
      SharedData.deriveRestriction(session: s, liveSnapshot: live, process: .mainApp),
      .activate(live))
  }

  func testGivenEndedButPresentSession_WhenDeriving_ThenTreatedAsNoSession() {
    let s = session(endTime: Date(), breakStart: nil)
    XCTAssertEqual(
      SharedData.deriveRestriction(session: s, liveSnapshot: nil, process: .mainApp),
      .deactivate)
    XCTAssertEqual(
      SharedData.deriveRestriction(session: s, liveSnapshot: nil, process: .monitorExtension),
      .bailPreserve)
  }
}
