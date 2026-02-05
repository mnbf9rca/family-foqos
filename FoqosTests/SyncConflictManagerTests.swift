// FoqosTests/SyncConflictManagerTests.swift
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncConflictManagerTests: XCTestCase {

  func testInitialStateHasNoConflicts() {
    SyncConflictManager.shared.clearAll()
    let manager = SyncConflictManager.shared
    XCTAssertTrue(manager.conflictedProfileIds.isEmpty)
    XCTAssertFalse(manager.showConflictBanner)
  }

  func testAddConflictAddsIdAndShowsBanner() {
    SyncConflictManager.shared.clearAll()
    let manager = SyncConflictManager.shared
    let profileId = UUID()

    manager.addConflict(profileId: profileId)

    XCTAssertTrue(manager.conflictedProfileIds.contains(profileId))
    XCTAssertTrue(manager.showConflictBanner)
  }

  func testAddMultipleConflicts() {
    SyncConflictManager.shared.clearAll()
    let manager = SyncConflictManager.shared
    let id1 = UUID()
    let id2 = UUID()

    manager.addConflict(profileId: id1)
    manager.addConflict(profileId: id2)

    XCTAssertEqual(manager.conflictedProfileIds.count, 2)
    XCTAssertTrue(manager.conflictedProfileIds.contains(id1))
    XCTAssertTrue(manager.conflictedProfileIds.contains(id2))
    XCTAssertTrue(manager.showConflictBanner)
  }

  func testAddSameConflictTwiceDoesNotDuplicate() {
    SyncConflictManager.shared.clearAll()
    let manager = SyncConflictManager.shared
    let profileId = UUID()

    manager.addConflict(profileId: profileId)
    manager.addConflict(profileId: profileId)

    XCTAssertEqual(manager.conflictedProfileIds.count, 1)
  }

  func testDismissBannerHidesBannerButKeepsConflicts() {
    SyncConflictManager.shared.clearAll()
    let manager = SyncConflictManager.shared
    let profileId = UUID()

    manager.addConflict(profileId: profileId)
    manager.dismissBanner()

    XCTAssertFalse(manager.showConflictBanner)
    XCTAssertTrue(manager.conflictedProfileIds.contains(profileId))
  }

  func testClearConflictRemovesSpecificId() {
    SyncConflictManager.shared.clearAll()
    let manager = SyncConflictManager.shared
    let id1 = UUID()
    let id2 = UUID()

    manager.addConflict(profileId: id1)
    manager.addConflict(profileId: id2)
    manager.clearConflict(profileId: id1)

    XCTAssertFalse(manager.conflictedProfileIds.contains(id1))
    XCTAssertTrue(manager.conflictedProfileIds.contains(id2))
    XCTAssertTrue(manager.showConflictBanner)
  }

  func testClearLastConflictHidesBanner() {
    SyncConflictManager.shared.clearAll()
    let manager = SyncConflictManager.shared
    let profileId = UUID()

    manager.addConflict(profileId: profileId)
    manager.clearConflict(profileId: profileId)

    XCTAssertTrue(manager.conflictedProfileIds.isEmpty)
    XCTAssertFalse(manager.showConflictBanner)
  }

  func testClearAllRemovesAllConflictsAndHidesBanner() {
    SyncConflictManager.shared.clearAll()
    let manager = SyncConflictManager.shared
    let id1 = UUID()
    let id2 = UUID()

    manager.addConflict(profileId: id1)
    manager.addConflict(profileId: id2)
    manager.clearAll()

    XCTAssertTrue(manager.conflictedProfileIds.isEmpty)
    XCTAssertFalse(manager.showConflictBanner)
  }

  func testConflictMessageSingular() {
    SyncConflictManager.shared.clearAll()
    let manager = SyncConflictManager.shared
    manager.addConflict(profileId: UUID())

    XCTAssertEqual(manager.conflictMessage, "A profile was edited on an older app version.")
  }

  func testConflictMessagePlural() {
    SyncConflictManager.shared.clearAll()
    let manager = SyncConflictManager.shared
    manager.addConflict(profileId: UUID())
    manager.addConflict(profileId: UUID())

    XCTAssertEqual(manager.conflictMessage, "Several profiles were edited on an older app version.")
  }
}
