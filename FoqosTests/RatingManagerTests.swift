import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class RatingManagerTests: XCTestCase {
  private var suite: String!
  private var defaults: UserDefaults!
  private var calendar: Calendar!
  private var requests = 0
  private var hasScene = true
  private var failSave = false
  private var container: ModelContainer!
  private var manager: StrategyManager!
  private var syncWasEnabled = false
  private var context: ModelContext { container.mainContext }

  override func setUp() async throws {
    suite = "RatingManagerTests-\(UUID())"
    defaults = UserDefaults(suiteName: suite)!
    SharedData.configure(suite: defaults)
    calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 3600)!
    container = try TestModelContainer.create()
    syncWasEnabled = ProfileSyncManager.shared.isEnabled
    ProfileSyncManager.shared.isEnabled = false
  }

  override func tearDown() async throws {
    manager?.stopTimer()
    ProfileSyncManager.shared.isEnabled = syncWasEnabled
    defaults.removePersistentDomain(forName: suite)
  }

  private func rating(version: String = "test") -> RatingManager {
    RatingManager(defaults: defaults, calendar: calendar, currentVersion: version) {
      guard self.hasScene else { return false }
      self.requests += 1
      return true
    }
  }

  func testRepeatedCompletionsNeedThreeDaysAndSurviveRelaunch() {
    let now = Date()
    let first = rating()
    for _ in 0..<5 { first.recordSuccessfulSessionEnd(now: now) }
    XCTAssertEqual(requests, 0)
    rating().recordSuccessfulSessionEnd(now: calendar.date(byAdding: .day, value: 1, to: now)!)
    XCTAssertEqual(requests, 0)
    rating().recordSuccessfulSessionEnd(now: calendar.date(byAdding: .day, value: 2, to: now)!)
    XCTAssertEqual(requests, 1)
    rating().recordSuccessfulSessionEnd(now: calendar.date(byAdding: .day, value: 3, to: now)!)
    XCTAssertEqual(requests, 1, "Do not request again for the same app version")
    rating(version: "next").recordSuccessfulSessionEnd(now: calendar.date(byAdding: .day, value: 4, to: now)!)
    XCTAssertEqual(requests, 2)
  }

  func testCompletionDaysUseLocalMidnight() {
    // UTC 22:30 is 23:30 in the injected calendar; an hour later is a new local day.
    let now = Date(timeIntervalSince1970: 1_767_306_600)
    let r = rating()
    r.recordSuccessfulSessionEnd(now: now)
    r.recordSuccessfulSessionEnd(now: now.addingTimeInterval(3600))
    XCTAssertEqual(requests, 0)
    r.recordSuccessfulSessionEnd(now: now.addingTimeInterval(25 * 3600))
    XCTAssertEqual(requests, 1)
  }

  func testNoActiveSceneDoesNotConsumeVersionOrRequestOnLaunch() {
    let now = Date()
    hasScene = false
    for day in 0..<3 { rating().recordSuccessfulSessionEnd(now: calendar.date(byAdding: .day, value: day, to: now)!) }
    XCTAssertEqual(requests, 0)
    hasScene = true
    let relaunched = rating()
    XCTAssertEqual(requests, 0, "Eligibility alone must not prompt on launch")
    relaunched.recordSuccessfulSessionEnd(now: calendar.date(byAdding: .day, value: 3, to: now)!)
    XCTAssertEqual(requests, 1)
  }

  func testOldTapCountCannotGrantEligibility() {
    let now = Date()
    defaults.set(500, forKey: "family_foqos_launch_count")
    rating().recordSuccessfulSessionEnd(now: now)
    XCTAssertEqual(requests, 0)
  }

  private func configureManager() {
    manager = StrategyManager(
      emergencyUnblockManager: EmergencyUnblockManager(defaults: defaults),
      appBlocker: RecordingRestrictionApplier(), startSessionActivity: { _ in },
      cancelPreActivationReminders: { _ in },
      saveSession: { context in
        if self.failSave { throw NSError(domain: "RatingSaveTest", code: 1) }
        try context.save()
      }, scheduleReconciler: { _ in }, ratingManager: rating())
  }

  private func start(now: Date) throws -> BlockedProfileSession {
    let profile = BlockedProfiles(name: "Rating", createdAt: now, updatedAt: now)
    profile.startTriggers = .init(manual: true)
    profile.stopConditions = .init(manual: true, nfc: .any)
    context.insert(profile)
    try context.save()
    return try manager.startOriginatingSession(context: context, profile: profile, origin: .init(kind: .manual), now: now)
  }

  private func stop(now: Date) async {
    await manager.handleTagEvent(
      .init(type: .nfc, namespace: .opaque, key: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
      operation: .scan, context: context, now: now)
  }

  func testNormalSessionCompletionsEarnReviewButRepeatedStopsDoNot() async throws {
    let now = Date()
    configureManager()
    for day in 0..<3 {
      let end = calendar.date(byAdding: .day, value: day, to: now)!
      let session = try start(now: end.addingTimeInterval(-60))
      await stop(now: end)
      XCTAssertFalse(session.isActive)
      XCTAssertNil(manager.errorMessage)
      XCTAssertEqual(requests, day == 2 ? 1 : 0)
    }
    await stop(now: now.addingTimeInterval(4 * 86400))
    XCTAssertEqual(requests, 1)
  }

  func testFailedSaveAndStopWithErrorCannotEarnReview() async throws {
    let now = Date()
    configureManager()
    for day in 0..<3 {
      let end = calendar.date(byAdding: .day, value: day, to: now)!
      _ = try start(now: end.addingTimeInterval(-60))
      failSave = true
      await stop(now: end)
      failSave = false
      try context.save()
    }
    for day in 3..<6 {
      let end = calendar.date(byAdding: .day, value: day, to: now)!
      _ = try start(now: end.addingTimeInterval(-60))
      manager.errorMessage = "A scheduling error is already visible"
      await stop(now: end)
    }
    // One ordinary completion must still be short of the threshold.
    let end = calendar.date(byAdding: .day, value: 6, to: now)!
    _ = try start(now: end.addingTimeInterval(-60))
    await stop(now: end)
    XCTAssertEqual(requests, 0)
  }

  func testEmergencyAndRefusedStartsCannotRequestReviewEvenWhenEligible() async throws {
    let now = Date()
    configureManager()
    hasScene = false
    for day in -3..<0 { rating().recordSuccessfulSessionEnd(now: calendar.date(byAdding: .day, value: day, to: now)!) }
    hasScene = true
    let session = try start(now: now.addingTimeInterval(-60))
    let other = BlockedProfiles(name: "Other", createdAt: now, updatedAt: now)
    context.insert(other)
    try context.save()
    manager.toggleBlocking(context: context, activeProfile: other)
    XCTAssertTrue(session.isActive)
    XCTAssertNotNil(manager.errorMessage)
    XCTAssertEqual(requests, 0)
    manager.errorMessage = nil
    try await manager.emergencyUnblock(context: context)
    XCTAssertFalse(session.isActive)
    XCTAssertEqual(requests, 0)
  }

  func testRemoteCompletionCannotRequestReviewEvenWhenEligible() throws {
    let now = Date()
    configureManager()
    hasScene = false
    for day in -3..<0 { rating().recordSuccessfulSessionEnd(now: calendar.date(byAdding: .day, value: day, to: now)!) }
    hasScene = true
    let session = try start(now: now.addingTimeInterval(-60))
    manager.stopRemoteSession(context: context, profileId: session.blockedProfile.id, expectedSessionId: session.id)
    XCTAssertFalse(session.isActive)
    XCTAssertEqual(requests, 0)
  }

}
