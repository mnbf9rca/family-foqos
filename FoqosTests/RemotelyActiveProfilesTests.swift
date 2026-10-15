import CloudKit
import FoqosShared
import Foundation
import SwiftData
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
    SharedData.configure(suite: defaults)
  }

  override func tearDown() async throws {
    SharedData.resetLockPath()
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  private func record(profileId: UUID, sessionId: String, sequence: Int, now: Date, device: String = "remote") -> ProfileSessionRecord {
    var record = ProfileSessionRecord(profileId: profileId)
    record.applyUpdate(isActive: true, sequenceNumber: sequence, deviceId: device, startTime: now, sessionId: sessionId)
    return record
  }

  func testConfirmationReleasesStoppedAndMissingRecordsButKeepsActiveAndOfflineBlocks() async {
    let now = Date()
    for outcome in ["active", "stopped", "missing", "offline"] {
      let profileId = UUID()
      let active = record(profileId: profileId, sessionId: UUID().uuidString, sequence: 1, now: now)
      var stopped = active
      stopped.applyUpdate(isActive: false, sequenceNumber: 2, deviceId: "remote", endTime: now.addingTimeInterval(60))
      let fetched = outcome == "stopped" ? stopped : active
      let service = SessionSyncService(fetchRecord: { _ in
        if outcome == "missing" { throw CKError(.unknownItem) }
        if outcome == "offline" { throw CKError(.networkUnavailable) }
        return fetched.toCKRecord(in: CKRecordZone.ID(zoneName: "test"))
      })
      let manager = StrategyManager(sessionSyncService: service, remoteActiveDefaults: defaults)
      manager.receiveSessionRecord(active)
      let confirmed = await manager.confirmSessionState(profileId: profileId)
      XCTAssertEqual(confirmed, outcome != "offline", outcome)
      XCTAssertEqual(manager.remotelyActiveProfileIds.contains(profileId), outcome == "active" || outcome == "offline", outcome)
      manager.clearAllRemoteSessionActive()
    }
  }

  func testRemoteOnlyManualStopWorksWithoutLocalSelectionOrSession() async throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Remote only")
    profile.needsAppSelection = true
    profile.stopConditions = .init(manual: true)
    context.insert(profile)
    try context.save()
    let active = record(profileId: profile.id, sessionId: UUID().uuidString, sequence: 1, now: now)
    let service = SessionSyncService(
      fetchRecord: { _ in active.toCKRecord(in: CKRecordZone.ID(zoneName: "test")) },
      saveRecord: { $0 })
    let manager = StrategyManager(sessionSyncService: service, remoteActiveDefaults: defaults)
    manager.receiveSessionRecord(active)
    XCTAssertNil(manager.activeSession)
    let stopped = try await manager.stopRemoteOnlySession(profileId: profile.id, context: context)
    XCTAssertTrue(stopped)
    XCTAssertFalse(manager.remotelyActiveProfileIds.contains(profile.id))
    XCTAssertNil(manager.activeSession)
    XCTAssertTrue(profile.sessions.isEmpty)
  }

  func testOwnStopEchoBeforeCASResultStillConsumesEmergency() async throws {
    try await assertAcceptedEmergencyStop(ownEcho: true)
  }

  func testClearingAnotherProfileDuringCASStillConsumesEmergency() async throws {
    try await assertAcceptedEmergencyStop(ownEcho: false)
  }

  private func assertAcceptedEmergencyStop(ownEcho: Bool) async throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Remote emergency")
    context.insert(profile)
    try context.save()
    let active = record(profileId: profile.id, sessionId: UUID().uuidString, sequence: 1, now: now)
    let other = record(profileId: UUID(), sessionId: UUID().uuidString, sequence: 1, now: now)
    let callback = RemoteStopCallback()
    let service = SessionSyncService(
      fetchRecord: { _ in active.toCKRecord(in: CKRecordZone.ID(zoneName: "test")) },
      saveRecord: { saved in
        await callback.run(saved)
        return saved
      })
    let emergency = EmergencyUnblockManager(defaults: defaults)
    let before = emergency.getRemainingEmergencyUnblocks()
    let manager = StrategyManager(emergencyUnblockManager: emergency, sessionSyncService: service, remoteActiveDefaults: defaults)
    manager.receiveSessionRecord(active)
    manager.receiveSessionRecord(other)
    callback.action = { saved in
      if ownEcho {
        manager.receiveSessionRecord(ProfileSessionRecord(from: saved)!)
      } else {
        manager.clearRemoteSession(profileId: other.profileId)
      }
    }
    let stopped = try await manager.stopRemoteOnlySession(profileId: profile.id, context: context, emergency: true)
    XCTAssertTrue(stopped)
    XCTAssertFalse(manager.remotelyActiveProfileIds.contains(profile.id))
    XCTAssertEqual(emergency.getRemainingEmergencyUnblocks(), before - 1)
  }

  func testRemoteOnlyStopCannotBypassNormalStopCondition() async throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Tag required")
    profile.stopConditions = .init(nfc: .any)
    context.insert(profile)
    try context.save()
    let active = record(profileId: profile.id, sessionId: UUID().uuidString, sequence: 1, now: now)
    let service = SessionSyncService(
      fetchRecord: { _ in active.toCKRecord(in: CKRecordZone.ID(zoneName: "test")) },
      saveRecord: { _ in
        XCTFail("Denied stop must not write to iCloud")
        throw CKError(.internalError)
      })
    let manager = StrategyManager(sessionSyncService: service, remoteActiveDefaults: defaults)
    manager.receiveSessionRecord(active)
    do {
      try await manager.stopRemoteOnlySession(profileId: profile.id, context: context)
      XCTFail("Manual stop must respect NFC-only rules")
    } catch {}
    XCTAssertTrue(manager.remotelyActiveProfileIds.contains(profile.id))
  }

  func testRemoteOnlyTagSwitchPreparesTargetAndStopsExactVictim() async throws {
    let now = Date()
    for failure in [false, true] {
      let container = try TestModelContainer.create()
      let context = container.mainContext
      let victim = BlockedProfiles(name: "Remote victim")
      victim.needsAppSelection = true
      victim.stopConditions = .init(nfc: .any)
      let target = BlockedProfiles(name: "Target")
      target.startTriggers = .init(anyNFC: true)
      target.stopConditions = .init(timer: true, timerDurationMinutes: 15)
      context.insert(victim)
      context.insert(target)
      try context.save()
      let active = record(profileId: victim.id, sessionId: UUID().uuidString, sequence: 1, now: now)
      let service = SessionSyncService(
        fetchRecord: { _ in active.toCKRecord(in: CKRecordZone.ID(zoneName: "test")) },
        saveRecord: { record in
          if failure { throw CKError(.permissionFailure) }
          return record
        })
      var registrations = 0
      var cancellations = 0
      let manager = StrategyManager(
        sessionSyncService: service, appBlocker: RecordingRestrictionApplier(), remoteActiveDefaults: defaults,
        registerTimer: { _, _, _, start in
          registrations += 1
          return start.addingTimeInterval(900)
        },
        cancelTimer: { _, _ in cancellations += 1 }, startSessionActivity: { _ in },
        cancelPreActivationReminders: { _ in }, scheduleReconciler: { _ in })
      defer { manager.stopTimer() }
      manager.receiveSessionRecord(active)
      let event = TagEvent(type: .nfc, namespace: .opaque, key: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", targetProfileId: target.id)
      await manager.handleTagEvent(event, operation: .scan, context: context, now: now)
      XCTAssertEqual(registrations, 1)
      XCTAssertEqual(cancellations, failure ? 1 : 0)
      XCTAssertEqual(manager.remotelyActiveProfileIds.contains(victim.id), failure)
      XCTAssertEqual(manager.activeSession?.blockedProfile.id, failure ? nil : target.id)
      XCTAssertEqual(target.sessions.count, failure ? 0 : 1)
      XCTAssertTrue(victim.sessions.isEmpty)
      manager.clearAllRemoteSessionActive()
      SharedData.endActiveSharedSession()
    }
  }

  func testRemoteSwitchPostCASFailuresDiscardCandidateAndPreservePublicationWinner() async throws {
    let now = Date()
    for failure in ["save", "lock", "race", "expired"] {
      let container = try TestModelContainer.create()
      let context = container.mainContext
      let victim = BlockedProfiles(name: "Remote victim")
      victim.stopConditions = .init(nfc: .any)
      let target = BlockedProfiles(name: "Target")
      target.startTriggers = .init(anyNFC: true)
      target.stopConditions = .init(timer: true, timerDurationMinutes: 15)
      context.insert(victim)
      context.insert(target)
      try context.save()
      let active = record(profileId: victim.id, sessionId: UUID().uuidString, sequence: 1, now: now)
      let server = RemoteSessionTestServer(record: active)
      let service = SessionSyncService(fetchRecord: { try await server.fetch($0) }, saveRecord: { try await server.save($0) })
      let winner = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "manual", blockedProfileId: UUID(), startTime: now, forceStarted: false)
      var saves = 0
      var cancellations = 0
      let blocker = RecordingRestrictionApplier()
      let manager = StrategyManager(
        sessionSyncService: service, appBlocker: blocker, remoteActiveDefaults: defaults,
        registerTimer: { _, _, _, start in start.addingTimeInterval(900) },
        cancelTimer: { _, _ in cancellations += 1 }, startSessionActivity: { _ in },
        cancelPreActivationReminders: { _ in },
        saveSession: { context in
          saves += 1
          if saves == 1 {
            if failure == "save" { throw NSError(domain: "TestSave", code: 1) }
            if failure == "lock" { SharedData.configureLockPath(nil) }
            if failure == "race" { SharedData.createActiveSharedSession(for: winner) }
          }
          try context.save()
        }, scheduleReconciler: { _ in }, currentDate: { failure == "expired" ? now.addingTimeInterval(901) : now })
      defer { manager.stopTimer() }
      manager.receiveSessionRecord(active)
      await manager.handleTagEvent(
        TagEvent(type: .nfc, namespace: .opaque, key: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", targetProfileId: target.id),
        operation: .scan, context: context, now: now)
      SharedData.resetLockPath()
      let saved = await server.current()
      XCTAssertFalse(saved.isActive, failure)
      XCTAssertEqual(cancellations, 1, failure)
      XCTAssertNil(manager.activeSession, failure)
      XCTAssertTrue(target.sessions.isEmpty, failure)
      XCTAssertTrue(try context.fetch(FetchDescriptor<BlockedProfileSession>()).isEmpty, failure)
      XCTAssertEqual(SharedData.getActiveSharedSession(), failure == "race" ? winner : nil, failure)
      XCTAssertEqual(manager.errorMessage, failure == "save" ? "Couldn’t start this profile. Please try again." : "This session changed. Please try again.", failure)
      manager.clearAllRemoteSessionActive()
      SharedData.endActiveSharedSession()
    }
  }

  func testOverlappingOfflineEmergencyStopsConsumeOnlyOnce() async throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Offline overlap")
    context.insert(profile)
    try context.save()
    let active = record(profileId: profile.id, sessionId: UUID().uuidString, sequence: 1, now: now)
    let callback = RemoteStopCallback()
    let service = SessionSyncService(fetchRecord: { _ in
      await callback.run(active.toCKRecord(in: CKRecordZone.ID(zoneName: "test")))
      throw CKError(.networkUnavailable)
    })
    let emergency = EmergencyUnblockManager(defaults: defaults)
    let before = emergency.getRemainingEmergencyUnblocks()
    let manager = StrategyManager(emergencyUnblockManager: emergency, sessionSyncService: service, remoteActiveDefaults: defaults)
    manager.receiveSessionRecord(active)
    callback.action = { _ in
      callback.action = nil
      do {
        try await manager.stopRemoteOnlySession(profileId: profile.id, context: context, emergency: true)
        XCTFail("An overlapping attempt must not accept the same unblock twice")
      } catch {}
    }
    let stopped = try await manager.stopRemoteOnlySession(profileId: profile.id, context: context, emergency: true)
    XCTAssertTrue(stopped)
    XCTAssertEqual(emergency.getRemainingEmergencyUnblocks(), before - 1)
    XCTAssertEqual(manager.sessionStopOutbox.pending.count, 1)
  }

  func testOfflineEmergencyStopSurvivesRelaunchAndReplaysWithoutDoubleConsumption() async throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Offline")
    profile.needsAppSelection = true
    context.insert(profile)
    try context.save()
    let active = record(profileId: profile.id, sessionId: UUID().uuidString, sequence: 1, now: now)
    let server = RemoteSessionTestServer(record: active)
    await server.setOffline(true)
    let service = SessionSyncService(fetchRecord: { try await server.fetch($0) }, saveRecord: { try await server.save($0) })
    let emergency = EmergencyUnblockManager(defaults: defaults)
    let before = emergency.getRemainingEmergencyUnblocks()
    let manager = StrategyManager(emergencyUnblockManager: emergency, sessionSyncService: service, remoteActiveDefaults: defaults)
    manager.receiveSessionRecord(active)
    try await manager.stopRemoteOnlySession(profileId: profile.id, context: context, emergency: true)
    XCTAssertFalse(manager.remotelyActiveProfileIds.contains(profile.id))
    XCTAssertEqual(emergency.getRemainingEmergencyUnblocks(), before - 1)
    XCTAssertEqual(manager.sessionStopOutbox.expectedSessionId(for: profile.id), active.sessionId)

    let restarted = StrategyManager(emergencyUnblockManager: emergency, sessionSyncService: service, remoteActiveDefaults: defaults)
    restarted.receiveSessionRecord(active)
    XCTAssertFalse(restarted.remotelyActiveProfileIds.contains(profile.id), "An old active echo cannot revive the pending end")
    await server.setOffline(false)
    await restarted.drainSessionStopOutbox()
    let saved = await server.current()
    XCTAssertFalse(saved.isActive)
    XCTAssertTrue(restarted.sessionStopOutbox.pending.isEmpty)
    XCTAssertEqual(emergency.getRemainingEmergencyUnblocks(), before - 1)
  }

  func testOfflineStopReplayLeavesReplacementSessionIntact() async throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Replacement")
    profile.stopConditions = .init(manual: true)
    context.insert(profile)
    try context.save()
    let old = record(profileId: profile.id, sessionId: UUID().uuidString, sequence: 1, now: now)
    let replacement = record(profileId: profile.id, sessionId: UUID().uuidString, sequence: 3, now: now.addingTimeInterval(60))
    let server = RemoteSessionTestServer(record: replacement)
    await server.setOffline(true)
    let service = SessionSyncService(fetchRecord: { try await server.fetch($0) }, saveRecord: { try await server.save($0) })
    let manager = StrategyManager(sessionSyncService: service, remoteActiveDefaults: defaults)
    manager.receiveSessionRecord(old)
    try await manager.stopRemoteOnlySession(profileId: profile.id, context: context)
    await server.setOffline(false)
    await manager.drainSessionStopOutbox()
    let saved = await server.current()
    XCTAssertEqual(saved.sessionId, replacement.sessionId)
    XCTAssertTrue(saved.isActive)
    XCTAssertTrue(manager.remotelyActiveProfileIds.contains(profile.id))
    XCTAssertTrue(manager.sessionStopOutbox.pending.isEmpty)
  }

  func testOnlineReplacementDoesNotConsumeEmergencyInChildOrIndividualMode() async throws {
    let now = Date()
    let originalMode = AppModeManager.shared.currentMode
    defer { AppModeManager.shared.currentMode = originalMode }
    for mode in [AppMode.child, .individual] {
      AppModeManager.shared.currentMode = mode
      let container = try TestModelContainer.create()
      let context = container.mainContext
      let profile = BlockedProfiles(name: "Replaced")
      profile.needsAppSelection = true
      context.insert(profile)
      try context.save()
      let old = record(profileId: profile.id, sessionId: UUID().uuidString, sequence: 1, now: now)
      let replacement = record(profileId: profile.id, sessionId: UUID().uuidString, sequence: 3, now: now.addingTimeInterval(60))
      let service = SessionSyncService(
        fetchRecord: { _ in replacement.toCKRecord(in: CKRecordZone.ID(zoneName: "test")) },
        saveRecord: { _ in
          XCTFail("A replacement session must never be stopped")
          throw CKError(.internalError)
        })
      let emergency = EmergencyUnblockManager(defaults: defaults)
      let count = emergency.getRemainingEmergencyUnblocks()
      let manager = StrategyManager(emergencyUnblockManager: emergency, sessionSyncService: service, remoteActiveDefaults: defaults)
      manager.receiveSessionRecord(old)
      do {
        try await manager.stopRemoteOnlySession(profileId: profile.id, context: context, emergency: true)
        XCTFail("A stale stop must report session changed")
      } catch {
        XCTAssertEqual(error.localizedDescription, EmergencyUnblockError.sessionChanged.localizedDescription)
      }
      XCTAssertEqual(emergency.getRemainingEmergencyUnblocks(), count)
      XCTAssertTrue(manager.remotelyActiveProfileIds.contains(profile.id))
      manager.clearAllRemoteSessionActive()
    }
  }

  func testRemoteSameTagRejectsWrongTagAndAcceptsMatchingOrigin() async throws {
    let now = Date()
    for type in [TagType.nfc, .qr] {
      let container = try TestModelContainer.create()
      let context = container.mainContext
      let profile = BlockedProfiles(name: "Same tag")
      profile.needsAppSelection = true
      profile.stopConditions = type == .nfc ? .init(sameNFC: true) : .init(sameQR: true)
      context.insert(profile)
      try context.save()
      var active = ProfileSessionRecord(profileId: profile.id)
      active.applyUpdate(
        isActive: true, sequenceNumber: 1, deviceId: "remote", startTime: now,
        sessionId: UUID().uuidString, origin: .init(kind: type == .nfc ? .nfc : .qr, key: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", namespace: .opaque))
      let server = RemoteSessionTestServer(record: active)
      let service = SessionSyncService(fetchRecord: { try await server.fetch($0) }, saveRecord: { try await server.save($0) })
      let manager = StrategyManager(sessionSyncService: service, remoteActiveDefaults: defaults)
      manager.receiveSessionRecord(active)
      do {
        try await manager.stopRemoteOnlySession(profileId: profile.id, method: .tag(TagEvent(type: type, namespace: .opaque, key: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")), context: context)
        XCTFail("Wrong tag must not stop")
      } catch {}
      XCTAssertTrue(manager.remotelyActiveProfileIds.contains(profile.id))
      try await manager.stopRemoteOnlySession(profileId: profile.id, method: .tag(TagEvent(type: type, namespace: .opaque, key: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")), context: context)
      XCTAssertFalse(manager.remotelyActiveProfileIds.contains(profile.id))
      manager.clearAllRemoteSessionActive()
    }
  }

  func testLegacyTimedRemoteSessionCanBeExplicitlyStoppedByStartIdentity() async throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Legacy timer")
    profile.stopConditions = .init(manual: true, timer: true, timerDurationMinutes: 15)
    context.insert(profile)
    try context.save()
    var active = ProfileSessionRecord(profileId: profile.id)
    active.applyUpdate(isActive: true, sequenceNumber: 1, deviceId: "remote", startTime: now, timerEndTime: now.addingTimeInterval(900))
    let server = RemoteSessionTestServer(record: active)
    let service = SessionSyncService(fetchRecord: { try await server.fetch($0) }, saveRecord: { try await server.save($0) })
    let manager = StrategyManager(sessionSyncService: service, remoteActiveDefaults: defaults)
    manager.receiveSessionRecord(active)
    try await manager.stopRemoteOnlySession(profileId: profile.id, context: context)
    let result = await server.current()
    XCTAssertFalse(result.isActive)
    XCTAssertFalse(manager.remotelyActiveProfileIds.contains(profile.id))
  }

  func testLegacyBooleanIsDiscardedOnUpgrade() {
    let profileId = UUID()
    defaults.set([profileId.uuidString], forKey: RemotelyActiveStore.defaultsKey)
    let manager = StrategyManager(remoteActiveDefaults: defaults)
    XCTAssertTrue(manager.remotelyActiveProfileIds.isEmpty)
    XCTAssertNil(defaults.object(forKey: RemotelyActiveStore.defaultsKey))
  }

  func testOlderRecordCannotClearNewerRemoteSessionAfterRelaunch() {
    let now = Date()
    let profileId = UUID()
    let current = record(profileId: profileId, sessionId: UUID().uuidString, sequence: 3, now: now)
    let manager = StrategyManager(remoteActiveDefaults: defaults)
    XCTAssertTrue(manager.receiveSessionRecord(current))
    var old = record(profileId: profileId, sessionId: UUID().uuidString, sequence: 1, now: now.addingTimeInterval(-60))
    old.applyUpdate(isActive: false, sequenceNumber: 2, deviceId: "remote", endTime: now)
    let restarted = StrategyManager(remoteActiveDefaults: defaults)
    XCTAssertFalse(restarted.receiveSessionRecord(old))
    XCTAssertTrue(restarted.remotelyActiveProfileIds.contains(profileId))
  }

  func testOriginatingDeviceDeterminesRemoteActivityNotLastWriter() {
    let now = Date()
    let profileId = UUID()
    var own = record(profileId: profileId, sessionId: UUID().uuidString, sequence: 1, now: now, device: SharedData.deviceSyncId.uuidString)
    own.applyUpdate(isActive: true, sequenceNumber: 2, deviceId: "remote")
    let manager = StrategyManager(remoteActiveDefaults: defaults)
    manager.receiveSessionRecord(own)
    XCTAssertTrue(manager.remotelyActiveProfileIds.isEmpty)
  }

  func testLegacyActiveRecordFallsBackToWriterWithoutCanonicalIdentity() {
    let now = Date()
    let profileId = UUID()
    let zone = CKRecordZone.ID(zoneName: "test")
    let remote = record(profileId: profileId, sessionId: UUID().uuidString, sequence: 1, now: now).toCKRecord(in: zone)
    remote["sessionOriginDevice"] = nil
    remote["sessionId"] = nil
    let manager = StrategyManager(remoteActiveDefaults: defaults)
    manager.receiveSessionRecord(ProfileSessionRecord(from: remote)!)
    XCTAssertTrue(manager.remotelyActiveProfileIds.contains(profileId))
  }

  func testCorruptEntryDoesNotDiscardOtherProfiles() throws {
    let now = Date()
    let profileId = UUID()
    let valid = record(profileId: profileId, sessionId: UUID().uuidString, sequence: 1, now: now)
    defaults.set(
      [
        profileId.uuidString: try JSONEncoder().encode(valid),
        UUID().uuidString: Data("{}".utf8),
      ], forKey: "family_foqos_remote_session_records")
    XCTAssertEqual(StrategyManager(remoteActiveDefaults: defaults).remotelyActiveProfileIds, [profileId])
  }

  func testGivenRemoteActiveState_WhenSet_ThenPersistsAndClears() {
    let profileId = UUID()
    let manager = StrategyManager(remoteActiveDefaults: defaults)

    manager.setRemoteSessionActive(true, profileId: profileId)

    XCTAssertTrue(manager.remotelyActiveProfileIds.contains(profileId))
    XCTAssertTrue(
      StrategyManager(remoteActiveDefaults: defaults).remotelyActiveProfileIds.contains(profileId),
      "The latest session record survives relaunch")

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
    XCTAssertEqual(Set(RemotelyActiveStore.load(defaults: defaults).keys), [idB])
  }
}

// Fixtures use real synced records; production callers cannot manufacture a remote-active Boolean.
@MainActor
extension StrategyManager {
  func setRemoteSessionActive(_ isActive: Bool, profileId: UUID) {
    if !isActive {
      clearRemoteSession(profileId: profileId)
      return
    }
    var record = ProfileSessionRecord(profileId: profileId)
    record.applyUpdate(
      isActive: true, sequenceNumber: 1, deviceId: "remote-test-device",
      startTime: Date(timeIntervalSince1970: 1_700_000_000), sessionId: UUID().uuidString)
    receiveSessionRecord(record)
  }
}

private actor RemoteSessionTestServer {
  private var record: ProfileSessionRecord
  private var offline = false
  init(record: ProfileSessionRecord) { self.record = record }
  func setOffline(_ value: Bool) { offline = value }
  func current() -> ProfileSessionRecord { record }
  func fetch(_ id: CKRecord.ID) throws -> CKRecord {
    if offline { throw CKError(.networkUnavailable) }
    return record.toCKRecord(in: id.zoneID)
  }
  func save(_ value: CKRecord) throws -> CKRecord {
    if offline { throw CKError(.networkUnavailable) }
    record = ProfileSessionRecord(from: value)!
    return value
  }
}

@MainActor
private final class RemoteStopCallback {
  var action: ((CKRecord) async -> Void)?
  func run(_ record: CKRecord) async { await action?(record) }
}
