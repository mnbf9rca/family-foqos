@preconcurrency import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

final class SessionSnapshotDeadlineTests: XCTestCase {
  private static let testSuiteName = "SessionSnapshotDeadlineTests-\(UUID().uuidString)"

  override func setUp() {
    super.setUp()
    SharedData.configure(suite: UserDefaults(suiteName: Self.testSuiteName)!)
  }

  override func tearDown() {
    UserDefaults().removePersistentDomain(forName: Self.testSuiteName)
    super.tearDown()
  }

  private func makePinned(id: UUID) -> SharedData.ProfileSnapshot {
    SharedData.ProfileSnapshot(
      id: id,
      name: "Pinned",
      selectedActivity: .init(),
      createdAt: Date(),
      updatedAt: Date(),
      order: 0,
      enableLiveActivity: false,
      enableBreaks: true,
      enableStrictMode: false,
      enableAllowMode: false,
      enableAllowModeDomains: false,
      enableSafariBlocking: false)
  }

  func testGivenSnapshotWithDeadlinesAndPin_WhenEncodedAndDecoded_ThenFieldsRoundTrip() throws {
    let now = Date()
    let pid = UUID()
    let snap = SharedData.SessionSnapshot(
      id: "s1",
      tag: "t",
      blockedProfileId: pid,
      startTime: now,
      breakStartTime: now,
      forceStarted: false,
      breakEndDeadline: now.addingTimeInterval(300),
      oneMoreMinuteDeadline: nil,
      pinnedProfileConfig: makePinned(id: pid))
    let data = try JSONEncoder().encode(snap)
    let back = try JSONDecoder().decode(SharedData.SessionSnapshot.self, from: data)
    XCTAssertEqual(back.breakEndDeadline, now.addingTimeInterval(300))
    XCTAssertNil(back.oneMoreMinuteDeadline)
    XCTAssertEqual(back.pinnedProfileConfig?.id, pid)
  }

  func testGivenLegacySnapshotJSONWithoutDeadlines_WhenDecoded_ThenDeadlinesAreNil() throws {
    let legacy = """
      {"id":"s0","tag":"t","blockedProfileId":"\(UUID().uuidString)","startTime":0,
       "forceStarted":false,"oneMoreMinuteUsed":false}
      """.data(using: .utf8)!
    let back = try JSONDecoder().decode(SharedData.SessionSnapshot.self, from: legacy)
    XCTAssertNil(back.breakEndDeadline)
    XCTAssertNil(back.oneMoreMinuteDeadline)
    XCTAssertNil(back.pinnedProfileConfig)
  }

  @MainActor
  func testGivenModelWithDeadlines_WhenToSnapshotAndUpsert_ThenModelMirrorsDeadlines() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = ModelContext(container)
    let profile = BlockedProfiles(name: "P")
    context.insert(profile)
    let session = BlockedProfileSession(tag: "t", blockedProfile: profile)
    session.breakStartTime = now
    session.breakEndDeadline = now.addingTimeInterval(300)
    session.pinnedProfileConfigData = try JSONEncoder().encode(makePinned(id: profile.id))
    context.insert(session)
    try context.save()

    let snap = session.toSnapshot()
    XCTAssertEqual(snap.breakEndDeadline, now.addingTimeInterval(300))
    XCTAssertEqual(snap.pinnedProfileConfig?.id, profile.id)

    let container2 = try TestModelContainer.create()
    let context2 = ModelContext(container2)
    let p2 = BlockedProfiles(id: snap.blockedProfileId, name: "P")
    context2.insert(p2)
    try context2.save()
    var snap2 = snap
    snap2.oneMoreMinuteDeadline = now.addingTimeInterval(60)
    BlockedProfileSession.upsertSessionFromSnapshot(in: context2, withSnapshot: snap2)
    let fetched = try context2.fetch(FetchDescriptor<BlockedProfileSession>()).first
    XCTAssertEqual(fetched?.breakEndDeadline, now.addingTimeInterval(300))
    XCTAssertEqual(fetched?.oneMoreMinuteDeadline, now.addingTimeInterval(60))
  }
}
