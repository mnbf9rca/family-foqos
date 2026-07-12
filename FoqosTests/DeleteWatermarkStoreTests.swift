import FoqosShared
import Foundation
import XCTest

@testable import FamilyFoqos

@MainActor
final class DeleteWatermarkStoreTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "DeleteWatermarkStoreTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: UserDefaults(suiteName: "\(suiteName!)-shared")!)
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: suiteName)
    UserDefaults().removePersistentDomain(forName: "\(suiteName!)-shared")
    try await super.tearDown()
  }

  private func makeStore() -> SyncEngineStore {
    SyncEngineStore(userRecordName: "userA", defaults: defaults)
  }

  func testGivenWatermarkSet_WhenRead_ThenReturnsValueUntilCleared() {
    let store = makeStore()
    store.setDeleteWatermark(recordName: "p1", value: 5)
    XCTAssertEqual(store.deleteWatermark(for: "p1"), 5)
    store.clearDeleteWatermark(recordName: "p1")
    XCTAssertNil(store.deleteWatermark(for: "p1"))
  }

  func testGivenWatermarkReset_WhenSetAgain_ThenOverwrites() {
    let store = makeStore()
    store.setDeleteWatermark(recordName: "p1", value: 5)
    store.setDeleteWatermark(recordName: "p1", value: 7)
    XCTAssertEqual(store.deleteWatermark(for: "p1"), 7)
  }

  func testGivenMoreThanCap_WhenSet_ThenOldestEvicted() {
    let store = makeStore()
    let cap = SyncEngineStore.maxDeleteWatermarkEntries
    for index in 0...cap {
      store.setDeleteWatermark(recordName: "r\(index)", value: Double(index))
    }
    XCTAssertNil(store.deleteWatermark(for: "r0"), "oldest evicted past the FIFO cap")
    XCTAssertEqual(store.deleteWatermark(for: "r\(cap)"), Double(cap))
  }
}
