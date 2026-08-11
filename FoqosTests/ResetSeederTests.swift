import Foundation
import XCTest

@testable import FamilyFoqos

@MainActor
final class ResetSeederTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: SyncEngineStore!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "reset-seeder-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
    store = SyncEngineStore(userRecordName: "user-A", defaults: defaults)
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    try await super.tearDown()
  }

  func testGivenSeeder_WhenPerformI6Purge_ThenPurgesSystemFieldsAndFlushesSessionCache() async {
    store.setSystemFields(Data([0x01]), for: "profile-1")
    XCTAssertNotNil(store.systemFields(for: "profile-1"))

    var flushCount = 0
    var seedCount = 0
    let seeder = DefaultResetSeeder(
      store: store,
      flush: { flushCount += 1 },
      seed: { seedCount += 1 },
      clearSelections: {}
    )

    await seeder.performI6Purge()

    XCTAssertNil(store.systemFields(for: "profile-1"), "I6 must purge systemFields")
    XCTAssertEqual(flushCount, 1, "I6 must flush the session cache")
    XCTAssertEqual(seedCount, 0, "purge must not seed")
  }

  func testGivenSeeder_WhenSeedAll_ThenSeedClosureInvoked() {
    var seedCount = 0
    let seeder = DefaultResetSeeder(
      store: store,
      flush: {},
      seed: { seedCount += 1 },
      clearSelections: {}
    )

    seeder.seedAll()

    XCTAssertEqual(seedCount, 1, "seedAll must invoke the seed closure")
  }

  func testGivenSeeder_WhenClearAllProfileSelections_ThenClearSelectionsClosureInvoked() throws {
    var clearCount = 0
    let seeder = DefaultResetSeeder(
      store: store,
      flush: {},
      seed: {},
      clearSelections: { clearCount += 1 }
    )

    try seeder.clearAllProfileSelections()

    XCTAssertEqual(clearCount, 1, "clearAllProfileSelections must invoke the clearSelections closure")
  }

  /// S-20 wiring: `SessionSyncCacheFlusher` (the `@MainActor` adapter over the
  /// `SessionSyncService` actor — see `SessionSyncService+Flushing.swift` for why a direct
  /// actor conformance to the `@MainActor` `SessionSyncFlushing` protocol does not compile)
  /// must satisfy `SessionSyncFlushing` so the controller can flush it via the seam with no
  /// hard singleton dependency. `clearCache()` itself is a synchronous local-dictionary
  /// clear with no CloudKit I/O, so this is safe to drive against the real singleton. The
  /// behavioral fetch-caches/flush/re-fetch-fresh path (create-if-absent after a zone
  /// recreation) is covered end-to-end via the `MockSessionSyncService.simulateZoneRecreated()`
  /// seam in
  /// `SessionStopOnAbsentTests.testGivenZoneRecreated_WhenFirstStopWrite_ThenCreatesFreshStoppedRecordNotStaleCacheError`.
  func testGivenSessionSyncCacheFlusher_WhenFlushSessionCache_ThenConformsAndClearsLocalCache()
    async
  {
    let flushing: SessionSyncFlushing = SessionSyncCacheFlusher(service: .shared)

    await flushing.flushSessionCache()
    await flushing.flushSessionCache()  // idempotent when already empty
  }
}
