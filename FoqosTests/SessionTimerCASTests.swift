import CloudKit
import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

final class SessionTimerCASTests: XCTestCase {
  @MainActor
  func testScheduledReplacementStopsOldSessionBeforePublishingNewStart() async throws {
    let now = Date()
    let suite = "ScheduledReplacement-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    SharedData.configure(suite: defaults)
    let sync = ProfileSyncManager.shared
    let wasEnabled = sync.isEnabled
    sync.isEnabled = true
    defer {
      sync.isEnabled = wasEnabled
      defaults.removePersistentDomain(forName: suite)
    }
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Scheduled")
    context.insert(profile)
    let old = BlockedProfileSession(tag: "schedule", blockedProfile: profile, startTime: now.addingTimeInterval(-600))
    old.usesCanonicalIdentity = true
    old.origin = .init(kind: .schedule)
    context.insert(old)
    try context.save()
    SharedData.createActiveSharedSession(for: old.toSnapshot())
    SharedData.endActiveSharedSession()
    let replacementId = UUID().uuidString
    SharedData.createActiveSharedSession(
      for: .init(
        id: replacementId, tag: "schedule", blockedProfileId: profile.id, startTime: now,
        timerEndTime: now.addingTimeInterval(2220), forceStarted: true, origin: .init(kind: .schedule), usesCanonicalIdentity: true))
    var active = ProfileSessionRecord(profileId: profile.id)
    active.applyUpdate(
      isActive: true, sequenceNumber: 1, deviceId: SharedData.deviceSyncId.uuidString,
      startTime: old.startTime, sessionId: old.id, origin: .init(kind: .schedule))
    let saved = expectation(description: "old completion and replacement publication")
    saved.expectedFulfillmentCount = 2
    let server = OrderingCASRecords(record: active.toCKRecord(in: CKRecordZone.ID(zoneName: "Test"))) { saved.fulfill() }
    let service = SessionSyncService(fetchRecord: { try await server.fetch($0) }, saveRecord: { await server.save($0) })
    let manager = StrategyManager(sessionSyncService: service)
    manager.sessionStopOutbox.clear()
    defer {
      manager.stopTimer()
      manager.sessionStopOutbox.clear()
    }
    try manager.loadActiveSession(context: context)
    await fulfillment(of: [saved], timeout: 3)
    let saves = await server.saves
    XCTAssertEqual(saves.map { $0["isActive"] as? Int }, [0, 1])
    XCTAssertEqual(saves.last?["startTime"] as? Date, now)
    XCTAssertNotNil(manager.activeSession?.sessionServerModificationDate)
    XCTAssertEqual(manager.activeSession?.sessionServerModificationDate, saves.last?.modificationDate)
    XCTAssertEqual(manager.activeSession?.timerEndTime, now.addingTimeInterval(2220))
  }

  @MainActor
  func testDisplacedLocalSessionStopsRemotelyWithoutAnotherForeground() async throws {
    let now = Date()
    let suite = "DisplacedSession-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    SharedData.configure(suite: defaults)
    let sync = ProfileSyncManager.shared
    let wasEnabled = sync.isEnabled
    sync.isEnabled = true
    defer {
      sync.isEnabled = wasEnabled
      defaults.removePersistentDomain(forName: suite)
    }
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Local")
    let incoming = BlockedProfiles(name: "Incoming")
    context.insert(profile)
    context.insert(incoming)
    let old = BlockedProfileSession(tag: "local", blockedProfile: profile, startTime: now.addingTimeInterval(-60))
    old.usesCanonicalIdentity = true
    old.origin = .init(kind: .schedule)
    context.insert(old)
    try context.save()
    SharedData.createActiveSharedSession(for: old.toSnapshot())
    var active = ProfileSessionRecord(profileId: profile.id)
    active.applyUpdate(
      isActive: true, sequenceNumber: 1, deviceId: SharedData.deviceSyncId.uuidString,
      startTime: old.startTime, sessionId: old.id, origin: .init(kind: .schedule))
    let stopped = expectation(description: "displaced local session retired while foregrounded")
    let server = OrderingCASRecords(record: active.toCKRecord(in: CKRecordZone.ID(zoneName: "Test"))) { stopped.fulfill() }
    let service = SessionSyncService(fetchRecord: { try await server.fetch($0) }, saveRecord: { await server.save($0) })
    let manager = StrategyManager(sessionSyncService: service)
    manager.sessionStopOutbox.clear()
    defer {
      manager.stopTimer()
      manager.sessionStopOutbox.clear()
    }
    manager.activeSession = old
    manager.startRemoteSession(context: context, profileId: incoming.id, sessionId: UUID(), startTime: now)
    await fulfillment(of: [stopped], timeout: 3)
    let saves = await server.saves
    XCTAssertEqual(saves.count, 1)
    XCTAssertEqual(saves.first?["isActive"] as? Int, 0)
    XCTAssertEqual(saves.first?["profileId"] as? String, profile.id.uuidString)
    XCTAssertEqual(manager.activeSession?.blockedProfile.id, incoming.id)
  }

