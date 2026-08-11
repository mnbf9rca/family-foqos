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
    await outbox.drain { id in id == resolvedId }

    XCTAssertEqual(outbox.pending, [stuckId], "resolved id cleared, stuck id retained (no loop loss)")

    // Second drive: stuckId now resolves.
    await outbox.drain { _ in true }
    XCTAssertTrue(outbox.pending.isEmpty)
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
}
