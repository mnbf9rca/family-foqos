import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class StrategyManagerRemoteSessionTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!
  private var manager: StrategyManager!
  private var appBlocker: RecordingRestrictionApplier!
  private var suiteName: String!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "StrategyManagerRemoteSessionTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    container = try TestModelContainer.create()
    context = container.mainContext
    appBlocker = RecordingRestrictionApplier()
    manager = StrategyManager(appBlocker: appBlocker)
    manager.sessionStopOutbox.clear()
  }

  override func tearDown() async throws {
    manager.stopTimer()
    manager.sessionStopOutbox.clear()
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  // #204: a remote start must converge on activateSession, not hand-roll a subset.
  // timerTask is the synchronous discriminator for activateSession's startTimer().
  func testGivenRemoteStart_WhenStartRemoteSession_ThenActiveSessionAndTimerStarted() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Focus")
    context.insert(profile)
    try context.save()

    manager.startRemoteSession(
      context: context, profileId: profile.id, sessionId: UUID(), startTime: now)

    XCTAssertEqual(
      manager.activeSession?.blockedProfile.id, profile.id,
      "remote session becomes the active session")
    XCTAssertEqual(manager.activeSession?.startTime, now, "synced startTime preserved")
    XCTAssertNotNil(
      manager.timerTask,
      "activateSession's startTimer() must run on the remote-start path (#204)")
  }

  // Guard: a remote start for a profile needing app selection must NOT activate.
  func testGivenProfileNeedsAppSelection_WhenStartRemoteSession_ThenNoActivation() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "NoApps")
    profile.needsAppSelection = true
    context.insert(profile)
    try context.save()

    manager.startRemoteSession(
      context: context, profileId: profile.id, sessionId: UUID(), startTime: now)

    XCTAssertNil(manager.activeSession, "cannot start remotely without local app selection")
    XCTAssertNil(manager.timerTask)
  }

  // #203 payload: the real stopRemoteSession must clear the manager's active session and stop
  // the timer. The SyncApplyService mock only proves the deletion path calls this seam.
  func testGivenRealActiveSession_WhenStopRemoteSession_ThenActiveSessionClearedAndTimerStopped()
    throws
  {
    let profile = BlockedProfiles(name: "Focus")
    context.insert(profile)
    let session = BlockedProfileSession(tag: "local", blockedProfile: profile)
    context.insert(session)
    try context.save()
    manager.activeSession = session
    manager.startTimer()
    XCTAssertNotNil(manager.timerTask, "precondition: timer running")

    manager.stopRemoteSession(context: context, profileId: profile.id)

    XCTAssertNil(manager.activeSession, "real stopRemoteSession clears the active session (#203)")
    XCTAssertNil(manager.timerTask, "real stopRemoteSession stops the timer (#203)")
    XCTAssertNotNil(session.endTime, "the session is ended")
  }

  func testGivenLocalNewerSession_WhenRemoteOlderStart_ThenRemoteRejected() throws {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let profileA = BlockedProfiles(name: "Local Newer")
    let profileB = BlockedProfiles(name: "Remote Older")
    context.insert(profileA)
    context.insert(profileB)
    let sessionA = BlockedProfileSession(tag: "local", blockedProfile: profileA, startTime: now)
    context.insert(sessionA)
    try context.save()
    manager.activeSession = sessionA

    manager.startRemoteSession(
      context: context,
      profileId: profileB.id,
      sessionId: UUID(),
      startTime: now.addingTimeInterval(-60))

    XCTAssertEqual(manager.activeSession?.blockedProfile.id, profileA.id)
    XCTAssertEqual(try activeSessions().map(\.blockedProfile.id), [profileA.id])
    XCTAssertTrue(appBlocker.calls.isEmpty)
  }

  func testGivenLocalOlderSession_WhenRemoteNewerStart_ThenLocalEndedAndRemoteAdopted() throws {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let profileA = BlockedProfiles(name: "Local Older")
    let profileB = BlockedProfiles(name: "Remote Newer")
    context.insert(profileA)
    context.insert(profileB)
    let sessionA = BlockedProfileSession(
      tag: "local", blockedProfile: profileA, startTime: now.addingTimeInterval(-60))
    context.insert(sessionA)
    try context.save()
    manager.activeSession = sessionA

    manager.startRemoteSession(
      context: context,
      profileId: profileB.id,
      sessionId: UUID(),
      startTime: now)

    XCTAssertEqual(manager.activeSession?.blockedProfile.id, profileB.id)
    XCTAssertEqual(try activeSessions().map(\.blockedProfile.id), [profileB.id])
    XCTAssertNotNil(sessionA.endTime)
    XCTAssertEqual(manager.sessionStopOutbox.pending, [profileA.id])
    XCTAssertEqual(appBlocker.calls, [.activate(profileId: profileB.id)])
  }

  func testGivenPendingStopForProfile_WhenRemoteSessionStarts_ThenPendingStopCleared() throws {
    let profile = BlockedProfiles(name: "Restarted")
    context.insert(profile)
    try context.save()
    manager.sessionStopOutbox.enqueue(profileId: profile.id)

    manager.startRemoteSession(
      context: context,
      profileId: profile.id,
      sessionId: UUID(),
      startTime: Date(timeIntervalSinceReferenceDate: 1_000))

    XCTAssertFalse(manager.sessionStopOutbox.pending.contains(profile.id))
  }

  func testGivenSameProfileActiveInStoreOnly_WhenRemoteStart_ThenNoDuplicateSessionCreated() throws {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let profile = BlockedProfiles(name: "Stored")
    context.insert(profile)
    let existing = BlockedProfileSession(
      tag: "local", blockedProfile: profile, startTime: now.addingTimeInterval(-60))
    context.insert(existing)
    try context.save()
    manager.activeSession = nil

    manager.startRemoteSession(
      context: context,
      profileId: profile.id,
      sessionId: UUID(),
      startTime: now)

    XCTAssertEqual(try activeSessions().map(\.id), [existing.id])
    XCTAssertTrue(appBlocker.calls.isEmpty)
  }

  private func activeSessions() throws -> [BlockedProfileSession] {
    try context.fetch(FetchDescriptor<BlockedProfileSession>()).filter { $0.endTime == nil }
  }
}