  @MainActor
  func testFailedExactStopDefersRemoteIdentityUntilDrainRetriesStartCAS() async throws {
    let now = Date()
    let suite = "DeferredStart-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    SharedData.configure(suite: defaults)
    let sync = ProfileSyncManager.shared
    let wasEnabled = sync.isEnabled
    sync.isEnabled = true
    defer {
      sync.isEnabled = wasEnabled
      defaults.removePersistentDomain(forName: suite)
    }
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Deferred")
    profile.startTriggers = .init(manual: true)
    profile.stopConditions = .init(timer: true, timerDurationMinutes: 37)
    context.insert(profile)
    try context.save()
    let oldId = UUID().uuidString
    var remote = ProfileSessionRecord(profileId: profile.id)
    remote.applyUpdate(
      isActive: true, sequenceNumber: 1, deviceId: "other-device",
      startTime: now.addingTimeInterval(-60), sessionId: oldId, origin: .init(kind: .manual))
    let failed = expectation(description: "pending exact stop fails offline")
    let server = DeferredStartCASRecord(record: remote.toCKRecord(in: CKRecordZone.ID(zoneName: "Test")), onFailure: { failed.fulfill() })
    let service = SessionSyncService(fetchRecord: { _ in try await server.fetch() }, saveRecord: { await server.save($0) })
    let manager = StrategyManager(
      sessionSyncService: service,
      registerTimer: { _, _, _, _ in now.addingTimeInterval(2220) }, cancelTimer: { _, _ in })
    manager.sessionStopOutbox.clear()
    defer {
      manager.stopTimer()
      manager.sessionStopOutbox.clear()
    }
    manager.sessionStopOutbox.enqueue(profileId: profile.id, expectedStart: now.addingTimeInterval(-60), expectedSessionId: oldId)
    let candidate = try manager.startOriginatingSession(context: context, profile: profile, origin: .init(kind: .manual), now: now)
    let candidateId = candidate.id
    await fulfillment(of: [failed], timeout: 3)
    XCTAssertTrue(candidate.sessionStartSyncPending)
    let winner = UUID()
    remote.resetForNewSession()
    remote.applyUpdate(
      isActive: true, sequenceNumber: 2, deviceId: "other-device",
      startTime: now.addingTimeInterval(-3600), timerEndTime: now.addingTimeInterval(1200),
      sessionId: winner.uuidString, origin: .init(kind: .schedule))
    let wire = SessionServerDatedRecord(copying: remote.toCKRecord(in: CKRecordZone.ID(zoneName: "Test")), modifiedAt: now.addingTimeInterval(1))
    manager.startRemoteSession(
      context: context, profileId: profile.id, sessionId: winner,
      startTime: remote.startTime!, timerEndTime: remote.validTimerEndTime,
      origin: remote.origin, sequenceNumber: 2, serverModificationDate: wire.modificationDate)
    XCTAssertEqual(manager.activeSession?.id, candidateId)
    await server.reconnect(record: wire)
    await manager.drainSessionStopOutbox()
    XCTAssertEqual(manager.activeSession?.id, winner.uuidString)
    XCTAssertEqual(manager.activeSession?.timerEndTime, now.addingTimeInterval(1200))
    XCTAssertEqual(manager.activeSession?.sessionServerModificationDate, now.addingTimeInterval(1))
    XCTAssertFalse(candidate.sessionStartSyncPending)
    XCTAssertTrue(manager.sessionStopOutbox.pending.isEmpty)
    let fetches = await server.fetchCount
    XCTAssertEqual(fetches, 3, "failed stop, resolved exact stop, and authoritative start CAS join")
  }

