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
}
