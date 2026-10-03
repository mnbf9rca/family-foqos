import CloudKit
import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

final class SessionTimerCASTests: XCTestCase {
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