  @MainActor
  func testReconnectRetiresOriginalRemoteSessionAfterTwoOfflineLocalStops() async {
    let now = Date()
    let profile = UUID()
    let original = UUID().uuidString
    let replacement = UUID().uuidString
    var active = ProfileSessionRecord(profileId: profile)
    active.applyUpdate(
      isActive: true, sequenceNumber: 1, deviceId: SharedData.deviceSyncId.uuidString,
      startTime: now, sessionId: original, origin: .init(kind: .manual))
    let server = OrderingCASRecords(record: active.toCKRecord(in: CKRecordZone.ID(zoneName: "Test"))) {}
    let service = SessionSyncService(fetchRecord: { try await server.fetch($0) }, saveRecord: { await server.save($0) })
    let manager = StrategyManager(sessionSyncService: service)
    manager.sessionStopOutbox.clear()
    defer { manager.sessionStopOutbox.clear() }
    manager.sessionStopOutbox.enqueue(profileId: profile, expectedStart: now, expectedSessionId: original)
    manager.sessionStopOutbox.enqueue(profileId: profile, expectedStart: now.addingTimeInterval(1), expectedSessionId: replacement)
    await manager.drainSessionStopOutbox()
    let saves = await server.saves
    XCTAssertEqual(saves.count, 1)
    XCTAssertEqual(saves.first?["isActive"] as? Int, 0)
    XCTAssertEqual(saves.first?["sessionId"] as? String, original)
    XCTAssertTrue(manager.sessionStopOutbox.pending.isEmpty)
  }

  @MainActor
  func testUnconfirmedIdentityAfterRestartObtainsCASConfirmation() async throws {
    let now = Date()
    let suite = "RestartConfirmation-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    SharedData.configure(suite: defaults)
    let sync = ProfileSyncManager.shared
    let wasEnabled = sync.isEnabled
    sync.isEnabled = true
    defer {
      sync.isEnabled = wasEnabled
      defaults.removePersistentDomain(forName: suite)
    }
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Unconfirmed")
    context.insert(profile)
    let local = BlockedProfileSession(tag: "local", blockedProfile: profile, startTime: now)
    local.usesCanonicalIdentity = true
    context.insert(local)
    try context.save()
    SharedData.createActiveSharedSession(for: local.toSnapshot())
    let winner = UUID()
    var active = ProfileSessionRecord(profileId: profile.id)
    active.applyUpdate(
      isActive: true, sequenceNumber: 1, deviceId: "other-device",
      startTime: now.addingTimeInterval(-3600), sessionId: winner.uuidString, origin: .init(kind: .manual))
    let wire = SessionServerDatedRecord(copying: active.toCKRecord(in: CKRecordZone.ID(zoneName: "Test")), modifiedAt: now)
    let server = DeferredStartCASRecord(record: wire, onFailure: { XCTFail("Server is online") })
    await server.reconnect(record: wire)
    let service = SessionSyncService(fetchRecord: { _ in try await server.fetch() }, saveRecord: { await server.save($0) })
    let manager = StrategyManager(sessionSyncService: service)
    manager.sessionStopOutbox.clear()
    defer {
      manager.stopTimer()
      manager.sessionStopOutbox.clear()
    }
    manager.activeSession = local
    manager.startRemoteSession(
      context: context, profileId: profile.id, sessionId: winner,
      startTime: active.startTime!, sequenceNumber: 1, serverModificationDate: now)
    XCTAssertTrue(local.sessionStartSyncPending)
    await manager.drainSessionStopOutbox()
    XCTAssertEqual(manager.activeSession?.id, winner.uuidString)
    XCTAssertEqual(manager.activeSession?.sessionServerModificationDate, now)
    XCTAssertFalse(local.sessionStartSyncPending)
    let fetches = await server.fetchCount
    XCTAssertEqual(fetches, 1)
  }

