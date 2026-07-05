import FoqosShared
import Foundation
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineStoreStateTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "SyncEngineStoreStateTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: UserDefaults(suiteName: "\(suiteName!)-shared")!)
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: suiteName)
    UserDefaults().removePersistentDomain(forName: "\(suiteName!)-shared")
    try await super.tearDown()
  }

  func testGivenEngineState_WhenSetAndReloaded_ThenPersistsAndClears() {
    let store = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    XCTAssertNil(store.engineState)
    let data = Data([0xAB, 0xCD])
    store.engineState = data
    let reloaded = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    XCTAssertEqual(reloaded.engineState, data)
    reloaded.engineState = nil
    XCTAssertNil(SyncEngineStore(userRecordName: "userA", defaults: defaults).engineState)
  }

  func testGivenSystemFields_WhenStoredPerRecord_ThenRoundTripAndPurge() {
    let store = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    let p1 = Data([0x01])
    let p2 = Data([0x02])
    store.setSystemFields(p1, for: "profile-1")
    store.setSystemFields(p2, for: "profile-2")
    XCTAssertEqual(store.systemFields(for: "profile-1"), p1)
    XCTAssertEqual(store.systemFields(for: "profile-2"), p2)
    store.setSystemFields(nil, for: "profile-1")
    XCTAssertNil(store.systemFields(for: "profile-1"))
    XCTAssertEqual(store.systemFields(for: "profile-2"), p2)
    // I6: zone events purge the whole cache
    store.purgeAllSystemFields()
    let reloaded = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    XCTAssertNil(reloaded.systemFields(for: "profile-2"))
  }

  func testGivenTwoUsers_WhenSystemFieldsStored_ThenIsolatedByUserRecordName() {
    let a = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    let b = SyncEngineStore(userRecordName: "userB", defaults: defaults)
    a.setSystemFields(Data([0xAA]), for: "shared-record")
    b.setSystemFields(Data([0xBB]), for: "shared-record")
    XCTAssertEqual(a.systemFields(for: "shared-record"), Data([0xAA]))
    XCTAssertEqual(b.systemFields(for: "shared-record"), Data([0xBB]))
    a.purgeAllSystemFields()
    XCTAssertNil(a.systemFields(for: "shared-record"))
    XCTAssertEqual(b.systemFields(for: "shared-record"), Data([0xBB]))
  }
}
