import CloudKit
import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SessionRecoveryTests: XCTestCase {
  private var container: ModelContainer!
  private var defaults: UserDefaults!
  private var suiteName: String!
  private var activityStarts = 0
  private var applier: RecordingRestrictionApplier!
  private var manager: StrategyManager!
  private var syncWasEnabled = false

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  private var wednesday: Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: 18))!
  }

  private func time(_ hour: Int, _ minute: Int = 0, day: Int = 0) -> Date {
    wednesday.addingTimeInterval(TimeInterval(day * 86_400 + hour * 3600 + minute * 60))
  }

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "SessionRecoveryTests-\(UUID())"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
    SharedData.configureLockPath(FileManager.default.temporaryDirectory.appendingPathComponent(suiteName).path)
    container = try TestModelContainer.create()
    applier = RecordingRestrictionApplier()
    syncWasEnabled = ProfileSyncManager.shared.isEnabled
    ProfileSyncManager.shared.isEnabled = false
  }

  override func tearDown() async throws {
    manager?.stopTimer()
    ProfileSyncManager.shared.isEnabled = syncWasEnabled
    defaults.removePersistentDomain(forName: suiteName)
    SharedData.resetLockPath()
    try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(suiteName))
    try await super.tearDown()
  }

  private func configureManager(delivery: Date) {
    manager = StrategyManager(
      appBlocker: applier, remoteActiveDefaults: defaults,
      startSessionActivity: { [weak self] _ in self?.activityStarts += 1 },
      currentDate: { delivery }, calendar: calendar)
  }

  func testEndedInstanceCannotBeAdoptedAgain() throws {
    try assertIncidentRejected(sameIdentity: true)
  }

  func testRemoteIdentityFromStoppedOccurrenceCannotBeAdopted() throws {
    try assertIncidentRejected(sameIdentity: false)
  }

  func testCompletionSurvivesFailedHistorySaveAndIsReplayed() throws {
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Completed")
    profile.profileSchemaVersion = 2
    context.insert(profile)
    try context.save()
    let owner = SharedData.SessionSnapshot(
      id: UUID().uuidString, tag: "schedule", blockedProfileId: profile.id,
      startTime: time(15, 20), forceStarted: false, origin: .init(kind: .schedule))
    SharedData.createActiveSharedSession(for: owner)
    XCTAssertTrue(SharedData.completeSession(expectedSessionId: owner.id, now: time(18, 4)))
    struct SaveFailure: Error {}
    let delivery = time(20, 18)
    manager = StrategyManager(
      appBlocker: applier, remoteActiveDefaults: defaults,
      saveSession: { _ in throw SaveFailure() }, currentDate: { delivery }, calendar: calendar)

    XCTAssertThrowsError(try manager.loadActiveSession(context: context))
    XCTAssertEqual(SharedData.completedSessionsInScheduler.map(\.id), [owner.id])

    configureManager(delivery: time(20, 18))
    let reopened = ModelContext(container)
    try manager.loadActiveSession(context: reopened)
    try manager.loadActiveSession(context: reopened)
    XCTAssertNil(manager.activeSession)
    XCTAssertTrue(SharedData.completedSessionsInScheduler.isEmpty)
    let rows = try ModelContext(container).fetch(FetchDescriptor<BlockedProfileSession>())
    XCTAssertEqual(rows.map(\.id), [owner.id])
    XCTAssertEqual(rows.first?.endTime, time(18, 4))
  }

  func testInterruptedAdoptionRestoresOnlySharedOwner() throws {
    configureManager(delivery: time(21, 52))
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Split")
    profile.profileSchemaVersion = 2
    context.insert(profile)
    let abandoned = BlockedProfileSession(
      tag: "schedule", blockedProfile: profile, startTime: time(6),
      origin: .init(kind: .schedule))
    abandoned.sessionStartSyncPending = true
    context.insert(abandoned)
    try context.save()
    BlockedProfiles.updateSnapshot(for: profile)
    let owner = SharedData.SessionSnapshot(
      id: UUID().uuidString, tag: "remote-sync", blockedProfileId: profile.id,
      startTime: time(6, 1), forceStarted: true, origin: .init(kind: .schedule))
    SharedData.createActiveSharedSession(for: owner)

    try manager.loadActiveSession(context: ModelContext(container))
    try manager.loadActiveSession(context: ModelContext(container))
    XCTAssertEqual(manager.activeSession?.id, owner.id)
    let rows = try ModelContext(container).fetch(FetchDescriptor<BlockedProfileSession>())
    XCTAssertEqual(rows.filter(\.isActive).map(\.id), [owner.id])
    let obsolete = try XCTUnwrap(rows.first { $0.id == abandoned.id })
    XCTAssertEqual(obsolete.endTime, owner.startTime)
    XCTAssertFalse(obsolete.sessionStartSyncPending)
  }

  func testAdoptedSlotIsRecoveredAfterAnInjectedRowSaveFailure() throws {
    let delivery = time(20, 18)
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Interrupted adoption")
    context.insert(profile)
    try context.save()
    struct SaveFailure: Error {}
    manager = StrategyManager(
      appBlocker: applier, remoteActiveDefaults: defaults, saveSession: { _ in throw SaveFailure() },
      currentDate: { delivery }, calendar: calendar)
    let adopted = UUID()
    manager.startRemoteSession(
      context: context, profileId: profile.id, sessionId: adopted,
      startTime: time(19), origin: .init(kind: .manual))

    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, adopted.uuidString)
    XCTAssertNil(try BlockedProfileSession.findSession(byID: adopted.uuidString, in: ModelContext(container)))

    configureManager(delivery: delivery)
    let reopened = ModelContext(container)
    try manager.loadActiveSession(context: reopened)
    try manager.loadActiveSession(context: reopened)
    XCTAssertEqual(try manager.controlSession(context: reopened)?.id, adopted.uuidString)
    XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<BlockedProfileSession>()).map(\.id), [adopted.uuidString])
  }

  func testOccurrenceUsesSourceStartWeekdayEditTimeAndIndependentStop() {
    let profile = BlockedProfiles(name: "Recurrence")
    profile.startTriggers = .init(schedule: true)
    profile.stopConditions = .init(schedule: true)
    profile.startSchedule = .init(days: [.monday], hour: 9, minute: 0, updatedAt: time(0, day: -8))
    profile.stopSchedule = .init(days: [.friday], hour: 17, minute: 0, updatedAt: time(0, day: -8))
    func allowed(start: Date, delivery: Date, kind: SessionOrigin.Kind?, deadline: Date? = nil) -> Bool {
      SharedData.sessionTimingAllowsAdmission(
        startedAt: start, deadline: deadline, origin: kind.map { SessionOrigin(kind: $0) },
        profile: BlockedProfiles.getSnapshot(for: profile), now: delivery, calendar: calendar)
    }
    XCTAssertTrue(allowed(start: time(9, day: -2), delivery: time(20), kind: .schedule))
    XCTAssertFalse(allowed(start: time(9, day: -2), delivery: time(17, day: 2), kind: .schedule))

    profile.startSchedule = .init(days: [.wednesday, .thursday], hour: 15, minute: 20, updatedAt: time(0, day: -1))
    profile.stopSchedule = .init(days: [.wednesday], hour: 15, minute: 20, updatedAt: time(0, day: -1))
    XCTAssertFalse(allowed(start: time(15, 20), delivery: time(15, 20), kind: .manual))
    profile.stopSchedule?.updatedAt = time(16)
    XCTAssertTrue(allowed(start: time(15, 20), delivery: time(20), kind: .schedule))
    profile.scheduleLastStoppedAt = time(15, 22)
    XCTAssertFalse(allowed(start: time(15, 24), delivery: time(20), kind: .schedule))
    XCTAssertTrue(allowed(start: time(15, 24), delivery: time(20), kind: nil))
    XCTAssertTrue(allowed(start: time(15, 24), delivery: time(20), kind: .manual))
    XCTAssertTrue(allowed(start: time(15, 20, day: 1), delivery: time(16, day: 1), kind: .schedule))
    XCTAssertFalse(allowed(start: time(15, 24), delivery: time(20), kind: .manual, deadline: time(20)))
    XCTAssertTrue(allowed(start: time(15, 24), delivery: time(20), kind: .manual, deadline: time(20, 1)))
  }

  func testOwnerRestoresAfterUndeliveredStopWithoutPublishingOrUnshielding() async throws {
    let delivery = time(20, 18)
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Live owner")
    profile.startTriggers = .init(schedule: true)
    profile.stopConditions = .init(manual: true, schedule: true)
    profile.stopSchedule = .init(days: [.wednesday], hour: 18, minute: 0, updatedAt: time(0))
    context.insert(profile)
    let session = BlockedProfileSession(
      tag: "schedule", blockedProfile: profile, startTime: time(15, 20), origin: .init(kind: .schedule))
    session.sessionStartSyncPending = true
    context.insert(session)
    try context.save()
    SharedData.setSnapshot(BlockedProfiles.getSnapshot(for: profile), for: profile.id.uuidString, now: delivery)
    SharedData.createActiveSharedSession(for: session.toSnapshot())
    ProfileSyncManager.shared.isEnabled = true
    let network = SessionSyncService(
      fetchRecord: { _ in
        XCTFail("An expired historical owner cannot be published")
        throw CKError(.networkUnavailable)
      })
    manager = StrategyManager(
      sessionSyncService: network, appBlocker: applier, remoteActiveDefaults: defaults,
      currentDate: { delivery }, calendar: calendar)
    try manager.loadActiveSession(context: context)
    await manager.drainSessionStopOutbox()

    XCTAssertEqual(try manager.controlSession(context: context)?.local?.id, session.id)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, session.id)
    XCTAssertNil(session.endTime)
    XCTAssertFalse(applier.calls.contains(.deactivate))
  }

  func testCorruptSlotDefersNormalizationAndIdleRecoveryDoesNotRepublish() async throws {
    let delivery = time(21, 52)
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Idle split")
    context.insert(profile)
    let row = BlockedProfileSession(
      tag: "schedule", blockedProfile: profile, startTime: time(6), origin: .init(kind: .schedule))
    row.sessionStartSyncPending = true
    context.insert(row)
    try context.save()
    let key = "family_foqos_active_schedule_session"
    let corrupt = Data("not a session".utf8)
    defaults.set(corrupt, forKey: key)
    configureManager(delivery: delivery)
    XCTAssertThrowsError(try manager.loadActiveSession(context: context))
    XCTAssertEqual(defaults.data(forKey: key), corrupt)
    XCTAssertTrue(row.isActive)
    XCTAssertTrue(applier.calls.isEmpty)

    defaults.removeObject(forKey: key)
    try manager.loadActiveSession(context: context)
    await manager.drainSessionStopOutbox()
    XCTAssertNil(try manager.controlSession(context: context))
    XCTAssertFalse(row.sessionStartSyncPending)
    XCTAssertEqual(row.endTime, delivery)
  }

  func testRemoteInactiveDeliveryRefreshesSessionBeforeSelectingStopTarget() throws {
    configureManager(delivery: time(20, 18))
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Replacement")
    context.insert(profile)
    let old = BlockedProfileSession(
      tag: "manual", blockedProfile: profile, startTime: time(15), origin: .init(kind: .manual))
    context.insert(old)
    try context.save()
    manager.activeSession = old
    let replacement = SharedData.SessionSnapshot(
      id: UUID().uuidString, tag: "remote-sync", blockedProfileId: profile.id,
      startTime: time(19), forceStarted: true, origin: .init(kind: .manual))
    SharedData.createActiveSharedSession(for: replacement)

    manager.stopRemoteSession(context: context, profileId: profile.id, expectedSessionId: old.id, sequenceNumber: 2)

    XCTAssertEqual(manager.activeSession?.id, replacement.id)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, replacement.id)
    XCTAssertTrue(try XCTUnwrap(manager.activeSession).isActive)
    XCTAssertFalse(applier.calls.contains(.deactivate))
  }

  func testCompletionIsKeptWhenRequiredOutboxCannotBeWritten() throws {
    configureManager(delivery: time(20, 18))
    ProfileSyncManager.shared.isEnabled = true
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Outbox")
    context.insert(profile)
    try context.save()
    let owner = SharedData.SessionSnapshot(
      id: UUID().uuidString, tag: "manual", blockedProfileId: profile.id,
      startTime: time(15, 20), forceStarted: false, origin: .init(kind: .manual))
    SharedData.createActiveSharedSession(for: owner)
    XCTAssertTrue(SharedData.completeSession(expectedSessionId: owner.id, now: time(18, 4)))
    defaults.set(Data("not an outbox".utf8), forKey: "family_foqos_session_stop_intents")

    XCTAssertThrowsError(try manager.loadActiveSession(context: context))
    XCTAssertEqual(try BlockedProfileSession.findSession(byID: owner.id, in: ModelContext(container))?.endTime, time(18, 4))
    XCTAssertEqual(SharedData.completedSessionsInScheduler.map(\.id), [owner.id])

    ProfileSyncManager.shared.isEnabled = false
    try manager.loadActiveSession(context: ModelContext(container))
    XCTAssertTrue(SharedData.completedSessionsInScheduler.isEmpty)
    XCTAssertNil(manager.activeSession)
  }

  private func assertIncidentRejected(sameIdentity: Bool) throws {
    configureManager(delivery: time(20, 18))
    let context = container.mainContext
    let profile = BlockedProfiles(name: "After school")
    profile.profileSchemaVersion = 2
    profile.startSchedule = ProfileScheduleTime(
      days: [.wednesday, .thursday], hour: 15, minute: 20, updatedAt: time(0, day: -1))
    profile.stopSchedule = ProfileScheduleTime(
      days: [.wednesday, .thursday], hour: 18, minute: 0, updatedAt: time(0, day: -1))
    profile.startTriggers = ProfileStartTriggers(schedule: true)
    profile.stopConditions = ProfileStopConditions(schedule: true)
    profile.scheduleLastStoppedAt = time(18, 4)
    context.insert(profile)
    let localId = UUID()
    let ended = BlockedProfileSession(
      tag: "schedule", blockedProfile: profile, startTime: time(15, 20),
      id: localId.uuidString, origin: .init(kind: .schedule))
    ended.usesCanonicalIdentity = true
    ended.endSession(now: time(18, 4))
    context.insert(ended)
    try context.save()

    let remoteId = sameIdentity ? localId : UUID()
    let start = time(15, sameIdentity ? 20 : 24)
    var remote = ProfileSessionRecord(profileId: profile.id)
    remote.applyUpdate(
      isActive: true, sequenceNumber: 1, deviceId: "remote", startTime: start,
      sessionId: remoteId.uuidString, origin: .init(kind: .schedule))

    XCTAssertFalse(try manager.receiveSessionRecord(remote, context: context))
    manager.startRemoteSession(
      context: context, profileId: profile.id, sessionId: remoteId,
      startTime: start, origin: .init(kind: .schedule))

    XCTAssertNil(manager.remoteOnlySessionRecord(profileIds: [profile.id]))
    XCTAssertTrue(manager.remotelyActiveProfileIds.isEmpty)
    XCTAssertNil(manager.activeSession)
    XCTAssertNil(SharedData.getActiveSharedSession())
    XCTAssertTrue(applier.calls.isEmpty)
    XCTAssertEqual(activityStarts, 0)
    XCTAssertEqual(ended.endTime, time(18, 4))
    XCTAssertTrue(try context.fetch(FetchDescriptor<BlockedProfileSession>()).allSatisfy { !$0.isActive })
  }
}