  private func record(profile: UUID, start: Date, owner: String, deadline: Date?) -> CKRecord {
    var session = ProfileSessionRecord(profileId: profile)
    session.applyUpdate(isActive: true, sequenceNumber: 1, deviceId: owner, startTime: start, timerEndTime: deadline)
    return session.toCKRecord(in: CKRecordZone.ID(zoneName: "Test"))
  }

  func testTimerStopConflictRefetchRejectsReplacementAndOtherOwner() async {
    let now = Date()
    let profile = UUID()
    let owner = SharedData.deviceSyncId.uuidString
    for (remoteStart, remoteOwner) in [(now.addingTimeInterval(5), owner), (now, "other-device")] {
      let server = TimerCASRecords(records: [
        record(profile: profile, start: now, owner: owner, deadline: now.addingTimeInterval(900)),
        record(profile: profile, start: remoteStart, owner: remoteOwner, deadline: now.addingTimeInterval(1800)),
      ])
      let service = SessionSyncService(fetchRecord: { _ in try await server.fetch() }, saveRecord: { try await server.save($0) })
      let result = await service.stopSession(profileId: profile, endTime: now, expectedStart: now.addingTimeInterval(0.25))
      guard case .alreadyStopped = result else {
        XCTFail("Obsolete timer stop must yield")
        continue
      }
      let saves = await server.saves
      XCTAssertEqual(saves.count, 1)
      XCTAssertNil(saves.first?["timerEndTime"])
    }
  }

  func testOrdinaryStopKeepsConflictBehaviorAndMatchingTimerRetainsExpectation() async {
    let now = Date()
    let profile = UUID()
    let owner = SharedData.deviceSyncId.uuidString
    let active = record(profile: profile, start: now, owner: owner, deadline: now.addingTimeInterval(900))
    let server = TimerCASRecords(records: [active, active])
    let service = SessionSyncService(fetchRecord: { _ in try await server.fetch() }, saveRecord: { try await server.save($0) })
    let result = await service.stopSession(profileId: profile, endTime: now, expectedStart: now.addingTimeInterval(0.4))
    guard case .conflict(let current) = result else { return XCTFail("Matching owner still conflicts") }
    XCTAssertEqual(current.validTimerEndTime, now.addingTimeInterval(900))
    let other = record(profile: profile, start: now, owner: "B", deadline: nil)
    let ordinaryServer = TimerCASRecords(records: [other], failSave: false)
    let ordinary = SessionSyncService(fetchRecord: { _ in try await ordinaryServer.fetch() }, saveRecord: { try await ordinaryServer.save($0) })
    let ordinaryResult = await ordinary.stopSession(profileId: profile, endTime: now)
    guard case .stopped = ordinaryResult else { return XCTFail("Ordinary authorized stops do not require timer ownership") }
  }

  func testStartConflictUsesAuthoritativeDeadlineAndNewWritesClearOldValue() async {
    let now = Date()
    let profile = UUID()
    var inactive = ProfileSessionRecord(profileId: profile)
    inactive.applyUpdate(isActive: false, sequenceNumber: 1, deviceId: "B", endTime: now)
    let old = inactive.toCKRecord(in: CKRecordZone.ID(zoneName: "Test"))
    old["timerEndTime"] = now.addingTimeInterval(5000)
    let winner = record(profile: profile, start: now.addingTimeInterval(-10), owner: "B", deadline: now.addingTimeInterval(1800))
    let server = TimerCASRecords(records: [old, winner])
    let service = SessionSyncService(fetchRecord: { _ in try await server.fetch() }, saveRecord: { try await server.save($0) })
    let result = await service.startSession(profileId: profile, startTime: now, timerEndTime: nil)
    guard case .alreadyActive(let active) = result else { return XCTFail("Server active record wins") }
    XCTAssertEqual(active.validTimerEndTime, now.addingTimeInterval(1800))
    let saves = await server.saves
    XCTAssertEqual(saves.count, 1)
    XCTAssertNil(saves.first?["timerEndTime"])
  }

