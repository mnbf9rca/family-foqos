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

  func testGivenMoreThanWarningThreshold_WhenSet_ThenOldestRetained() {
    let store = makeStore()
    let threshold = SyncEngineStore.deleteWatermarkWarningThreshold
    for index in 0...threshold {
      store.setDeleteWatermark(recordName: "r\(index)", value: Double(index))
    }
    XCTAssertEqual(store.deleteWatermark(for: "r0"), 0, "oldest retained past the warning threshold")
    XCTAssertEqual(store.deleteWatermark(for: "r\(threshold)"), Double(threshold))
  }
}
