import Foundation
import XCTest

@testable import FamilyFoqos

@MainActor
final class RemotelyActiveProfilesTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "RemotelyActiveProfilesTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func testGivenRemoteActiveState_WhenSet_ThenPersistsAndClears() {
    let profileId = UUID()
    let manager = StrategyManager(remoteActiveDefaults: defaults)

    manager.setRemoteSessionActive(true, profileId: profileId)

    XCTAssertTrue(manager.remotelyActiveProfileIds.contains(profileId))
    XCTAssertTrue(
      StrategyManager(remoteActiveDefaults: defaults).remotelyActiveProfileIds.contains(profileId),
      "#311: active-anywhere locks must survive relaunch")

    manager.setRemoteSessionActive(false, profileId: profileId)

    XCTAssertFalse(manager.remotelyActiveProfileIds.contains(profileId))
    XCTAssertFalse(
      StrategyManager(remoteActiveDefaults: defaults).remotelyActiveProfileIds.contains(profileId))
  }

  func testGivenRemoteActiveIds_WhenClearAll_ThenSetEmptyAndPersistsEmpty() {
    let idA = UUID()
    let idB = UUID()
    let manager = StrategyManager(remoteActiveDefaults: defaults)
    manager.setRemoteSessionActive(true, profileId: idA)
    manager.setRemoteSessionActive(true, profileId: idB)

    manager.clearAllRemoteSessionActive()

    XCTAssertTrue(manager.remotelyActiveProfileIds.isEmpty)
    XCTAssertTrue(RemotelyActiveStore.load(defaults: defaults).isEmpty)
  }

  func testGivenTwoRemoteActiveIds_WhenClearingOne_ThenOtherRemains() {
    let idA = UUID()
    let idB = UUID()
    let manager = StrategyManager(remoteActiveDefaults: defaults)
    manager.setRemoteSessionActive(true, profileId: idA)
    manager.setRemoteSessionActive(true, profileId: idB)

    manager.setRemoteSessionActive(false, profileId: idA)

    XCTAssertEqual(manager.remotelyActiveProfileIds, [idB])
    XCTAssertEqual(RemotelyActiveStore.load(defaults: defaults), [idB])
  }
}
