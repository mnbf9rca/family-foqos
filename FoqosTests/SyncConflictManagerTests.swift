import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncConflictManagerTests: XCTestCase {

  func testGivenFreshManager_WhenCheckingState_ThenNoConflicts() {
    let manager = SyncConflictManager()
    XCTAssertTrue(manager.conflictedProfiles.isEmpty)
    XCTAssertFalse(manager.showConflictBanner)
  }

  func testGivenNoConflicts_WhenAddingConflict_ThenShowsBanner() {
    let manager = SyncConflictManager()
    let profileId = UUID()

    manager.addConflict(profileId: profileId, profileName: "Test")

    XCTAssertNotNil(manager.conflictedProfiles[profileId])
    XCTAssertTrue(manager.showConflictBanner)
  }

  func testGivenNoConflicts_WhenAddingMultiple_ThenAllTracked() {
    let manager = SyncConflictManager()
    let id1 = UUID()
    let id2 = UUID()

    manager.addConflict(profileId: id1, profileName: "Profile 1")
    manager.addConflict(profileId: id2, profileName: "Profile 2")

    XCTAssertEqual(manager.conflictedProfiles.count, 2)
    XCTAssertNotNil(manager.conflictedProfiles[id1])
    XCTAssertNotNil(manager.conflictedProfiles[id2])
    XCTAssertTrue(manager.showConflictBanner)
  }

  func testGivenExistingConflict_WhenAddingSameConflict_ThenNoDuplicate() {
    let manager = SyncConflictManager()
    let profileId = UUID()

    manager.addConflict(profileId: profileId, profileName: "Test")
    manager.addConflict(profileId: profileId, profileName: "Test")

    XCTAssertEqual(manager.conflictedProfiles.count, 1)
  }

  func testGivenVisibleBanner_WhenDismissing_ThenBannerHiddenButConflictsRemain() {
    let manager = SyncConflictManager()
    let profileId = UUID()

    manager.addConflict(profileId: profileId, profileName: "Test")
    manager.dismissBanner()

    XCTAssertFalse(manager.showConflictBanner)
    XCTAssertNotNil(manager.conflictedProfiles[profileId])
  }

  func testGivenMultipleConflicts_WhenClearingOne_ThenOnlyThatOneRemoved() {
    let manager = SyncConflictManager()
    let id1 = UUID()
    let id2 = UUID()

    manager.addConflict(profileId: id1, profileName: "Profile 1")
    manager.addConflict(profileId: id2, profileName: "Profile 2")
    manager.clearConflict(profileId: id1)

    XCTAssertNil(manager.conflictedProfiles[id1])
    XCTAssertNotNil(manager.conflictedProfiles[id2])
    XCTAssertTrue(manager.showConflictBanner)
  }

  func testGivenSingleConflict_WhenClearing_ThenBannerHidden() {
    let manager = SyncConflictManager()
    let profileId = UUID()

    manager.addConflict(profileId: profileId, profileName: "Test")
    manager.clearConflict(profileId: profileId)

    XCTAssertTrue(manager.conflictedProfiles.isEmpty)
    XCTAssertFalse(manager.showConflictBanner)
  }

  func testGivenMultipleConflicts_WhenClearingAll_ThenEmptyAndBannerHidden() {
    let manager = SyncConflictManager()
    let id1 = UUID()
    let id2 = UUID()

    manager.addConflict(profileId: id1, profileName: "Profile 1")
    manager.addConflict(profileId: id2, profileName: "Profile 2")
    manager.clearAll()

    XCTAssertTrue(manager.conflictedProfiles.isEmpty)
    XCTAssertFalse(manager.showConflictBanner)
  }

  func testGivenOneConflict_WhenGettingMessage_ThenIncludesProfileName() {
    let manager = SyncConflictManager()
    manager.addConflict(profileId: UUID(), profileName: "Work Focus")

    XCTAssertEqual(
      manager.conflictMessage,
      "\"Work Focus\" was edited on an older app version. Update Foqos on all devices to sync."
    )
  }

  func testGivenMultipleConflicts_WhenGettingMessage_ThenUsesPlural() {
    let manager = SyncConflictManager()
    manager.addConflict(profileId: UUID(), profileName: "Work Focus")
    manager.addConflict(profileId: UUID(), profileName: "Study Mode")

    XCTAssertEqual(
      manager.conflictMessage,
      "Several profiles were edited on an older app version. Update Foqos on all devices to sync."
    )
  }

  // MARK: - Newer Version Conflict Tests

  func testGivenNoConflicts_WhenAddingNewerVersionConflict_ThenShowsBanner() {
    let manager = SyncConflictManager()
    let profileId = UUID()

    manager.addNewerVersionConflict(profileId: profileId, profileName: "Test")

    XCTAssertNotNil(manager.newerVersionProfiles[profileId])
    XCTAssertTrue(manager.showConflictBanner)
  }

  func testGivenBothConflictTypes_WhenChecking_ThenTrackedSeparately() {
    let manager = SyncConflictManager()
    let olderId = UUID()
    let newerId = UUID()

    manager.addConflict(profileId: olderId, profileName: "Old Device")
    manager.addNewerVersionConflict(profileId: newerId, profileName: "New Device")

    XCTAssertEqual(manager.conflictedProfiles.count, 1)
    XCTAssertEqual(manager.newerVersionProfiles.count, 1)
  }

  func testGivenOneNewerVersionConflict_WhenGettingMessage_ThenIncludesProfileName() {
    let manager = SyncConflictManager()
    manager.addNewerVersionConflict(profileId: UUID(), profileName: "Work Focus")

    XCTAssertEqual(
      manager.newerVersionMessage,
      "\"Work Focus\" was updated on a newer version of Foqos. Update this device to continue syncing."
    )
  }

  func testGivenMultipleNewerVersionConflicts_WhenGettingMessage_ThenUsesPlural() {
    let manager = SyncConflictManager()
    manager.addNewerVersionConflict(profileId: UUID(), profileName: "Work Focus")
    manager.addNewerVersionConflict(profileId: UUID(), profileName: "Study Mode")

    XCTAssertEqual(
      manager.newerVersionMessage,
      "Some profiles were updated on a newer version of Foqos. Update this device to continue syncing."
    )
  }

  func testGivenNewerVersionConflict_WhenClearing_ThenRemovedAndBannerHidden() {
    let manager = SyncConflictManager()
    let profileId = UUID()

    manager.addNewerVersionConflict(profileId: profileId, profileName: "Test")
    manager.clearConflict(profileId: profileId)

    XCTAssertTrue(manager.newerVersionProfiles.isEmpty)
    XCTAssertFalse(manager.showConflictBanner)
  }

  func testGivenBothConflictTypes_WhenClearingAll_ThenAllRemovedAndBannerHidden() {
    let manager = SyncConflictManager()
    manager.addConflict(profileId: UUID(), profileName: "A")
    manager.addNewerVersionConflict(profileId: UUID(), profileName: "B")
    manager.clearAll()

    XCTAssertTrue(manager.conflictedProfiles.isEmpty)
    XCTAssertTrue(manager.newerVersionProfiles.isEmpty)
    XCTAssertFalse(manager.showConflictBanner)
  }

  func testGivenBothConflictTypes_WhenClearingOlderOnly_ThenBannerStays() {
    let manager = SyncConflictManager()
    let olderId = UUID()
    let newerId = UUID()

    manager.addConflict(profileId: olderId, profileName: "Old")
    manager.addNewerVersionConflict(profileId: newerId, profileName: "New")
    manager.clearConflict(profileId: olderId)

    XCTAssertTrue(manager.showConflictBanner)
    XCTAssertNotNil(manager.newerVersionProfiles[newerId])
  }

  // MARK: - Computed Banner Visibility Tests

  func testGivenNewerVersionConflicts_WhenCheckingBannerVisibility_ThenShowsNewerOnly() {
    let manager = SyncConflictManager()
    manager.addNewerVersionConflict(profileId: UUID(), profileName: "New Version")

    XCTAssertTrue(manager.shouldShowNewerVersionBanner)
    XCTAssertFalse(manager.shouldShowOlderDeviceBanner)
  }

  func testGivenOlderDeviceConflicts_WhenCheckingBannerVisibility_ThenShowsOlderOnly() {
    let manager = SyncConflictManager()
    manager.addConflict(profileId: UUID(), profileName: "Old Device")

    XCTAssertTrue(manager.shouldShowOlderDeviceBanner)
    XCTAssertFalse(manager.shouldShowNewerVersionBanner)
  }

  func testGivenBothConflictTypes_WhenBannerDismissed_ThenBothComputedPropertiesFalse() {
    let manager = SyncConflictManager()
    manager.addConflict(profileId: UUID(), profileName: "Old Device")
    manager.addNewerVersionConflict(profileId: UUID(), profileName: "New Version")
    manager.dismissBanner()

    XCTAssertFalse(manager.shouldShowNewerVersionBanner)
    XCTAssertFalse(manager.shouldShowOlderDeviceBanner)
  }

  func testGivenBothConflictTypes_WhenBannerVisible_ThenBothComputedPropertiesTrue() {
    let manager = SyncConflictManager()
    manager.addConflict(profileId: UUID(), profileName: "Old Device")
    manager.addNewerVersionConflict(profileId: UUID(), profileName: "New Version")

    XCTAssertTrue(manager.shouldShowNewerVersionBanner)
    XCTAssertTrue(manager.shouldShowOlderDeviceBanner)
  }

  // MARK: - Reset Superseded Tests

  func testGivenFreshManager_WhenAddingResetSupersededConflict_ThenFlagFlipsTrueAndShowsBanner() {
    let manager = SyncConflictManager()

    manager.addResetSupersededConflict()

    XCTAssertTrue(manager.resetWasSuperseded)
    XCTAssertTrue(manager.showConflictBanner)
  }

  func testGivenResetSuperseded_WhenDismissingBanner_ThenFlagClears() {
    let manager = SyncConflictManager()
    manager.addResetSupersededConflict()

    manager.dismissBanner()

    XCTAssertFalse(manager.resetWasSuperseded)
    XCTAssertFalse(manager.showConflictBanner)
  }

  func testGivenResetSuperseded_WhenClearingAll_ThenFlagClears() {
    let manager = SyncConflictManager()
    manager.addResetSupersededConflict()

    manager.clearAll()

    XCTAssertFalse(manager.resetWasSuperseded)
    XCTAssertFalse(manager.showConflictBanner)
  }
}
