import FoqosShared
import Foundation
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineStoreIntentTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "SyncEngineStoreIntentTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: UserDefaults(suiteName: "\(suiteName!)-shared")!)
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: suiteName)
    UserDefaults().removePersistentDomain(forName: "\(suiteName!)-shared")
    try await super.tearDown()
  }

  func testGivenProcessedResetIds_WhenMarked_ThenAccumulateAndNeverPrune() {
    let store = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    let id1 = UUID()
    let id2 = UUID()
    XCTAssertTrue(store.processedResetCommandIds.isEmpty)
    store.markProcessed(id1)
    store.markProcessed(id2)
    store.markProcessed(id1)  // idempotent (Set)
    let reloaded = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    XCTAssertEqual(reloaded.processedResetCommandIds, [id1, id2])
  }

  func testGivenLastAppliedAndResetIntent_WhenSet_ThenRoundTrip() {
    let store = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    let cmd = UUID()
    let prior = UUID()
    store.lastAppliedResetCommandId = cmd
    let intent = ResetIntent(id: UUID(), clear: true, stage: .recreating, priorCommandId: prior)
    store.resetIntent = intent
    store.pendingSeedIntent = true

    let reloaded = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    XCTAssertEqual(reloaded.lastAppliedResetCommandId, cmd)
    XCTAssertEqual(reloaded.resetIntent, intent)
    XCTAssertTrue(reloaded.pendingSeedIntent)

    reloaded.resetIntent = nil
    reloaded.lastAppliedResetCommandId = nil
    let cleared = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    XCTAssertNil(cleared.resetIntent)
    XCTAssertNil(cleared.lastAppliedResetCommandId)
  }

  func testGivenTwoUsers_WhenIntentsSet_ThenIsolatedByUserRecordName() {
    let a = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    let b = SyncEngineStore(userRecordName: "userB", defaults: defaults)
    a.markProcessed(UUID())
    a.pendingSeedIntent = true
    a.resetIntent = ResetIntent(id: UUID(), clear: false, stage: .deleting, priorCommandId: nil)
    XCTAssertTrue(b.processedResetCommandIds.isEmpty)
    XCTAssertFalse(b.pendingSeedIntent)
    XCTAssertNil(b.resetIntent)
  }
}
