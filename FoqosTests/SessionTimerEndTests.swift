import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SessionTimerEndTests: XCTestCase {
  private var suite: String!
  private var container: ModelContainer!
  private var context: ModelContext { container.mainContext }

  override func setUp() async throws {
    suite = "SessionTimerEndTests-\(UUID())"
    SharedData.configure(suite: UserDefaults(suiteName: suite)!)
    container = try TestModelContainer.create()
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: suite)
  }

  private func makeSession(now: Date, tag: String = ShortcutTimerBlockingStrategy.id) -> BlockedProfileSession {
    let profile = BlockedProfiles(name: "Timer")
    context.insert(profile)
    return BlockedProfileSession.createSession(in: context, withTag: tag, withProfile: profile, startTime: now)
  }

  func testOldTrueFlagDoesNotVetoExactSessionTimerExpiry() throws {
    let now = Date()
    var snapshot = BlockedProfiles.getSnapshot(for: BlockedProfiles(name: "Timer"))
    snapshot.disableBackgroundStops = true
    snapshot.stopConditions = .init(timer: true, timerDurationMinutes: 15)
    let deadline = now.addingTimeInterval(900)
    let session = SharedData.SessionSnapshot(
      id: UUID().uuidString, tag: "manual",
      blockedProfileId: snapshot.id, startTime: now, timerEndTime: deadline,
      forceStarted: false, origin: .init(kind: .manual))
    SharedData.createActiveSharedSession(for: session)
    let timer = StrategyTimerActivity()
    XCTAssertFalse(timer.stop(for: snapshot, sessionId: UUID().uuidString, now: deadline))
    XCTAssertEqual(SharedData.getActiveSharedSession(), session)
    XCTAssertTrue(timer.stop(for: snapshot, sessionId: session.id, now: deadline))
    XCTAssertNil(SharedData.getActiveSharedSession())
  }

  func testRegistrarSuccessFailureAndReplacementPublishExactResult() throws {
    let now = Date()
    for tag in [ShortcutTimerBlockingStrategy.id, NFCTimerBlockingStrategy.id, QRTimerBlockingStrategy.id] {
      let session = makeSession(now: now, tag: tag)
      let end = now.addingTimeInterval(901)
      XCTAssertNil(
        DeviceActivityCenterUtil.startStrategyTimerActivity(
          for: session.blockedProfile, session: session, durationInMinutes: 15, now: now,
          register: { _, minutes, registrationTime in
            XCTAssertEqual(minutes, 15)
            XCTAssertEqual(registrationTime, now)
            XCTAssertEqual(SharedData.getActiveSharedSession()?.id, session.id)
            return end
          }))
      XCTAssertEqual(session.timerEndTime, end)
      XCTAssertEqual(SharedData.getActiveSharedSession()?.timerEndTime, end)
      XCTAssertNotNil(
        DeviceActivityCenterUtil.startStrategyTimerActivity(
          for: session.blockedProfile, session: session, durationInMinutes: 30, now: now,
          register: { _, _, _ in throw NSError(domain: "registration", code: 1) }))
      XCTAssertNil(session.timerEndTime)
      XCTAssertNil(SharedData.getActiveSharedSession()?.timerEndTime)
      session.endSession(now: now)
    }
  }

  func testTimerIntervalMinutePrecisionClampAndMidnight() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 23, minute: 50, second: 42))!
    for minutes in [1, 15, 1439, 1440] {
      let result = DeviceActivityCenterUtil.timerInterval(from: minutes, now: now, calendar: calendar)
      let expected = now.addingTimeInterval(Double(min(minutes, 1439)) * 60 - 42)
      XCTAssertEqual(result.deadline, expected)
      XCTAssertEqual(result.end, calendar.dateComponents([.hour, .minute], from: expected))
    }
  }

  func testSnapshotColdReconstructionUpdatesAndEndClear() throws {
    let now = Date()
    let session = makeSession(now: now)
    session.origin = .init(kind: .nfc, key: "UID", namespace: .nfcUID)
    XCTAssertNil(session.timerEndTime)
    session.timerEndTime = now.addingTimeInterval(900)
    let data = try JSONEncoder().encode(session.toSnapshot())
    let snapshot = try JSONDecoder().decode(SharedData.SessionSnapshot.self, from: data)
    let cold = try TestModelContainer.create()
    cold.mainContext.insert(BlockedProfiles(id: session.blockedProfile.id, name: "Cold"))
    try cold.mainContext.save()
    BlockedProfileSession.upsertSessionFromSnapshot(in: cold.mainContext, withSnapshot: snapshot)
    let restored = try XCTUnwrap(BlockedProfileSession.findSession(byID: session.id, in: cold.mainContext))
    XCTAssertEqual(restored.timerEndTime, session.timerEndTime)
    XCTAssertEqual(restored.origin, session.origin)
    var updated = snapshot
    updated.timerEndTime = nil
    BlockedProfileSession.upsertSessionFromSnapshot(in: cold.mainContext, withSnapshot: updated)
    XCTAssertNil(restored.timerEndTime)
    updated = snapshot
    updated.endTime = now.addingTimeInterval(60)
    BlockedProfileSession.upsertSessionFromSnapshot(in: cold.mainContext, withSnapshot: updated)
    XCTAssertNil(restored.timerEndTime)
    session.endSession(now: now)
    XCTAssertNil(session.timerEndTime)
    var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy["origin"] = ["kind": "unknown"]
    let malformed = try JSONDecoder().decode(SharedData.SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
    XCTAssertEqual(malformed.id, session.id)
    XCTAssertNil(malformed.origin)
    legacy.removeValue(forKey: "timerEndTime")
    legacy.removeValue(forKey: "origin")
    legacy.removeValue(forKey: "usesCanonicalIdentity")
    XCTAssertNil(
      try JSONDecoder().decode(
        SharedData.SessionSnapshot.self,
        from: JSONSerialization.data(withJSONObject: legacy)
      ).timerEndTime)
  }

  func testSharedTimingPublicationPreservesGrantAndRefusesReplacement() throws {
    let now = Date()
    let session = makeSession(now: now)
    SharedData.setBreakStartTime(date: now, expectedSessionId: session.id)
    XCTAssertTrue(
      SharedData.updateSessionTiming(
        expectedSessionId: session.id, startTime: now,
        timerEndTime: now.addingTimeInterval(900)))
    XCTAssertEqual(SharedData.getActiveSharedSession()?.breakStartTime, now)
    let replacement = makeSession(now: now.addingTimeInterval(1))
    XCTAssertFalse(SharedData.updateSessionTiming(expectedSessionId: session.id, startTime: now, timerEndTime: now))
    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, replacement.id)
    XCTAssertNil(SharedData.getActiveSharedSession()?.timerEndTime)
  }

  func testCASAdoptionCancelsOnlyLosingCountdownAndRejectsStaleLocalID() throws {
    let now = Date()
    let session = makeSession(now: now)
    session.timerEndTime = now.addingTimeInterval(900)
    let manager = StrategyManager()
    manager.activeSession = session
    var canceled: [UUID] = []
    let reconcile: (String, String, Date?) -> Void = { id, owner, deadline in
      manager.reconcileSessionTiming(
        sessionId: id, profileId: session.blockedProfile.id,
        startTime: now, timerEndTime: deadline, originDevice: owner, context: self.context,
        cancelTimer: { canceled.append($0) })
    }
    reconcile(session.id, SharedData.deviceSyncId.uuidString, now.addingTimeInterval(900))
    XCTAssertTrue(canceled.isEmpty)
    reconcile("stale-id", "B", now.addingTimeInterval(1800))
    XCTAssertTrue(canceled.isEmpty)
    reconcile(session.id, "B", now.addingTimeInterval(1800))
    XCTAssertEqual(canceled, [session.blockedProfile.id])
    XCTAssertEqual(session.timerEndTime, now.addingTimeInterval(1800))
    XCTAssertEqual(SharedData.getActiveSharedSession()?.timerEndTime, session.timerEndTime)
    reconcile(session.id, "B", nil)
    XCTAssertNil(session.timerEndTime)
    XCTAssertNil(SharedData.getActiveSharedSession()?.timerEndTime)
  }

  func testRemoteAdoptionAndSameSessionUpdateDoNotStartCountdown() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Remote")
    context.insert(profile)
    try context.save()
    let manager = StrategyManager()
    defer { manager.stopTimer() }
    let id = UUID()
    manager.startRemoteSession(
      context: context, profileId: profile.id, sessionId: id, startTime: now,
      timerEndTime: now.addingTimeInterval(900), originDevice: "B", serverModificationDate: now)
    let session = try XCTUnwrap(manager.activeSession)
    XCTAssertEqual(session.tag, "remote-sync")
    XCTAssertEqual(session.timerEndTime, now.addingTimeInterval(900))
    XCTAssertEqual(SharedData.getActiveSharedSession()?.timerEndTime, now.addingTimeInterval(900))
    manager.startRemoteSession(
      context: context, profileId: profile.id, sessionId: id, startTime: now,
      timerEndTime: nil, originDevice: "B", serverModificationDate: now)
    XCTAssertEqual(manager.activeSession?.id, session.id)
    XCTAssertNil(session.timerEndTime)
    XCTAssertNil(SharedData.getActiveSharedSession()?.timerEndTime)
  }
  func testSessionTimerDeadlinePersistsOnDisk() throws {
    let now = Date()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("sessions.store")
    let schema = Schema([BlockedProfiles.self, BlockedProfileSession.self, SavedLocation.self, SavedTag.self])
    var disk: ModelContainer? = try ModelContainer(
      for: schema,
      configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
    let id = try autoreleasepool {
      let context = ModelContext(try XCTUnwrap(disk))
      let profile = BlockedProfiles(name: "Persisted")
      context.insert(profile)
      let session = BlockedProfileSession(tag: "timer", blockedProfile: profile, startTime: now)
      session.origin = .init(kind: .qr, key: "DIGEST", namespace: .qrDigest)
      session.usesCanonicalIdentity = true
      session.sessionServerModificationDate = now
      session.sessionStartSyncPending = true
      session.timerEndTime = now.addingTimeInterval(900)
      context.insert(session)
      try context.save()
      return session.id
    }
    disk = nil
    let reopened = try ModelContainer(
      for: schema,
      configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
    let restored = try XCTUnwrap(BlockedProfileSession.findSession(byID: id, in: reopened.mainContext))
    XCTAssertEqual(restored.timerEndTime, now.addingTimeInterval(900))
    XCTAssertEqual(restored.origin, .init(kind: .qr, key: "DIGEST", namespace: .qrDigest))
    XCTAssertEqual(restored.usesCanonicalIdentity, true)
    XCTAssertEqual(restored.sessionServerModificationDate, now)
    XCTAssertTrue(restored.sessionStartSyncPending)
  }
  func testCASWinnerReplacesIdentityAndCancelsOnlyCandidateTimer() throws {
    let now = Date()
    let candidate = makeSession(now: now)
    candidate.origin = .init(kind: .nfc, key: "LOSER", namespace: .nfcUID)
    candidate.usesCanonicalIdentity = true
    candidate.timerEndTime = now.addingTimeInterval(900)
    SharedData.createActiveSharedSession(for: candidate.toSnapshot())
    let oldId = candidate.id
    let winnerId = UUID().uuidString
    let winnerOrigin = SessionOrigin(kind: .qr, key: "WINNER", namespace: .qrDigest)
    var canceled: [String] = []
    let sut = StrategyManager(
      registerTimer: { _, _, _, _ in
        XCTFail("Adoption never registers")
        return now
      }, cancelTimer: { _, id in canceled.append(id) })
    sut.activeSession = candidate
    sut.reconcileSessionTiming(
      sessionId: oldId, profileId: candidate.blockedProfile.id, startTime: now,
      timerEndTime: now.addingTimeInterval(2207), originDevice: "other-owner", context: context, canonicalSessionId: winnerId, origin: winnerOrigin)
    XCTAssertEqual(candidate.id, winnerId)
    XCTAssertEqual(candidate.origin, winnerOrigin)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, winnerId)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.origin, winnerOrigin)
    XCTAssertEqual(canceled, [oldId])
    XCTAssertEqual(candidate.timerEndTime, now.addingTimeInterval(2207))
    sut.reconcileSessionTiming(
      sessionId: oldId, profileId: candidate.blockedProfile.id, startTime: now,
      timerEndTime: nil, originDevice: "stale-owner", context: context, canonicalSessionId: UUID().uuidString, origin: nil)
    XCTAssertEqual(candidate.id, winnerId)
    XCTAssertEqual(candidate.origin, winnerOrigin)
    XCTAssertEqual(canceled, [oldId])
  }

}