  @MainActor
  func testFailedCompletionStopsPersistExpectationAndRedriveOnlyMatchingSession() async throws {
    let now = Date()
    let owner = SharedData.deviceSyncId.uuidString
    let outbox = SessionStopOutbox()
    outbox.clear()
    defer { outbox.clear() }
    for conflicts in [false, true] {
      for (remoteStart, remoteOwner, deadline, canStop) in [
        (now, owner, Optional(now.addingTimeInterval(900)), true),
        (now.addingTimeInterval(5), owner, now.addingTimeInterval(900), false),
        (now, "other-device", now.addingTimeInterval(900), false),
        (now.addingTimeInterval(5), "other-device", nil, false),
        (now, "other-device", nil, true),
      ] {
        let profile = UUID()
        let active = record(profile: profile, start: now, owner: owner, deadline: now.addingTimeInterval(900))
        let remote = record(profile: profile, start: remoteStart, owner: remoteOwner, deadline: deadline)
        let server = TimerCASRecords(
          records: conflicts ? [active, active, remote] : [remote],
          failuresRemaining: conflicts ? 1 : 0)
        let service = SessionSyncService(fetchRecord: { _ in try await server.fetch() }, saveRecord: { try await server.save($0) })
        let manager = StrategyManager(sessionSyncService: service)
        let failure: SessionSyncService.StopResult =
          conflicts ? .conflict(currentSession: try XCTUnwrap(ProfileSessionRecord(from: active))) : .error(CKError(.networkUnavailable))

        await manager.handleStopResult(failure, profileId: profile, endTime: now, expectedStart: now)

        let reloaded = SessionStopOutbox()
        XCTAssertEqual(reloaded.pending, [profile])
        XCTAssertEqual(reloaded.expectedStart(for: profile), now)
        let restartedManager = StrategyManager(sessionSyncService: service)
        await restartedManager.drainSessionStopOutbox()
        let saves = await server.saves
        XCTAssertEqual(saves.count, (conflicts ? 1 : 0) + (canStop ? 1 : 0))
        if canStop { XCTAssertEqual(saves.last?["isActive"] as? Int, 0) }
        XCTAssertTrue(reloaded.pending.isEmpty)
        XCTAssertNil(reloaded.expectedStart(for: profile))
      }
    }
    let legacy = UUID()
    outbox.enqueue(profileId: legacy)
    XCTAssertNil(SessionStopOutbox().expectedStart(for: legacy))
    outbox.enqueue(profileId: legacy, expectedStart: now)
    XCTAssertEqual(outbox.pending, [legacy])
    outbox.clear()
    XCTAssertNil(SessionStopOutbox().expectedStart(for: legacy))
  }

  @MainActor
  func testCompletedScheduleMirrorRetriesMatchingConflictWithOriginalEndTime() async throws {
    let now = Date()
    let suiteName = "CountdownRetry-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    let sync = ProfileSyncManager.shared
    let wasEnabled = sync.isEnabled
    sync.isEnabled = true
    defer {
      sync.isEnabled = wasEnabled
      UserDefaults().removePersistentDomain(forName: suiteName)
    }
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Timer")
    context.insert(profile)
    let session = BlockedProfileSession.createSession(
      in: context, withTag: profile.id.uuidString, withProfile: profile, startTime: now)
    SharedData.endActiveSharedSession()
    let active = record(profile: profile.id, start: now, owner: "other-device", deadline: nil)
    let saved = expectation(description: "conflicting completion retried successfully")
    let server = TimerCASRecords(records: [active, active, active], failuresRemaining: 1) { saved.fulfill() }
    let service = SessionSyncService(fetchRecord: { _ in try await server.fetch() }, saveRecord: { try await server.save($0) })
    let manager = StrategyManager(sessionSyncService: service)

    try manager.loadActiveSession(context: context)
    await fulfillment(of: [saved], timeout: 5)

    let saves = await server.saves
    XCTAssertEqual(saves.count, 2)
    XCTAssertEqual(saves.last?["endTime"] as? Date, session.endTime)
    XCTAssertEqual(saves.first?["endTime"] as? Date, saves.last?["endTime"] as? Date)
    XCTAssertEqual(saves.last?["isActive"] as? Int, 0)
  }
  func testMirrorAuthorizedStopWithTimerCannotEndReplacementAfterConflict() async {
    let now = Date()
    let profile = UUID()
    let id = UUID().uuidString
    for replacement in [false, true] {
      let active = record(profile: profile, start: now, owner: "other-device", deadline: now.addingTimeInterval(2207))
      active["sessionId"] = id
      let newer = active.copy() as! CKRecord
      newer["sessionId"] = replacement ? UUID().uuidString : id
      let server = TimerCASRecords(records: [active, newer], failuresRemaining: replacement ? 1 : 0)
      let service = SessionSyncService(fetchRecord: { _ in try await server.fetch() }, saveRecord: { try await server.save($0) })
      let result = await service.stopSession(profileId: profile, endTime: now, expectedSessionId: id, expectedStart: now)
      if replacement {
        guard case .alreadyStopped = result else {
          XCTFail("Exact ID mismatch must resolve without replacement stop")
          continue
        }
      } else {
        guard case .stopped = result else {
          XCTFail("Mirror may stop the canonical timed session")
          continue
        }
      }
      let saves = await server.saves
      XCTAssertEqual(saves.count, 1)
    }
  }

