import Foundation
import XCTest

@testable import FamilyFoqos

private struct StopOutboxTestError: Error {}

@MainActor
final class SessionStopOutboxTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "stop-outbox-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    try await super.tearDown()
  }

  func testGivenEnqueue_WhenReloaded_ThenPersistsAndDeduplicates() {
    let id = UUID()
    let outbox = SessionStopOutbox(defaults: defaults)
    outbox.enqueue(profileId: id)
    outbox.enqueue(profileId: id)  // dedupe

    let reloaded = SessionStopOutbox(defaults: defaults)
    XCTAssertEqual(reloaded.pending, [id])
  }

  func testGivenPending_WhenRemove_ThenGone() {
    let a = UUID()
    let b = UUID()
    let outbox = SessionStopOutbox(defaults: defaults)
    outbox.enqueue(profileId: a)
    outbox.enqueue(profileId: b)

    outbox.remove(profileId: a)

    XCTAssertEqual(outbox.pending, [b])
  }

  func testGivenPending_WhenClear_ThenEmptyAndPersistedAcrossReload() {
    let a = UUID()
    let b = UUID()
    let outbox = SessionStopOutbox(defaults: defaults)
    outbox.enqueue(profileId: a)
    outbox.enqueue(profileId: b)

    outbox.clear()

    XCTAssertTrue(outbox.pending.isEmpty)

    let reloaded = SessionStopOutbox(defaults: defaults)
    XCTAssertTrue(reloaded.pending.isEmpty, "clear must persist, not just clear in-memory state")
  }

  func testGivenStopError_WhenEnqueuedAndDrained_ThenRetriesAndClearsOnSuccess() async {
    let resolvedId = UUID()
    let stuckId = UUID()
    let outbox = SessionStopOutbox(defaults: defaults)
    outbox.enqueue(profileId: resolvedId)
    outbox.enqueue(profileId: stuckId)

    // First drive: resolvedId succeeds (.alreadyStopped ⇒ resolved), stuckId keeps failing.
    await outbox.drain { id, _, _ in id == resolvedId }

    XCTAssertEqual(outbox.pending, [stuckId], "resolved id cleared, stuck id retained (no loop loss)")

    // Second drive: stuckId now resolves.
    await outbox.drain { _, _, _ in true }
    XCTAssertTrue(outbox.pending.isEmpty)
  }

  func testTwoOfflineStopsForSameProfileSurviveReloadAndDrain() async {
    let now = Date()
    let profile = UUID()
    let outbox = SessionStopOutbox(defaults: defaults)
    outbox.enqueue(profileId: profile, expectedStart: now, expectedSessionId: UUID().uuidString)
    outbox.enqueue(profileId: profile, expectedStart: now.addingTimeInterval(60), expectedSessionId: UUID().uuidString)
    let reloaded = SessionStopOutbox(defaults: defaults)
    var attempted: [Date?] = []
    await reloaded.drain { _, _, start in
      attempted.append(start)
      return true
    }
    XCTAssertEqual(attempted, [now, now.addingTimeInterval(60)])
    XCTAssertTrue(reloaded.pending.isEmpty)
  }

  func testOldPersistedExactIntentMigratesBeforeNewIntentWithoutLoss() async {
    let now = Date()
    let profile = UUID()
    let original = UUID().uuidString
    let replacement = UUID().uuidString
    defaults.set([profile.uuidString], forKey: "family_foqos_session_stop_outbox")
    defaults.set([profile.uuidString: original], forKey: "family_foqos_session_stop_outbox_expected_ids")
    defaults.set([profile.uuidString: now], forKey: "family_foqos_session_stop_outbox_expected_starts")
    let outbox = SessionStopOutbox(defaults: defaults)
    outbox.enqueue(profileId: profile, expectedStart: now.addingTimeInterval(1), expectedSessionId: replacement)
    var attempted: [String?] = []
    await SessionStopOutbox(defaults: defaults).drain { _, id, _ in
      attempted.append(id)
      return true
    }
    XCTAssertEqual(attempted, [original, replacement])
    XCTAssertTrue(outbox.pending.isEmpty)
  }

  func testExactIntentsDeduplicateAndDoNotWeakenToLegacyStops() {
    let now = Date()
    let profile = UUID()
    let first = UUID().uuidString
    let second = UUID().uuidString
    let outbox = SessionStopOutbox(defaults: defaults)
    outbox.enqueue(profileId: profile, expectedStart: now, expectedSessionId: first)
    outbox.enqueue(profileId: profile, expectedStart: now.addingTimeInterval(1), expectedSessionId: first)
    outbox.enqueue(profileId: profile, expectedStart: now.addingTimeInterval(2), expectedSessionId: second)
    outbox.enqueue(profileId: profile)
    XCTAssertEqual(outbox.intents?.compactMap(\.expectedSessionId), [first, second])
    outbox.resolve(profileId: profile, expectedSessionId: second, expectedStart: now.addingTimeInterval(2))
    XCTAssertEqual(outbox.expectedSessionId(for: profile), first)
  }

  func testCorruptIntentQueueIsPreservedAndCannotBeDrainedOrOverwritten() async {
    let corrupt = Data("damaged queue".utf8)
    defaults.set(corrupt, forKey: "family_foqos_session_stop_intents")
    let outbox = SessionStopOutbox(defaults: defaults)
    outbox.enqueue(profileId: UUID(), expectedSessionId: UUID().uuidString)
    await outbox.drain { _, _, _ in
      XCTFail("A damaged queue cannot authorize a stop")
      return true
    }
    XCTAssertNil(outbox.intents)
    XCTAssertEqual(defaults.data(forKey: "family_foqos_session_stop_intents"), corrupt)
  }

  // MARK: - StrategyManager routing (#201)

  /// Exercises `StrategyManager.handleStopResult` — the exact production code the CAS Task
  /// closure calls — with a simulated `.error` result, without touching live CloudKit.
  func testGivenStrategyManagerStopError_WhenHandled_ThenOutboxPersistsEntry() async {
    let manager = StrategyManager()
    let profileId = UUID()
    manager.sessionStopOutbox.clear()

    await manager.handleStopResult(.error(StopOutboxTestError()), profileId: profileId)

    XCTAssertEqual(manager.sessionStopOutbox.pending, [profileId])

    manager.sessionStopOutbox.clear()
  }
  func testExactIdentityPersistsAndDelayedDrainKeepsNewIntent() async {
    let now = Date()
    let profile = UUID()
    let original = UUID().uuidString
    let replacement = UUID().uuidString
    let outbox = SessionStopOutbox(defaults: defaults)
    outbox.enqueue(profileId: profile, expectedStart: now, expectedSessionId: original)
    let reloaded = SessionStopOutbox(defaults: defaults)
    XCTAssertEqual(reloaded.expectedSessionId(for: profile), original)
    await reloaded.drain { id, expectedId, start in
      XCTAssertEqual(expectedId, original)
      XCTAssertEqual(start, now)
      outbox.enqueue(profileId: id, expectedStart: now.addingTimeInterval(1), expectedSessionId: replacement)
      await Task.yield()
      return true
    }
    XCTAssertEqual(reloaded.pending, [profile])
    XCTAssertEqual(reloaded.expectedSessionId(for: profile), replacement)
  }

}
