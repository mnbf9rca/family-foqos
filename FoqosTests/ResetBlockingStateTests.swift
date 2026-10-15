import CloudKit
import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class ResetBlockingStateTests: XCTestCase {
  private var suiteName: String!
  override func setUp() async throws {
    suiteName = "ResetBlockingStateTests-\(UUID())"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
  }
  override func tearDown() async throws {
    SharedData.resetLockPath()
    UserDefaults().removePersistentDomain(forName: suiteName)
  }

  func testResetRefusesExtensionOnlyActiveSessionWithoutEffects() async throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Active", createdAt: now, updatedAt: now)
    context.insert(profile)
    try context.save()
    let live = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "schedule", blockedProfileId: profile.id, startTime: now, forceStarted: true)
    SharedData.createActiveSharedSession(for: live)
    let applier = RecordingRestrictionApplier()
    var timerRemovals = 0
    let manager = StrategyManager(appBlocker: applier, removeAllStrategyTimers: { timerRemovals += 1 })

    await manager.resetBlockingState(context: context)

    XCTAssertEqual(SharedData.getActiveSharedSession(), live)
    XCTAssertTrue(applier.calls.isEmpty)
    XCTAssertEqual(timerRemovals, 0)
  }

  func testResetRemovesOrphanSharedSession() async throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let ghost = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "schedule", blockedProfileId: UUID(), startTime: now, forceStarted: true)
    SharedData.createActiveSharedSession(for: ghost)
    let manager = StrategyManager(appBlocker: RecordingRestrictionApplier(), removeAllStrategyTimers: {})

    await manager.resetBlockingState(context: container.mainContext)

    XCTAssertNil(SharedData.getActiveSharedSession())
  }

  func testResetPreservesExtensionWinnerPublishedWhileWaitingForLock() async throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Winner", createdAt: now, updatedAt: now)
    context.insert(profile)
    try context.save()
    let winner = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "schedule", blockedProfileId: profile.id, startTime: now, forceStarted: true)
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let fd = open(path, O_CREAT | O_RDWR, 0o600)
    XCTAssertGreaterThanOrEqual(fd, 0)
    guard fd >= 0 else { return }
    defer {
      close(fd)
      unlink(path)
    }
    XCTAssertEqual(flock(fd, LOCK_EX), 0)
    SharedData.configureLockPath(path)
    let winnerData = try JSONEncoder().encode(winner)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
      // The extension writes while it owns the process-shared lock.
      SharedData.activeSharedSession = try! JSONDecoder().decode(SharedData.SessionSnapshot.self, from: winnerData)
      flock(fd, LOCK_UN)
    }
    let applier = RecordingRestrictionApplier()
    var timerRemovals = 0
    let manager = StrategyManager(appBlocker: applier, removeAllStrategyTimers: { timerRemovals += 1 })

    let resetResult = await manager.resetBlockingState(context: context)
    XCTAssertEqual(resetResult, .activeSession)

    XCTAssertEqual(SharedData.getActiveSharedSession(), winner)
    XCTAssertTrue(applier.calls.isEmpty)
    XCTAssertEqual(timerRemovals, 0)
  }

  func testResetPreservesLocalActiveSessionEvenWithoutSharedSnapshot() async throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Local", createdAt: now, updatedAt: now)
    context.insert(profile)
    let local = BlockedProfileSession(tag: "manual", blockedProfile: profile, startTime: now)
    context.insert(local)
    try context.save()
    let applier = RecordingRestrictionApplier()
    let manager = StrategyManager(appBlocker: applier, removeAllStrategyTimers: {})
    manager.activeSession = local

    let resetResult = await manager.resetBlockingState(context: context)
    XCTAssertEqual(resetResult, .activeSession)

    XCTAssertEqual(manager.activeSession?.id, local.id)
    XCTAssertNil(local.endTime)
    XCTAssertTrue(applier.calls.isEmpty)
  }

  func testResetRepairsUnreadableSharedSessionsSoDeletionCanSucceed() async throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Delete after repair", createdAt: now, updatedAt: now)
    context.insert(profile)
    try context.save()
    BlockedProfiles.updateSnapshot(for: profile)
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(Data("corrupt active".utf8), forKey: "family_foqos_active_schedule_session")
    defaults.set(Data("corrupt completed".utf8), forKey: "family_foqos_completed_schedule_sessions")
    XCTAssertThrowsError(try BlockedProfiles.deleteProfile(profile, in: context)) { error in
      XCTAssertEqual(error.localizedDescription, "Couldn't remove this profile's stored sessions, so it wasn't deleted. Go to Settings and tap Reset Blocking State, then delete it again.")
    }
    let applier = RecordingRestrictionApplier()
    let manager = StrategyManager(appBlocker: applier, removeAllStrategyTimers: {})

    let resetResult = await manager.resetBlockingState(context: context)

    XCTAssertEqual(resetResult, .completed)
    XCTAssertEqual(applier.calls, [.deactivate])
    try BlockedProfiles.deleteProfile(profile, in: context)
    try context.save()
    XCTAssertNil(try BlockedProfiles.findProfile(byID: profile.id, in: context))
  }

  func testUnreadableCompletedQueueCannotClearReadableActiveSession() async throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Keep", createdAt: now, updatedAt: now)
    context.insert(profile)
    try context.save()
    let live = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "schedule", blockedProfileId: profile.id, startTime: now, forceStarted: true)
    SharedData.createActiveSharedSession(for: live)
    UserDefaults(suiteName: suiteName)!.set(Data("corrupt completed".utf8), forKey: "family_foqos_completed_schedule_sessions")
    let applier = RecordingRestrictionApplier()
    let manager = StrategyManager(appBlocker: applier, removeAllStrategyTimers: {})

    let resetResult = await manager.resetBlockingState(context: context)

    XCTAssertEqual(resetResult, .activeSession)
    XCTAssertEqual(SharedData.getActiveSharedSession(), live)
    XCTAssertTrue(applier.calls.isEmpty)
  }

  func testResetRefreshesRemoteCacheWithoutCloudWritesAndPreservesOfflineCache() async throws {
    let now = Date()
    let sync = ProfileSyncManager.shared
    let wasEnabled = sync.isEnabled
    sync.isEnabled = true
    defer { sync.isEnabled = wasEnabled }
    for online in [true, false] {
      let container = try TestModelContainer.create()
      let context = container.mainContext
      let profile = BlockedProfiles(name: "Remote", createdAt: now, updatedAt: now)
      context.insert(profile)
      try context.save()
      var active = ProfileSessionRecord(profileId: profile.id)
      active.applyUpdate(isActive: true, sequenceNumber: 1, deviceId: "other-device", startTime: now, sessionId: UUID().uuidString)
      let service = SessionSyncService(
        fetchRecord: { _ in throw CKError(online ? .unknownItem : .networkUnavailable) },
        saveRecord: { record in
          XCTFail("Reset must never write a cloud stop")
          return record
        })
      let manager = StrategyManager(
        profileSyncManager: sync, sessionSyncService: service,
        appBlocker: RecordingRestrictionApplier(), remoteActiveDefaults: UserDefaults(suiteName: suiteName)!,
        removeAllStrategyTimers: {})
      manager.receiveSessionRecord(active)

      let resetResult = await manager.resetBlockingState(context: context)

      XCTAssertEqual(resetResult, .completed)
      XCTAssertEqual(manager.remotelyActiveProfileIds.contains(profile.id), !online)
      XCTAssertNil(manager.activeSession)
    }
  }

  func testRemoteRefreshCannotClearSessionStartedDuringItsAwait() async throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Winner", createdAt: now, updatedAt: now)
    context.insert(profile)
    try context.save()
    let winner = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "schedule", blockedProfileId: profile.id, startTime: now, forceStarted: true)
    let sync = ProfileSyncManager.shared
    let wasEnabled = sync.isEnabled
    sync.isEnabled = true
    defer { sync.isEnabled = wasEnabled }
    let applier = RecordingRestrictionApplier()
    let winnerData = try JSONEncoder().encode(winner)
    let service = SessionSyncService(fetchRecord: { _ in
      let winner = try JSONDecoder().decode(SharedData.SessionSnapshot.self, from: winnerData)
      SharedData.createActiveSharedSession(for: winner)
      throw CKError(.networkUnavailable)
    })
    var timerRemovals = 0
    let manager = StrategyManager(
      profileSyncManager: sync, sessionSyncService: service, appBlocker: applier,
      remoteActiveDefaults: UserDefaults(suiteName: suiteName)!,
      removeAllStrategyTimers: { timerRemovals += 1 })

    let result = await manager.resetBlockingState(context: context)

    XCTAssertEqual(result, .completed)
    XCTAssertEqual(SharedData.getActiveSharedSession(), winner)
    XCTAssertEqual(applier.calls, [.deactivate], "All clearing happens before the cloud fetch")
    XCTAssertEqual(timerRemovals, 1)
  }
  func testResetPreservesDetachedPublishedActiveSessionWithSurvivingOwner() async throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Surviving owner", createdAt: now, updatedAt: now)
    context.insert(profile)
    try context.save()
    let otherContext = ModelContext(container)
    let detachedOwner = try XCTUnwrap(BlockedProfiles.findProfile(byID: profile.id, in: otherContext))
    let detached = BlockedProfileSession(tag: "manual", blockedProfile: detachedOwner, startTime: now)
    otherContext.insert(detached)
    XCTAssertTrue(detached.isPersistentModelValid)
    XCTAssertTrue(try context.fetch(FetchDescriptor<BlockedProfileSession>()).isEmpty)
    let applier = RecordingRestrictionApplier()
    let manager = StrategyManager(appBlocker: applier, removeAllStrategyTimers: {})
    manager.activeSession = detached

    let result = await manager.resetBlockingState(context: context)

    XCTAssertEqual(result, .activeSession)
    XCTAssertEqual(manager.activeSession?.id, detached.id)
    XCTAssertTrue(applier.calls.isEmpty)
  }

  func testResetDiscardsMalformedCompletedEntryWithoutTreatingItAsActive() async throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let profile = BlockedProfiles(name: "Surviving owner", createdAt: now, updatedAt: now)
    container.mainContext.insert(profile)
    try container.mainContext.save()
    let malformed = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "schedule", blockedProfileId: profile.id, startTime: now, forceStarted: true)
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(try JSONEncoder().encode([malformed]), forKey: "family_foqos_completed_schedule_sessions")
    let applier = RecordingRestrictionApplier()
    let manager = StrategyManager(appBlocker: applier, removeAllStrategyTimers: {})

    let result = await manager.resetBlockingState(context: container.mainContext)

    XCTAssertEqual(result, .completed)
    XCTAssertEqual(SharedData.completedSessionsInScheduler, [])
    XCTAssertEqual(applier.calls, [.deactivate])
  }

  func testResetClearsDeletedPublishedReference() async throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Owner", createdAt: now, updatedAt: now)
    context.insert(profile)
    let session = BlockedProfileSession(tag: "manual", blockedProfile: profile, startTime: now)
    context.insert(session)
    try context.save()
    let applier = RecordingRestrictionApplier()
    let manager = StrategyManager(appBlocker: applier, removeAllStrategyTimers: {})
    manager.activeSession = session
    context.delete(session)
    XCTAssertFalse(session.isPersistentModelValid)

    let result = await manager.resetBlockingState(context: context)

    XCTAssertEqual(result, .completed)
    XCTAssertNil(manager.activeSession)
    XCTAssertEqual(applier.calls, [.deactivate])
  }

  func testResetRebuildsUnreadableSnapshotsBeforeRetryingDeletion() async throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let deleted = BlockedProfiles(name: "Delete", createdAt: now, updatedAt: now)
    let survivor = BlockedProfiles(name: "Keep", createdAt: now, updatedAt: now)
    context.insert(deleted)
    context.insert(survivor)
    try context.save()
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(Data("corrupt snapshots".utf8), forKey: "family_foqos_profile_snapshots")
    XCTAssertThrowsError(try BlockedProfiles.deleteProfile(deleted, in: context))
    XCTAssertThrowsError(try OrphanedSessionCleanup.run(context: context))
    let manager = StrategyManager(appBlocker: RecordingRestrictionApplier(), removeAllStrategyTimers: {})

    let result = await manager.resetBlockingState(context: context)

    XCTAssertEqual(result, .completed)
    XCTAssertEqual(SharedData.snapshot(for: survivor.id.uuidString), BlockedProfiles.getSnapshot(for: survivor))
    try BlockedProfiles.deleteProfile(deleted, in: context)
    try context.save()
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<BlockedProfiles>()), 1)
    XCTAssertNotNil(SharedData.snapshot(for: survivor.id.uuidString))
  }

  func testCorruptSnapshotsAreUntouchedWhenReadableSessionIsActive() async throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Keep", createdAt: now, updatedAt: now)
    context.insert(profile)
    try context.save()
    let live = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "schedule", blockedProfileId: profile.id, startTime: now, forceStarted: true)
    SharedData.createActiveSharedSession(for: live)
    let corrupt = Data("corrupt snapshots".utf8)
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(corrupt, forKey: "family_foqos_profile_snapshots")
    let applier = RecordingRestrictionApplier()
    let manager = StrategyManager(appBlocker: applier, removeAllStrategyTimers: { XCTFail("Refused reset must not remove timers") })

    let result = await manager.resetBlockingState(context: context)

    XCTAssertEqual(result, .activeSession)
    XCTAssertEqual(defaults.data(forKey: "family_foqos_profile_snapshots"), corrupt)
    XCTAssertEqual(SharedData.getActiveSharedSession(), live)
    XCTAssertTrue(applier.calls.isEmpty)
  }

  func testResetReportsStorageFailureWithoutClearingEffects() async throws {
    let container = try TestModelContainer.create()
    SharedData.configureLockPath(nil)
    let applier = RecordingRestrictionApplier()
    let manager = StrategyManager(appBlocker: applier, removeAllStrategyTimers: { XCTFail("Failed reset must not clear timers") })

    let result = await manager.resetBlockingState(context: container.mainContext)

    XCTAssertEqual(result, .failed)
    XCTAssertTrue(applier.calls.isEmpty)
  }

  func testResetDefersWhileSyncIsReplacingProfiles() async throws {
    let container = try TestModelContainer.create()
    let sync = ProfileSyncManager.shared
    let restoreAttachment = sync.makeAttachedEngineStateRestorerForTest()
    let savedController = sync.engineController
    let savedEnabled = sync.isEnabled
    let savedReady = sync.isSyncReady
    let savedDefaults = sync.bufferDefaults
    sync.isEnabled = false
    sync.engineController = nil
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      sync.engineController = savedController
      sync.isSyncReady = savedReady
      sync.isEnabled = savedEnabled
      sync.bufferDefaults = savedDefaults
      restoreAttachment()
    }
    await sync.attachEngine(
      modelContext: container.mainContext, emergencyManager: EmergencyUnblockManager(defaults: defaults),
      userRecordNameProvider: { "reset-test-user" }, driverFactory: { _ in MockSyncEngineDriver() }, storeDefaults: defaults)
    let store = SyncEngineStore(userRecordName: "reset-test-user", defaults: defaults)
    store.resetIntent = ResetIntent(id: UUID(), clear: false, wipe: true, stage: .wiping, priorCommandId: nil)
    XCTAssertTrue(sync.isReplacingLocalProfiles)
    let corrupt = Data("corrupt snapshots".utf8)
    defaults.set(corrupt, forKey: "family_foqos_profile_snapshots")
    let applier = RecordingRestrictionApplier()
    let manager = StrategyManager(profileSyncManager: sync, appBlocker: applier, removeAllStrategyTimers: { XCTFail("Deferred reset must not clear timers") })

    let result = await manager.resetBlockingState(context: container.mainContext)

    XCTAssertEqual(result, .syncInProgress)
    XCTAssertTrue(applier.calls.isEmpty)
    XCTAssertEqual(defaults.data(forKey: "family_foqos_profile_snapshots"), corrupt)
  }

}