  func testNewCASStartWritesCanonicalIdentityAndOrigin() async throws {
    let now = Date()
    let profile = UUID()
    let id = UUID().uuidString
    let server = TimerCASRecords(records: [], failSave: false)
    let service = SessionSyncService(fetchRecord: { _ in try await server.fetch() }, saveRecord: { try await server.save($0) })
    let origin = SessionOrigin(kind: .nfc, key: "UID", namespace: .nfcUID)
    let result = await service.startSession(profileId: profile, startTime: now, timerEndTime: now.addingTimeInterval(2207), sessionId: id, origin: origin)
    guard case .started = result else { return XCTFail("Must publish") }
    let saved = await server.saves
    let record = try XCTUnwrap(saved.last)
    XCTAssertEqual(record["sessionId"] as? String, id)
    XCTAssertEqual(ProfileSessionRecord(from: record)?.origin, origin)
  }

  @MainActor
  func testOfflineStopThenStartResolvesExactOldIntentBeforePublishingNewCountdown() async throws {
    let now = Date()
    let name = "OfflineRestart-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    SharedData.configure(suite: defaults)
    let sync = ProfileSyncManager.shared
    let wasEnabled = sync.isEnabled
    sync.isEnabled = true
    defer {
      sync.isEnabled = wasEnabled
      defaults.removePersistentDomain(forName: name)
    }
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Timer", createdAt: now, updatedAt: now)
    profile.startTriggers = .init(manual: true)
    profile.stopConditions = .init(timer: true, timerDurationMinutes: 37)
    context.insert(profile)
    let old = BlockedProfileSession(
      tag: "manual", blockedProfile: profile,
      startTime: now.addingTimeInterval(-600), origin: .init(kind: .manual))
    context.insert(old)
    old.endSession(now: now.addingTimeInterval(-1))
    try context.save()
    var record = ProfileSessionRecord(profileId: profile.id)
    record.applyUpdate(
      isActive: true, sequenceNumber: 1, deviceId: SharedData.deviceSyncId.uuidString,
      startTime: old.startTime, timerEndTime: now.addingTimeInterval(1600),
      sessionId: old.id, origin: .init(kind: .manual))
    let published = expectation(description: "old stop followed by new canonical start")
    let server = RestartCASRecord(record: record.toCKRecord(in: CKRecordZone.ID(zoneName: "Test"))) {
      published.fulfill()
    }
    let service = SessionSyncService(
      fetchRecord: { _ in await server.fetch() },
      saveRecord: { await server.save($0) })
    var canceled: [String] = []
    let manager = StrategyManager(
      sessionSyncService: service,
      registerTimer: { _, _, _, _ in now.addingTimeInterval(2207) },
      cancelTimer: { _, id in canceled.append(id) })
    defer {
      manager.stopTimer()
      manager.sessionStopOutbox.clear()
    }
    manager.sessionStopOutbox.clear()
    manager.sessionStopOutbox.enqueue(profileId: profile.id, expectedStart: old.startTime, expectedSessionId: old.id)

    let candidate = try manager.startOriginatingSession(
      context: context, profile: profile,
      origin: .init(kind: .manual), now: now)
    let candidateId = candidate.id
    await fulfillment(of: [published], timeout: 5)

    let saves = await server.saves
    XCTAssertEqual(saves.count, 2)
    XCTAssertEqual(saves.first?["isActive"] as? Int, 0)
    XCTAssertEqual(saves.last?["sessionId"] as? String, candidateId)
    XCTAssertNotEqual(candidateId, old.id)
    XCTAssertEqual(manager.activeSession?.id, candidateId)
    XCTAssertEqual(manager.activeSession?.timerEndTime, now.addingTimeInterval(2207))
    XCTAssertTrue(canceled.isEmpty)
    XCTAssertTrue(manager.sessionStopOutbox.pending.isEmpty)
    XCTAssertEqual(try context.fetch(FetchDescriptor<BlockedProfileSession>()).count, 2)
  }

}

