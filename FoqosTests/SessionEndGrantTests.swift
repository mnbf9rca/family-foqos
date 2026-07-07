@preconcurrency import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

final class SessionEndGrantTests: XCTestCase {
  private static let testSuiteName = "SessionEndGrantTests-\(UUID().uuidString)"

  override func setUp() {
    super.setUp()
    SharedData.configure(suite: UserDefaults(suiteName: Self.testSuiteName)!)
  }

  override func tearDown() {
    UserDefaults().removePersistentDomain(forName: Self.testSuiteName)
    super.tearDown()
  }

  func testGivenOpenBreak_WhenCloseGrantsForSessionEnd_ThenBreakEndSetNoRestrictionChange() {
    let now = Date()
    let pid = UUID()
    let s = SharedData.SessionSnapshot(
      id: "s1",
      tag: "t",
      blockedProfileId: pid,
      startTime: now,
      breakStartTime: now.addingTimeInterval(-60),
      forceStarted: false,
      breakEndDeadline: now.addingTimeInterval(240))
    SharedData.createActiveSharedSession(for: s)
    SharedData.closeGrantsForSessionEnd(expectedSessionId: "s1", now: now)
    let after = SharedData.getActiveSharedSession()
    XCTAssertEqual(after?.breakEndTime, now)
  }

  func testGivenEndedSnapshotWithOpenBreak_WhenNormalizedForEnd_ThenGrantClosedAtMinEndDeadline() {
    let now = Date()
    let pid = UUID()
    let ended = SharedData.SessionSnapshot(
      id: "s2",
      tag: "t",
      blockedProfileId: pid,
      startTime: now.addingTimeInterval(-600),
      endTime: now,
      breakStartTime: now.addingTimeInterval(-120),
      breakEndTime: nil,
      forceStarted: false,
      oneMoreMinuteStartTime: now.addingTimeInterval(-90),
      breakEndDeadline: now.addingTimeInterval(60),
      oneMoreMinuteDeadline: now.addingTimeInterval(-30))
    let norm = SharedData.normalizedForEnd(ended)
    XCTAssertEqual(norm.breakEndTime, now)
    XCTAssertNil(norm.oneMoreMinuteStartTime)
    XCTAssertTrue(SharedData.endedSessionHadOpenGrant(ended))
  }

  func testGivenEndedSnapshotNoGrant_WhenEndedSessionHadOpenGrant_ThenFalse() {
    let now = Date()
    let ended = SharedData.SessionSnapshot(
      id: "s3",
      tag: "t",
      blockedProfileId: UUID(),
      startTime: now.addingTimeInterval(-600),
      endTime: now,
      forceStarted: false)
    XCTAssertFalse(SharedData.endedSessionHadOpenGrant(ended))
  }

  @MainActor
  func testGivenEndedSnapshotIngested_WhenUpsert_ThenModelHasNoDanglingGrant() throws {
    let now = Date()
    let profileId = UUID()
    let container = try TestModelContainer.create()
    let context = ModelContext(container)
    context.insert(BlockedProfiles(id: profileId, name: "P"))
    let ended = SharedData.SessionSnapshot(
      id: "s4",
      tag: "t",
      blockedProfileId: profileId,
      startTime: now.addingTimeInterval(-600),
      endTime: now,
      breakStartTime: now.addingTimeInterval(-120),
      forceStarted: false,
      oneMoreMinuteStartTime: now.addingTimeInterval(-90))
    BlockedProfileSession.upsertSessionFromSnapshot(in: context, withSnapshot: ended)
    let fetched = try context.fetch(FetchDescriptor<BlockedProfileSession>()).first
    XCTAssertNotNil(fetched?.breakEndTime)
    XCTAssertNil(fetched?.oneMoreMinuteStartTime)
  }
}
