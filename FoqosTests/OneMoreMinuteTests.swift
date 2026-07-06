import XCTest

@testable import FamilyFoqos

final class OneMoreMinuteTests: XCTestCase {

  private static let testSuiteName = "OneMoreMinuteTests-\(UUID().uuidString)"

  override func setUp() {
    super.setUp()
    SharedData.configure(
      suite: UserDefaults(suiteName: Self.testSuiteName)!
    )
  }

  override func tearDown() {
    UserDefaults().removePersistentDomain(forName: Self.testSuiteName)
    super.tearDown()
  }

  // MARK: - SessionSnapshot Tests

  func testGivenNewSnapshot_WhenCheckingDefaults_ThenOneMoreMinuteFieldsAreEmpty() {
    // Test that default values are correct for one-more-minute fields
    let snapshot = SharedData.SessionSnapshot(
      id: "test-id",
      tag: "test-tag",
      blockedProfileId: UUID(),
      startTime: Date(),
      forceStarted: false
    )

    XCTAssertFalse(snapshot.oneMoreMinuteUsed)
    XCTAssertNil(snapshot.oneMoreMinuteStartTime)
  }

  func testGivenSnapshotWithOneMoreMinute_WhenCheckingFields_ThenValuesAreSet() {
    let now = Date()
    let snapshot = SharedData.SessionSnapshot(
      id: "test-id",
      tag: "test-tag",
      blockedProfileId: UUID(),
      startTime: now,
      forceStarted: false,
      oneMoreMinuteUsed: true,
      oneMoreMinuteStartTime: now
    )

    XCTAssertTrue(snapshot.oneMoreMinuteUsed)
    XCTAssertEqual(snapshot.oneMoreMinuteStartTime, now)
  }

  func testGivenIdenticalSnapshots_WhenComparing_ThenTheyAreEqual() {
    let profileId = UUID()
    let now = Date()

    let snapshot1 = SharedData.SessionSnapshot(
      id: "test-id",
      tag: "test-tag",
      blockedProfileId: profileId,
      startTime: now,
      forceStarted: false,
      oneMoreMinuteUsed: true,
      oneMoreMinuteStartTime: now
    )

    let snapshot2 = SharedData.SessionSnapshot(
      id: "test-id",
      tag: "test-tag",
      blockedProfileId: profileId,
      startTime: now,
      forceStarted: false,
      oneMoreMinuteUsed: true,
      oneMoreMinuteStartTime: now
    )

    XCTAssertEqual(snapshot1, snapshot2)
  }

  func testGivenDifferentOneMoreMinuteUsed_WhenComparing_ThenTheyAreNotEqual() {
    let profileId = UUID()
    let now = Date()

    let snapshot1 = SharedData.SessionSnapshot(
      id: "test-id",
      tag: "test-tag",
      blockedProfileId: profileId,
      startTime: now,
      forceStarted: false,
      oneMoreMinuteUsed: false,
      oneMoreMinuteStartTime: nil
    )

    let snapshot2 = SharedData.SessionSnapshot(
      id: "test-id",
      tag: "test-tag",
      blockedProfileId: profileId,
      startTime: now,
      forceStarted: false,
      oneMoreMinuteUsed: true,
      oneMoreMinuteStartTime: now
    )

    XCTAssertNotEqual(snapshot1, snapshot2)
  }

  // MARK: - isOneMoreMinuteActive Tests

  func testGivenNoStartTime_WhenCheckingActive_ThenReturnsFalse() {
    let profile = BlockedProfiles(name: "Test")
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)

