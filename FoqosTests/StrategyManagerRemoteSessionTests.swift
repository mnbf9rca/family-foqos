import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class StrategyManagerRemoteSessionTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!
  private var manager: StrategyManager!
  private var suiteName: String!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "StrategyManagerRemoteSessionTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    container = try TestModelContainer.create()
    context = container.mainContext
    manager = StrategyManager()
  }

  override func tearDown() async throws {
    manager.stopTimer()
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
}
