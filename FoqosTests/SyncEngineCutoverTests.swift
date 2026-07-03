import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

/// Task 136 (Phase F): S-12 integration test — an account switch (T7/§7) purges NEITHER
/// user's namespace, and reconstructing the controller for the original user (switch-back)
/// resumes with that user's persisted state intact, enqueueing nothing new (I7/I11).
@MainActor
final class SyncEngineCutoverTests: XCTestCase {
  var testSuiteName: String!
  var defaults: UserDefaults!
  var container: ModelContainer!
  var context: ModelContext!

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "SyncEngineCutoverTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: testSuiteName)!
    SharedData.configure(suite: defaults)
    container = try TestModelContainer.create()
    context = container.mainContext
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: testSuiteName)
    try await super.tearDown()
  }

  private func makeController(
    userRecordName: String, engineState: Data?, driver: CutoverRecordingDriver
  ) -> SyncEngineController {
    let store = SyncEngineStore(userRecordName: userRecordName, defaults: defaults)
    store.engineState = engineState
    let deviceId = SharedData.deviceSyncId.uuidString
    let apply = SyncApplyService(
      modelContext: context, store: store, sessionController: MockSessionController(),
      emergencyManager: EmergencyUnblockManager(), deviceId: deviceId)
    let provider = RecordProvider(
      modelContext: context, store: store, emergencyManager: EmergencyUnblockManager(),
      deviceId: deviceId)
    return SyncEngineController(
      modelContext: context, store: store, driverFactory: { _ in driver },
      apply: apply, provider: provider, sessionSync: SessionSyncCacheFlusher(), deviceId: deviceId)
  }

  func testGivenTwoAccounts_WhenAccountSwitched_ThenNeitherNamespacePurgedAndSwitchBackResumes()
    throws
  {
    let stateA = Data("engine-A".utf8)
    let stateB = Data("engine-B".utf8)

    // Seed both namespaces with per-user state (engine state + a delete tombstone).
    let storeA = SyncEngineStore(userRecordName: "user-A", defaults: defaults)
    storeA.engineState = stateA
    storeA.setTombstone(recordName: "prof-A", changeTag: "tagA")
    let storeB = SyncEngineStore(userRecordName: "user-B", defaults: defaults)
    storeB.engineState = stateB
    storeB.setTombstone(recordName: "prof-B", changeTag: "tagB")

    // Account A is active; an account switch fires T7.
    let driverA = CutoverRecordingDriver(stateSerialization: stateA)
    let controllerA = makeController(userRecordName: "user-A", engineState: stateA, driver: driverA)
    controllerA.start()
    controllerA.handle(.accountChange(kind: .switchAccounts))

    // §7: switching purges NOTHING — both namespaces intact.
    let checkA = SyncEngineStore(userRecordName: "user-A", defaults: defaults)
    let checkB = SyncEngineStore(userRecordName: "user-B", defaults: defaults)
    XCTAssertEqual(checkA.engineState, stateA)
    XCTAssertEqual(checkA.deleteTombstones["prof-A"] ?? nil, "tagA")
    XCTAssertEqual(checkB.engineState, stateB)
    XCTAssertEqual(checkB.deleteTombstones["prof-B"] ?? nil, "tagB")

    // Switch back to A: relaunch with existing engineState, no intents -> resumes,
    // zero new seed enqueues (I7/I11).
    let driverA2 = CutoverRecordingDriver(stateSerialization: stateA)
    let controllerA2 = makeController(
      userRecordName: "user-A", engineState: stateA, driver: driverA2)
    controllerA2.start()
    XCTAssertTrue(driverA2.enqueuedZoneSaveNames.isEmpty)
    XCTAssertTrue(driverA2.enqueuedSaveNames.isEmpty)
  }

  /// Task 137 (Phase F): S-16 end-to-end — a funnel-bumped edit propagates through
  /// materialization and apply on another device; a bypass edit (no funnel) produces no bump
  /// and no pending change, so it never propagates (I2/S-27).
  func testGivenFunnelBumpedAndBypassEdit_WhenApplied_ThenOnlyFunnelEditPropagates() throws {
    let now = Date()

    // Device A: create + funnel-save a profile (bump-in-write + enqueue).
    let driverA = CutoverRecordingDriver(stateSerialization: Data("A".utf8))
    let storeA = SyncEngineStore(userRecordName: "user-A16", defaults: defaults)
    storeA.engineState = Data("A".utf8)
    let deviceA = "device-A"
    let profile = BlockedProfiles(id: UUID(), name: "Focus", createdAt: now, updatedAt: now)
    context.insert(profile)
    try context.save()
    let funnelA = MutationFunnel(
      modelContext: context, store: storeA, driver: driverA, deviceId: deviceA)
    try funnelA.enqueueSave(profileId: profile.id)

    let refreshed = try XCTUnwrap(try BlockedProfiles.findProfile(byID: profile.id, in: context))
    XCTAssertGreaterThanOrEqual(refreshed.syncVersion, 1)
    XCTAssertTrue(driverA.enqueuedSaveNames.contains(profile.id.uuidString))

    // Materialize the record the way nextRecordZoneChangeBatch would (§5.4).
    let providerA = RecordProvider(
      modelContext: context, store: storeA, emergencyManager: EmergencyUnblockManager(),
      deviceId: deviceA)
    let record = try XCTUnwrap(providerA.record(forRecordName: profile.id.uuidString))

    // Device B: apply the fetched modification -> profile appears with the same version.
    let containerB = try TestModelContainer.create()
    let contextB = containerB.mainContext
    let storeB = SyncEngineStore(userRecordName: "user-B16", defaults: defaults)
    let applyB = SyncApplyService(
      modelContext: contextB, store: storeB, sessionController: MockSessionController(),
      emergencyManager: EmergencyUnblockManager(), deviceId: "device-B")
    let outcome = applyB.applyFetchedModification(record, isPendingDeleteOrTombstoned: { _ in false })
    XCTAssertEqual(outcome, .applied)
    let onB = try XCTUnwrap(try BlockedProfiles.findProfile(byID: profile.id, in: contextB))
    XCTAssertEqual(onB.name, "Focus")
    XCTAssertEqual(onB.syncVersion, refreshed.syncVersion)

    // Device A bypass edit: mutate WITHOUT the funnel (no bump, no enqueue).
    let saveCountBefore = driverA.enqueuedSaveNames.count
    refreshed.name = "Renamed-bypassing-funnel"
    try context.save()
    XCTAssertEqual(driverA.enqueuedSaveNames.count, saveCountBefore)  // nothing enqueued -> won't propagate
  }
}