    XCTAssertFalse(session.isOneMoreMinuteActive())
  }

  func testGivenStartTimeWithin60Seconds_WhenCheckingActive_ThenReturnsTrue() {
    let now = Date()
    let profile = BlockedProfiles(name: "Test")
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)
    session.oneMoreMinuteStartTime = now.addingTimeInterval(-30)

    XCTAssertTrue(session.isOneMoreMinuteActive(now: now))
  }

  func testGivenStartTimeOver60Seconds_WhenCheckingActive_ThenReturnsFalse() {
    let now = Date()
    let profile = BlockedProfiles(name: "Test")
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)
    session.oneMoreMinuteStartTime = now.addingTimeInterval(-61)

    XCTAssertFalse(session.isOneMoreMinuteActive(now: now))
  }

  // MARK: - isOneMoreMinuteAvailable Tests

  func testGivenNotUsedAndNotOnBreak_WhenCheckingAvailable_ThenReturnsTrue() {
    let profile = BlockedProfiles(name: "Test")
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)

    XCTAssertTrue(session.isOneMoreMinuteAvailable)
  }

  func testGivenAlreadyUsed_WhenCheckingAvailable_ThenReturnsFalse() {
    let profile = BlockedProfiles(name: "Test")
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)
    session.oneMoreMinuteUsed = true

    XCTAssertFalse(session.isOneMoreMinuteAvailable)
  }

  func testGivenOnBreak_WhenCheckingAvailable_ThenReturnsFalse() {
    let profile = BlockedProfiles(name: "Test", enableBreaks: true)
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)
    session.breakStartTime = Date()

    XCTAssertFalse(session.isOneMoreMinuteAvailable)
  }

  // MARK: - duration Tests

  func testGivenEndedSession_WhenCheckingDuration_ThenReturnsStartToEnd() {
    let now = Date()
    let profile = BlockedProfiles(name: "Test")
    let session = BlockedProfileSession(
      tag: "test", blockedProfile: profile, startTime: now.addingTimeInterval(-300)
    )
    session.endTime = now

    XCTAssertEqual(session.duration(), 300, accuracy: 0.001)
  }

  func testGivenActiveSession_WhenCheckingDuration_ThenReturnsStartToNow() {
    let now = Date()
    let profile = BlockedProfiles(name: "Test")
    let session = BlockedProfileSession(
      tag: "test", blockedProfile: profile, startTime: now.addingTimeInterval(-120)
    )

    XCTAssertEqual(session.duration(now: now), 120, accuracy: 0.001)
  }

  // MARK: - startOneMoreMinute Tests

  func testGivenSession_WhenStartOneMoreMinute_ThenSetsUsedAndStartTime() {
    let now = Date()
    let profile = BlockedProfiles(name: "Test")
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)

    session.startOneMoreMinute(now: now)

    XCTAssertTrue(session.oneMoreMinuteUsed)
    XCTAssertEqual(session.oneMoreMinuteStartTime, now)
  }

  // MARK: - startBreak Tests

  func testGivenSession_WhenStartBreak_ThenSetsBreakStartTime() {
    let now = Date()
    let profile = BlockedProfiles(name: "Test")
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)

    session.startBreak(now: now)

    XCTAssertEqual(session.breakStartTime, now)
  }

  // MARK: - endSession Tests

  func testGivenSession_WhenEndSession_ThenSetsEndTime() {
    let now = Date()
    let profile = BlockedProfiles(name: "Test")
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)

    session.endSession(now: now)

    XCTAssertEqual(session.endTime, now)
  }

  // MARK: - Time Remaining Calculation Tests

  func testGivenActiveOneMoreMinute_WhenCalculatingRemaining_ThenReturnsCorrectSeconds() {
    let now = Date()
    let startTime = now.addingTimeInterval(-30)
    let elapsed = now.timeIntervalSince(startTime)
    let remaining = max(0, 60 - elapsed)

    XCTAssertEqual(remaining, 30, accuracy: 0.001)
  }

  func testGivenExpiredOneMoreMinute_WhenCalculatingRemaining_ThenReturnsZero() {
    let now = Date()
    let startTime = now.addingTimeInterval(-65)
    let elapsed = now.timeIntervalSince(startTime)
    let remaining = max(0, 60 - elapsed)

    XCTAssertEqual(remaining, 0)
  }

  // MARK: - Content State Widget Tests

  func testGivenDefaultContentState_WhenCheckingOneMoreMinute_ThenFieldsAreEmpty() {
    let state = FoqosWidgetAttributes.ContentState(startTime: Date())

    XCTAssertFalse(state.isOneMoreMinuteActive)
    XCTAssertNil(state.oneMoreMinuteStartTime)
  }

  func testGivenContentStateWithOneMoreMinute_WhenCheckingActive_ThenReturnsTrue() {
    let now = Date()
    let state = FoqosWidgetAttributes.ContentState(
      startTime: now,
      isBreakActive: false,
      breakStartTime: nil,
      breakEndTime: nil,
      isOneMoreMinuteActive: true,
      oneMoreMinuteStartTime: now
    )

    XCTAssertTrue(state.isOneMoreMinuteActive)
    XCTAssertNotNil(state.oneMoreMinuteStartTime)
  }

  // MARK: - SharedData Sync Tests

  func testGivenActiveSession_WhenSettingOneMoreMinuteStartTime_ThenSyncsToSharedData() {
    // Setup: Create an active session in SharedData
    let profileId = UUID()
    let initialSnapshot = SharedData.SessionSnapshot(
      id: "test-session",
      tag: "test-tag",
      blockedProfileId: profileId,
      startTime: Date(),
      forceStarted: false
    )
    SharedData.createActiveSharedSession(for: initialSnapshot)

    // Verify initial state
    let beforeSession = SharedData.getActiveSharedSession()
    XCTAssertNotNil(beforeSession)
    XCTAssertFalse(beforeSession!.oneMoreMinuteUsed)
    XCTAssertNil(beforeSession!.oneMoreMinuteStartTime)

    // Act: Call the real API
    let oneMoreMinuteStart = Date()
    SharedData.setOneMoreMinuteStartTime(
      date: oneMoreMinuteStart, expectedSessionId: "test-session")

    // Assert: SharedData is updated
    let afterSession = SharedData.getActiveSharedSession()
    XCTAssertNotNil(afterSession)
    XCTAssertTrue(afterSession!.oneMoreMinuteUsed)
    XCTAssertEqual(afterSession!.oneMoreMinuteStartTime, oneMoreMinuteStart)
  }

  func testGivenNoActiveSession_WhenSettingOneMoreMinuteStartTime_ThenNoOp() {
    // Act: Call the API with no active session (should not crash)
    SharedData.setOneMoreMinuteStartTime(date: Date(), expectedSessionId: "any-id")

    // Assert: Still no session
    XCTAssertNil(SharedData.getActiveSharedSession())
  }

  func testGivenDifferentActiveSession_WhenSettingOneMoreMinute_ThenNoOp() {
    let now = Date()
    let profileId = UUID()
    let stored = SharedData.SessionSnapshot(
      id: "stored-session",
      tag: "tag",
      blockedProfileId: profileId,
      startTime: now,
      forceStarted: false
    )
    SharedData.createActiveSharedSession(for: stored)

    // A different session tries to stamp one-more-minute.
    SharedData.setOneMoreMinuteStartTime(date: now, expectedSessionId: "other-session")

    let after = SharedData.getActiveSharedSession()
    XCTAssertEqual(after?.id, "stored-session", "stored session untouched")
    XCTAssertFalse(after?.oneMoreMinuteUsed ?? true, "mismatch is a no-op (#237)")
    XCTAssertNil(after?.oneMoreMinuteStartTime)
  }
}
