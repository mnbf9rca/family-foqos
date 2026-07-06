@preconcurrency import FoqosShared
import XCTest

@testable import FamilyFoqos

@MainActor
final class SharedDataLegacyKeyClearingTests: XCTestCase {
  private var suite: UserDefaults!
  private var suiteName: String!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "SharedDataLegacyKeyClearingTests-\(UUID().uuidString)"
    suite = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: suite)
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: suiteName)
    suite = nil
    suiteName = nil
    try await super.tearDown()
  }

  private func makeSnapshot(id: String, ended: Bool = false) -> SharedData.SessionSnapshot {
    let now = Date()  // pin time: one Date() per test path (AGENTS.md)
    return SharedData.SessionSnapshot(
      id: id, tag: "t", blockedProfileId: UUID(), startTime: now,
      endTime: ended ? now : nil, forceStarted: true)
  }

  func testGivenLegacyActiveKey_WhenActiveSharedSessionWritten_ThenLegacyKeyCleared() {
    suite.set(Data([1, 2, 3]), forKey: "activeScheduleSession")  // pre-migration legacy shadow

    SharedData.createActiveSharedSession(for: makeSnapshot(id: "s1"))

    XCTAssertNil(
      suite.object(forKey: "activeScheduleSession"),
      "legacy active key must be cleared on write (#217)")
    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, "s1")
  }

  func testGivenLegacyActiveKey_WhenActiveSessionEnded_ThenNoResurrectionPossible() {
    SharedData.createActiveSharedSession(for: makeSnapshot(id: "s1"))
    // Simulate the stale legacy shadow lingering alongside the extension's new-key write.
    suite.set(Data([9, 9, 9]), forKey: "activeScheduleSession")

    SharedData.endActiveSharedSession()

    XCTAssertNil(SharedData.getActiveSharedSession(), "no active session after end")
    XCTAssertNil(
      suite.object(forKey: "activeScheduleSession"),
      "legacy active key must not survive end() — else migration resurrects it (#217)")
  }

  func testGivenLegacyCompletedKey_WhenCompletedSessionAppended_ThenLegacyKeyCleared() {
    suite.set(Data([1, 2, 3]), forKey: "completedScheduleSessions")  // legacy shadow
    SharedData.createActiveSharedSession(for: makeSnapshot(id: "s1"))

    // endActiveSharedSession appends to completedSessionsInScheduler (a setter write).
    SharedData.endActiveSharedSession()

    XCTAssertNil(
      suite.object(forKey: "completedScheduleSessions"),
      "legacy completed key must be cleared on write (#217)")
  }

  func testGivenLegacyDeviceSyncKeys_WhenWritten_ThenLegacyKeysCleared() {
    suite.set("old-id", forKey: "deviceSyncId")
    suite.set(false, forKey: "deviceSyncEnabled")

    SharedData.deviceSyncId = UUID()
    SharedData.deviceSyncEnabled = true

    XCTAssertNil(suite.object(forKey: "deviceSyncId"), "legacy deviceSyncId key cleared on write")
    XCTAssertNil(
      suite.object(forKey: "deviceSyncEnabled"), "legacy deviceSyncEnabled key cleared on write")
  }
}
