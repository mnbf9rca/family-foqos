// FoqosTests/SyncConflictManagerTests.swift
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncConflictManagerTests: XCTestCase {

  func testInitialStateHasNoConflicts() {
    SyncConflictManager.shared.clearAll()
    let manager = SyncConflictManager.shared
    XCTAssertTrue(manager.conflictedProfiles.isEmpty)
    XCTAssertFalse(manager.showConflictBanner)
  }

  func testAddConflictAddsIdAndShowsBanner() {
    SyncConflictManager.shared.clearAll()
    let manager = SyncConflictManager.shared
    let profileId = UUID()

    manager.addConflict(profileId: profileId, profileName: "Test")

    XCTAssertNotNil(manager.conflictedProfiles[profileId])
    XCTAssertTrue(manager.showConflictBanner)
  }

  func testAddMultipleConflicts() {
    SyncConflictManager.shared.clearAll()
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
    SyncConflictManager.shared.clearAll()
    let manager = SyncConflictManager.shared
    let profileId = UUID()

    manager.addConflict(profileId: profileId, profileName: "Test")
    manager.addConflict(profileId: profileId, profileName: "Test")

    XCTAssertEqual(manager.conflictedProfiles.count, 1)
  }

  func testDismissBannerHidesBannerButKeepsConflicts() {
    SyncConflictManager.shared.clearAll()
    let manager = SyncConflictManager.shared
    let profileId = UUID()

    manager.addConflict(profileId: profileId, profileName: "Test")
    manager.dismissBanner()

    XCTAssertFalse(manager.showConflictBanner)
    XCTAssertNotNil(manager.conflictedProfiles[profileId])
  }

  func testClearConflictRemovesSpecificId() {
    SyncConflictManager.shared.clearAll()
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
    SyncConflictManager.shared.clearAll()
    let manager = SyncConflictManager.shared
    let profileId = UUID()

    manager.addConflict(profileId: profileId, profileName: "Test")
    manager.clearConflict(profileId: profileId)

    XCTAssertTrue(manager.conflictedProfiles.isEmpty)
    XCTAssertFalse(manager.showConflictBanner)
  }

  func testClearAllRemovesAllConflictsAndHidesBanner() {
    SyncConflictManager.shared.clearAll()
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
    SyncConflictManager.shared.clearAll()
    let manager = SyncConflictManager.shared
    manager.addConflict(profileId: UUID(), profileName: "Work Focus")

    XCTAssertEqual(
      manager.conflictMessage,
      "\"Work Focus\" was edited on an older app version. Update Foqos on all devices to sync."
    )
  }

  func testConflictMessagePlural() {
    SyncConflictManager.shared.clearAll()
    let manager = SyncConflictManager.shared
    manager.addConflict(profileId: UUID(), profileName: "Work Focus")
    manager.addConflict(profileId: UUID(), profileName: "Study Mode")

    XCTAssertEqual(
      manager.conflictMessage,
      "Several profiles were edited on an older app version. Update Foqos on all devices to sync."
    )
  }
}
