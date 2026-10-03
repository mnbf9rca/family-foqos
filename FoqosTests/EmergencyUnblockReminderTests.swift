import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class EmergencyUnblockReminderTests: XCTestCase {
  func testGivenReminderSet_WhenEmergencyUnblock_ThenSessionReminderScheduledExactlyOnce()
    async throws
  {
    let container = try TestModelContainer.create()
    let context = ModelContext(container)
    let profile = BlockedProfiles(name: "Focus")
    profile.reminderTimeInSeconds = 1_800
    context.insert(profile)
    let session = BlockedProfileSession.createSession(
      in: context,
      withTag: ManualBlockingStrategy.id,
      withProfile: profile,
      forceStart: true
    )
    try context.save()

    let defaults = UserDefaults(suiteName: "EmergencyUnblockReminderTests-\(UUID().uuidString)")!
    let emergencyManager = EmergencyUnblockManager(defaults: defaults)
    emergencyManager.seedForTesting(epoch: 1)
    let timersUtil = CountingTimersUtil()
    let manager = StrategyManager(
      emergencyUnblockManager: emergencyManager,
      timersUtil: timersUtil
    )

    _ = session
    try await manager.emergencyUnblock(context: context)

    XCTAssertEqual(
      timersUtil.scheduleCount(prefix: TimersUtil.sessionReminderPrefix),
      1,
      "Emergency unblock must schedule the post-session reminder exactly once"
    )
  }
  func testEmergencyFallbackEndsIdleAndUndecodableStoreWithoutSpendingFailedStops() async throws {
    let now = Date()
    for state in ["idle", "corrupt", "different", "unlocked"] {
      let name = "EmergencyFallback-" + UUID().uuidString
      let defaults = UserDefaults(suiteName: name)!
      defer { defaults.removePersistentDomain(forName: name) }
      SharedData.configure(suite: defaults)
      let container = try TestModelContainer.create()
      let context = container.mainContext
      let profile = BlockedProfiles(name: "Focus", createdAt: now, updatedAt: now)
      context.insert(profile)
      let session = BlockedProfileSession(tag: "manual", blockedProfile: profile, startTime: now)
      context.insert(session)
      try context.save()
      if state == "corrupt" { defaults.set(Data("bad JSON".utf8), forKey: "family_foqos_active_schedule_session") }
      if state == "different" { SharedData.createSessionForScheduler(for: UUID()) }
      if state == "unlocked" { SharedData.configureLockPath(nil) }
      defer { SharedData.resetLockPath() }
      let emergency = EmergencyUnblockManager(defaults: defaults)
      emergency.seedForTesting(epoch: 1)
      let count = emergency.getRemainingEmergencyUnblocks()
      let manager = StrategyManager(emergencyUnblockManager: emergency)
      manager.activeSession = session
      do {
        try await manager.emergencyUnblock(context: context)
        XCTAssertTrue(state == "idle" || state == "corrupt")
      } catch {
        XCTAssertTrue(state == "different" || state == "unlocked")
      }
      let stopped = state == "idle" || state == "corrupt"
      XCTAssertEqual(session.endTime != nil, stopped)
      XCTAssertEqual(emergency.getRemainingEmergencyUnblocks(), count - (stopped ? 1 : 0))
      manager.stopTimer()
    }
  }

}
