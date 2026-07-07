@preconcurrency import FoqosShared
import XCTest

@testable import FamilyFoqos

final class RestrictionApplyingConformanceTests: XCTestCase {
  func testGivenAppBlockerUtil_WhenUsedAsRestrictionApplying_ThenConforms() {
    let applier: RestrictionApplying = AppBlockerUtil()
    XCTAssertNotNil(applier)
  }

  func testGivenSpy_WhenActivateThenDeactivate_ThenRecordsOrderedCalls() {
    let spy = RecordingRestrictionApplier()
    let pid = UUID()
    let snap = SharedData.ProfileSnapshot(
      id: pid,
      name: "P",
      selectedActivity: .init(),
      createdAt: Date(),
      updatedAt: Date(),
      order: 0,
      enableLiveActivity: false,
      enableBreaks: false,
      enableStrictMode: false,
      enableAllowMode: false,
      enableAllowModeDomains: false,
      enableSafariBlocking: false)
    spy.activateRestrictions(for: snap)
    spy.deactivateRestrictions()
    XCTAssertEqual(spy.calls, [.activate(profileId: pid), .deactivate])
  }
}
