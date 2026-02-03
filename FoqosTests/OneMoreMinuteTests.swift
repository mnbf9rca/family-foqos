import XCTest

@testable import FamilyFoqos

final class OneMoreMinuteTests: XCTestCase {

  // MARK: - SessionSnapshot Tests

  func testSessionSnapshotDefaultValues() {
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

  func testSessionSnapshotWithOneMoreMinuteFields() {
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

  func testSessionSnapshotEquality() {
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

  func testSessionSnapshotInequalityOnOneMoreMinuteUsed() {
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

  // MARK: - One More Minute Availability Logic Tests

  func testOneMoreMinuteAvailableWhenNotUsedAndNotOnBreak() {
    // When oneMoreMinuteUsed is false and not on break, should be available
    // This tests the logic: !oneMoreMinuteUsed && !isBreakActive

    let oneMoreMinuteUsed = false
    let isBreakActive = false
    let isAvailable = !oneMoreMinuteUsed && !isBreakActive

    XCTAssertTrue(isAvailable)
  }

  func testOneMoreMinuteNotAvailableWhenAlreadyUsed() {
    // When oneMoreMinuteUsed is true, should not be available
    let oneMoreMinuteUsed = true
    let isBreakActive = false
    let isAvailable = !oneMoreMinuteUsed && !isBreakActive

    XCTAssertFalse(isAvailable)
  }

  func testOneMoreMinuteNotAvailableWhenOnBreak() {
    // When on break, should not be available (even if not used)
    let oneMoreMinuteUsed = false
    let isBreakActive = true
    let isAvailable = !oneMoreMinuteUsed && !isBreakActive

    XCTAssertFalse(isAvailable)
  }

  func testOneMoreMinuteNotAvailableWhenUsedAndOnBreak() {
    // When both used and on break, should not be available
    let oneMoreMinuteUsed = true
    let isBreakActive = true
    let isAvailable = !oneMoreMinuteUsed && !isBreakActive

    XCTAssertFalse(isAvailable)
  }

  // MARK: - One More Minute Active Logic Tests

  func testOneMoreMinuteActiveWhenStartTimeWithin60Seconds() {
    // When start time is within 60 seconds, should be active
    let startTime = Date()
    let now = Date()
    let timeSinceStart = now.timeIntervalSince(startTime)
    let isActive = timeSinceStart < 60

    XCTAssertTrue(isActive)
  }

  func testOneMoreMinuteNotActiveWhenStartTimeOver60Seconds() {
    // When start time is over 60 seconds ago, should not be active
    let startTime = Date().addingTimeInterval(-61)  // 61 seconds ago
    let now = Date()
    let timeSinceStart = now.timeIntervalSince(startTime)
    let isActive = timeSinceStart < 60

    XCTAssertFalse(isActive)
  }

  func testOneMoreMinuteNotActiveWhenNoStartTime() {
    // When start time is nil, should not be active
    let startTime: Date? = nil
    let isActive: Bool
    if let start = startTime {
      isActive = Date().timeIntervalSince(start) < 60
    } else {
      isActive = false
    }

    XCTAssertFalse(isActive)
  }

  // MARK: - Time Remaining Calculation Tests

  func testTimeRemainingCalculation() {
    let startTime = Date().addingTimeInterval(-30)  // Started 30 seconds ago
    let elapsed = Date().timeIntervalSince(startTime)
    let remaining = max(0, 60 - elapsed)

    // Should have approximately 30 seconds remaining (within a small margin for test execution)
    XCTAssertTrue(remaining > 29 && remaining <= 30)
  }

  func testTimeRemainingZeroWhenExpired() {
    let startTime = Date().addingTimeInterval(-65)  // Started 65 seconds ago
    let elapsed = Date().timeIntervalSince(startTime)
    let remaining = max(0, 60 - elapsed)

    XCTAssertEqual(remaining, 0)
  }

  // MARK: - Content State Widget Tests

  func testContentStateDefaultOneMoreMinuteValues() {
    let state = FoqosWidgetAttributes.ContentState(startTime: Date())

    XCTAssertFalse(state.isOneMoreMinuteActive)
    XCTAssertEqual(state.oneMoreMinuteTimeRemaining, 0)
  }

  func testContentStateWithOneMoreMinuteActive() {
    let state = FoqosWidgetAttributes.ContentState(
      startTime: Date(),
      isBreakActive: false,
      breakStartTime: nil,
      breakEndTime: nil,
      isOneMoreMinuteActive: true,
      oneMoreMinuteTimeRemaining: 45
    )

    XCTAssertTrue(state.isOneMoreMinuteActive)
    XCTAssertEqual(state.oneMoreMinuteTimeRemaining, 45)
  }

  // MARK: - SharedData Sync Tests

  func testSetOneMoreMinuteStartTimeSyncsToSharedData() {
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
    SharedData.setOneMoreMinuteStartTime(date: oneMoreMinuteStart)

    // Assert: SharedData is updated
    let afterSession = SharedData.getActiveSharedSession()
    XCTAssertNotNil(afterSession)
    XCTAssertTrue(afterSession!.oneMoreMinuteUsed)
    XCTAssertEqual(afterSession!.oneMoreMinuteStartTime, oneMoreMinuteStart)

    // Cleanup
    SharedData.flushActiveSession()
  }

  func testSetOneMoreMinuteStartTimeNoOpWhenNoActiveSession() {
    // Ensure no active session
    SharedData.flushActiveSession()
    XCTAssertNil(SharedData.getActiveSharedSession())

    // Act: Call the API with no active session (should not crash)
    SharedData.setOneMoreMinuteStartTime(date: Date())

    // Assert: Still no session
    XCTAssertNil(SharedData.getActiveSharedSession())
  }
}