private actor TimerCASRecords {
  var records: [CKRecord]
  var saves: [CKRecord] = []
  var failuresRemaining: Int
  let onSave: (@Sendable () -> Void)?
  init(records: [CKRecord], failSave: Bool = true, failuresRemaining: Int? = nil, onSave: (@Sendable () -> Void)? = nil) {
    self.records = records
    self.failuresRemaining = failuresRemaining ?? (failSave ? Int.max : 0)
    self.onSave = onSave
  }
  func fetch() throws -> CKRecord {
    guard !records.isEmpty else { throw CKError(.unknownItem) }
    return records.removeFirst().copy() as! CKRecord
  }
  func save(_ record: CKRecord) throws -> CKRecord {
    saves.append(record.copy() as! CKRecord)
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw CKError(.serverRecordChanged)
    }
    onSave?()
    return record
  }
}

private actor RestartCASRecord {
  var record: CKRecord
  var saves: [CKRecord] = []
  let onStart: @Sendable () -> Void
  init(record: CKRecord, onStart: @escaping @Sendable () -> Void) {
    self.record = record
    self.onStart = onStart
  }
  func fetch() -> CKRecord { record.copy() as! CKRecord }
  func save(_ value: CKRecord) -> CKRecord {
    record = value.copy() as! CKRecord
    saves.append(record)
    if value["isActive"] as? Int == 1 { onStart() }
    return value
  }
}

private actor OrderingCASRecords {
  var record: CKRecord
  var saves: [CKRecord] = []
  let onSave: @Sendable () -> Void
  init(record: CKRecord, onSave: @escaping @Sendable () -> Void) {
    self.record = record
    self.onSave = onSave
  }
  func fetch(_ id: CKRecord.ID) throws -> CKRecord {
    guard id.recordName == record.recordID.recordName else { throw CKError(.unknownItem) }
    return record.copy() as! CKRecord
  }
  func save(_ value: CKRecord) -> CKRecord {
    record = SessionServerDatedRecord(copying: value, modifiedAt: Date(timeIntervalSinceReferenceDate: 9000 + Double(saves.count)))
    saves.append(record)
    onSave()
    return record
  }
}

private actor DeferredStartCASRecord {
  var record: CKRecord
  var offline = true
  var fetchCount = 0
  let onFailure: @Sendable () -> Void
  init(record: CKRecord, onFailure: @escaping @Sendable () -> Void) {
    self.record = record
    self.onFailure = onFailure
  }
  func fetch() throws -> CKRecord {
    fetchCount += 1
    if offline {
      onFailure()
      throw CKError(.networkUnavailable)
    }
    return record
  }
  func save(_ value: CKRecord) -> CKRecord {
    let saved = SessionServerDatedRecord(copying: value, modifiedAt: Date(timeIntervalSinceReferenceDate: 9000))
    record = saved
    return saved
  }
  func reconnect(record: CKRecord) {
    self.record = record
    offline = false
  }
}
