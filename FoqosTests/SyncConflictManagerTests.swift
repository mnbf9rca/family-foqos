// FoqosTests/SyncConflictManagerTests.swift
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncConflictManagerTests: XCTestCase {

  override func setUp() {
    super.setUp()
    MainActor.assumeIsolated {
      SyncConflictManager.shared.clearAll()
    }
  }

  func testInitialStateHasNoConflicts() {
    let manager = SyncConflictManager.shared
    XCTAssertTrue(manager.conflictedProfiles.isEmpty)
    XCTAssertFalse(manager.showConflictBanner)
  }

  func testAddConflictAddsIdAndShowsBanner() {
    let manager = SyncConflictManager.shared
    let profileId = UUID()

    manager.addConflict(profileId: profileId, profileName: "Test")

    XCTAssertNotNil(manager.conflictedProfiles[profileId])
    XCTAssertTrue(manager.showConflictBanner)
  }

  func testAddMultipleConflicts() {
    let manager = SyncConflictManager.shared
    let id1 = UUID()
    let id2 = UUID()

    manager.addConflict(profileId: id1, profileName: "Profile 1")
    manager.addConflict(profileId: id2, profileName: "Profile 2")

    XCTAssertEqual(manager.conflictedProfiles.count, 2)
    XCTAssertNotNil(manager.conflictedProfiles[id1])
    XCTAssertNotNil(manager.conflictedProfiles[id2])
    XCTAssertTrue(manager.showConflictBanner)
  }

  func testAddSameConflictTwiceDoesNotDuplicate() {
    let manager = SyncConflictManager.shared
    let profileId = UUID()

    manager.addConflict(profileId: profileId, profileName: "Test")
    manager.addConflict(profileId: profileId, profileName: "Test")

    XCTAssertEqual(manager.conflictedProfiles.count, 1)
  }

  func testDismissBannerHidesBannerButKeepsConflicts() {
    let manager = SyncConflictManager.shared
    let profileId = UUID()

    manager.addConflict(profileId: profileId, profileName: "Test")
    manager.dismissBanner()

    XCTAssertFalse(manager.showConflictBanner)
    XCTAssertNotNil(manager.conflictedProfiles[profileId])
  }

  func testClearConflictRemovesSpecificId() {
    let manager = SyncConflictManager.shared
    let id1 = UUID()
    let id2 = UUID()

    manager.addConflict(profileId: id1, profileName: "Profile 1")
    manager.addConflict(profileId: id2, profileName: "Profile 2")
    manager.clearConflict(profileId: id1)

    XCTAssertNil(manager.conflictedProfiles[id1])
    XCTAssertNotNil(manager.conflictedProfiles[id2])
    XCTAssertTrue(manager.showConflictBanner)
  }

  func testClearLastConflictHidesBanner() {
    let manager = SyncConflictManager.shared
    let profileId = UUID()

    manager.addConflict(profileId: profileId, profileName: "Test")
    manager.clearConflict(profileId: profileId)

    XCTAssertTrue(manager.conflictedProfiles.isEmpty)
    XCTAssertFalse(manager.showConflictBanner)
  }

  func testClearAllRemovesAllConflictsAndHidesBanner() {
    let manager = SyncConflictManager.shared
    let id1 = UUID()
    let id2 = UUID()

    manager.addConflict(profileId: id1, profileName: "Profile 1")
    manager.addConflict(profileId: id2, profileName: "Profile 2")
    manager.clearAll()

    XCTAssertTrue(manager.conflictedProfiles.isEmpty)
    XCTAssertFalse(manager.showConflictBanner)
  }

  func testConflictMessageSingularIncludesProfileName() {
    let manager = SyncConflictManager.shared
    manager.addConflict(profileId: UUID(), profileName: "Work Focus")

    XCTAssertEqual(
      manager.conflictMessage,
      "\"Work Focus\" was edited on an older app version. Update Foqos on all devices to sync."
    )
  }

  func testConflictMessagePlural() {
    let manager = SyncConflictManager.shared
    manager.addConflict(profileId: UUID(), profileName: "Work Focus")
    manager.addConflict(profileId: UUID(), profileName: "Study Mode")

    XCTAssertEqual(
      manager.conflictMessage,
      "Several profiles were edited on an older app version. Update Foqos on all devices to sync."
    )
  }

  // MARK: - Newer Version Conflict Tests

  func testAddNewerVersionConflictShowsBanner() {
    let manager = SyncConflictManager.shared
    let profileId = UUID()

    manager.addNewerVersionConflict(profileId: profileId, profileName: "Test")

    XCTAssertNotNil(manager.newerVersionProfiles[profileId])
    XCTAssertTrue(manager.showConflictBanner)
  }

  func testNewerVersionConflictTrackedSeparately() {
    let manager = SyncConflictManager.shared
    let olderId = UUID()
    let newerId = UUID()

    manager.addConflict(profileId: olderId, profileName: "Old Device")
    manager.addNewerVersionConflict(profileId: newerId, profileName: "New Device")

    XCTAssertEqual(manager.conflictedProfiles.count, 1)
    XCTAssertEqual(manager.newerVersionProfiles.count, 1)
  }

  func testNewerVersionMessageSingular() {
    let manager = SyncConflictManager.shared
    manager.addNewerVersionConflict(profileId: UUID(), profileName: "Work Focus")

    XCTAssertEqual(
      manager.newerVersionMessage,
      "\"Work Focus\" was updated on a newer version of Foqos. Update this device to continue syncing."
    )
  }

  func testNewerVersionMessagePlural() {
    let manager = SyncConflictManager.shared
    manager.addNewerVersionConflict(profileId: UUID(), profileName: "Work Focus")
    manager.addNewerVersionConflict(profileId: UUID(), profileName: "Study Mode")

    XCTAssertEqual(
      manager.newerVersionMessage,
      "Some profiles were updated on a newer version of Foqos. Update this device to continue syncing."
    )
  }

  func testClearConflictClearsNewerVersion() {
    let manager = SyncConflictManager.shared
    let profileId = UUID()

    manager.addNewerVersionConflict(profileId: profileId, profileName: "Test")
    manager.clearConflict(profileId: profileId)

    XCTAssertTrue(manager.newerVersionProfiles.isEmpty)
    XCTAssertFalse(manager.showConflictBanner)
  }

  func testClearAllClearsNewerVersionConflicts() {
    let manager = SyncConflictManager.shared
    manager.addConflict(profileId: UUID(), profileName: "A")
    manager.addNewerVersionConflict(profileId: UUID(), profileName: "B")
    manager.clearAll()

    XCTAssertTrue(manager.conflictedProfiles.isEmpty)
    XCTAssertTrue(manager.newerVersionProfiles.isEmpty)
    XCTAssertFalse(manager.showConflictBanner)
  }

  func testBannerStaysWhenOnlyNewerVersionConflictsRemain() {
    let manager = SyncConflictManager.shared
    let olderId = UUID()
    let newerId = UUID()

    manager.addConflict(profileId: olderId, profileName: "Old")
    manager.addNewerVersionConflict(profileId: newerId, profileName: "New")
    manager.clearConflict(profileId: olderId)

    XCTAssertTrue(manager.showConflictBanner)
    XCTAssertNotNil(manager.newerVersionProfiles[newerId])
  }

  // MARK: - Computed Banner Visibility Tests

  func testShouldShowNewerVersionBannerWhenConflictsExist() {
    let manager = SyncConflictManager.shared
    manager.addNewerVersionConflict(profileId: UUID(), profileName: "New Version")

    XCTAssertTrue(manager.shouldShowNewerVersionBanner)
    XCTAssertFalse(manager.shouldShowOlderDeviceBanner)
  }

  func testShouldShowOlderDeviceBannerWhenConflictsExist() {
    let manager = SyncConflictManager.shared
    manager.addConflict(profileId: UUID(), profileName: "Old Device")

    XCTAssertTrue(manager.shouldShowOlderDeviceBanner)
    XCTAssertFalse(manager.shouldShowNewerVersionBanner)
  }

  func testComputedPropertiesFalseWhenBannerDismissed() {
    let manager = SyncConflictManager.shared
    manager.addConflict(profileId: UUID(), profileName: "Old Device")
    manager.addNewerVersionConflict(profileId: UUID(), profileName: "New Version")
    manager.dismissBanner()

    XCTAssertFalse(manager.shouldShowNewerVersionBanner)
    XCTAssertFalse(manager.shouldShowOlderDeviceBanner)
  }

  func testBothComputedPropertiesTrueWhenBothConflictTypesExist() {
    let manager = SyncConflictManager.shared
    manager.addConflict(profileId: UUID(), profileName: "Old Device")
    manager.addNewerVersionConflict(profileId: UUID(), profileName: "New Version")

    XCTAssertTrue(manager.shouldShowNewerVersionBanner)
    XCTAssertTrue(manager.shouldShowOlderDeviceBanner)
  }
}
