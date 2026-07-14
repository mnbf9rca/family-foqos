import XCTest

@testable import FamilyFoqos

@MainActor
final class EstablishmentGenerationGateTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "establishment-generation-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    suiteName = nil
    super.tearDown()
  }

  private func makeStore(userRecordName: String = "user-A") -> SyncEngineStore {
    SyncEngineStore(userRecordName: userRecordName, defaults: defaults)
  }

  func testGivenNoValue_WhenRead_ThenZero() {
    let store = makeStore()

    XCTAssertEqual(store.establishmentGeneration, 0)
  }

  func testGivenSet_WhenReloaded_ThenPersistsPerUser() {
    makeStore(userRecordName: "user-A").establishmentGeneration = 2

    XCTAssertEqual(makeStore(userRecordName: "user-A").establishmentGeneration, 2)
    XCTAssertEqual(makeStore(userRecordName: "user-B").establishmentGeneration, 0)
  }
}
