import FoqosShared
import XCTest

final class SharedDataScheduledEndTests: XCTestCase {
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "SharedDataScheduledEndTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
  }

  override func tearDown() {
    UserDefaults().removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  func testGivenSwappedSession_WhenEndByExpectedId_ThenNoOpAndReturnsFalse() {
    SharedData.createSessionForScheduler(for: UUID())
    let staleId = "some-other-id"

    let didEnd = SharedData.endActiveSharedSession(expectedSessionId: staleId)

    XCTAssertFalse(didEnd, "no-op returns false so the caller skips deactivateRestrictions")
    XCTAssertNotNil(
      SharedData.getActiveSharedSession(),
      "ending with a non-matching id is a no-op (extension TOCTOU guard)")
  }

  func testGivenMatchingSession_WhenEndByExpectedId_ThenEndedAndReturnsTrue() {
    SharedData.createSessionForScheduler(for: UUID())
    let id = SharedData.getActiveSharedSession()!.id

    let didEnd = SharedData.endActiveSharedSession(expectedSessionId: id)

    XCTAssertTrue(didEnd, "matching id reports it ended")
    XCTAssertNil(SharedData.getActiveSharedSession(), "matching id ends the session")
  }

  func testGivenDifferentSessionAppeared_WhenTakingOver_ThenAborts() {
    let victimId = UUID()
    SharedData.createActiveSharedSession(
      for: SharedData.SessionSnapshot(
        id: "victim-A", tag: "t", blockedProfileId: victimId, startTime: .distantPast,
        forceStarted: false))

    let started = SharedData.startSchedulerSessionTakingOver(
      profileId: UUID(), expectedVictimId: "stale-victim")

    XCTAssertFalse(started, "a newer/different session aborts the takeover")
    XCTAssertEqual(
      SharedData.getActiveSharedSession()?.id, "victim-A", "the active session is untouched")
  }

  func testGivenExpectedVictimActive_WhenTakingOver_ThenReplacedAndVictimCompleted() {
    let victimId = UUID()
    SharedData.createActiveSharedSession(
      for: SharedData.SessionSnapshot(
        id: "victim-A", tag: "t", blockedProfileId: victimId, startTime: .distantPast,
        forceStarted: false))
    let newProfile = UUID()

    let started = SharedData.startSchedulerSessionTakingOver(
      profileId: newProfile, expectedVictimId: "victim-A")

    XCTAssertTrue(started)
    XCTAssertEqual(
      SharedData.getActiveSharedSession()?.blockedProfileId, newProfile,
      "scheduler session is active")
    XCTAssertTrue(
      SharedData.completedSessionsInScheduler.contains { $0.id == "victim-A" },
      "the displaced victim is moved to completed, not lost")
  }

  func testGivenNoActiveSession_WhenTakingOver_ThenCreates() {
    let newProfile = UUID()
    let started = SharedData.startSchedulerSessionTakingOver(
      profileId: newProfile, expectedVictimId: nil)
    XCTAssertTrue(started)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.blockedProfileId, newProfile)
  }
}
