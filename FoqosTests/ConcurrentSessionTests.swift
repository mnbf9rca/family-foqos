import XCTest

@testable import FamilyFoqos

final class ConcurrentSessionTests: XCTestCase {

  var mockService: MockSessionSyncService!
  let profileId = UUID()

  override func setUp() async throws {
    mockService = MockSessionSyncService()
  }

  /// Simulates the original bug: stale start after stop
  func testGivenStoppedSession_WhenStaleStartArrives_ThenRejectsIt() async {
    let now = Date()

    // Device A starts
    let startResult = await mockService.startSession(
      profileId: profileId,
      startTime: now,
      deviceId: "device-a"
    )
    guard case .started(let seq1) = startResult else {
      XCTFail("Should start")
      return
    }
    XCTAssertEqual(seq1, 1)

    // Device A stops
    let stopResult = await mockService.stopSession(
      profileId: profileId,
      endTime: now,
      deviceId: "device-a"
    )
    guard case .stopped(let seq2) = stopResult else {
      XCTFail("Should stop")
      return
    }
    XCTAssertEqual(seq2, 2)

    // Device B's stale start arrives (from before A stopped)
    // In the real system, this would be a CAS conflict
    // With single record model, B would fetch current state and see it's stopped
    let fetchResult = await mockService.fetchSession(profileId: profileId)
    guard case .found(let current) = fetchResult else {
      XCTFail("Should find session")
      return
    }

    // B sees the session is stopped - no resurrection
    XCTAssertFalse(current.isActive)
    XCTAssertEqual(current.sequenceNumber, 2)
  }

  /// Simulates concurrent schedule triggers
  func testGivenConcurrentScheduleTriggers_WhenBothDevicesStart_ThenFirstWins() async {
    let now = Date()

    // Simulate Device A winning the race (Device B gets conflict)
    await mockService.reset()
    await mockService.setSimulateConflictOnce(true)

    // Device B tries to start (but A already won)
    let resultB = await mockService.startSession(
      profileId: profileId,
      startTime: now,
      deviceId: "device-b"
    )

    // B should see A's session and join it
    guard case .alreadyActive(let session) = resultB else {
      XCTFail("Should get alreadyActive")
      return
    }

    XCTAssertTrue(session.isActive)
    XCTAssertEqual(session.sessionOriginDevice, "other-device")  // A won
  }

  /// Simulates multiple devices starting and stopping
  func testGivenMultipleDevices_WhenStartingAndStopping_ThenAllSeeStoppedState() async {
    let now = Date()

    // Device A starts
    _ = await mockService.startSession(
      profileId: profileId, startTime: now, deviceId: "device-a")

    // Device B tries to start - should join A's session
    let resultB = await mockService.startSession(
      profileId: profileId, startTime: now, deviceId: "device-b")
    guard case .alreadyActive = resultB else {
      XCTFail("B should join A's session")
      return
    }

    // Device C tries to start - should also join
    let resultC = await mockService.startSession(
      profileId: profileId, startTime: now, deviceId: "device-c")
    guard case .alreadyActive = resultC else {
      XCTFail("C should join A's session")
      return
    }

    // Device B stops
    let stopResult = await mockService.stopSession(
      profileId: profileId, endTime: now, deviceId: "device-b")
    guard case .stopped(let seq) = stopResult else {
      XCTFail("Should stop")
      return
    }
    XCTAssertEqual(seq, 2)

    // All devices now see stopped state
    let fetchResult = await mockService.fetchSession(profileId: profileId)
    guard case .found(let final) = fetchResult else {
      XCTFail("Should find")
      return
    }
    XCTAssertFalse(final.isActive)
  }

  /// Tests that stopping an already stopped session returns alreadyStopped
  func testGivenAlreadyStoppedSession_WhenStoppingAgain_ThenReturnsAlreadyStopped() async {
    let now = Date()

    // Start and stop
    _ = await mockService.startSession(
      profileId: profileId, startTime: now, deviceId: "device-a")
    _ = await mockService.stopSession(
      profileId: profileId, endTime: now, deviceId: "device-a")

    // Try to stop again
    let result = await mockService.stopSession(
      profileId: profileId, endTime: now, deviceId: "device-b")
    guard case .alreadyStopped = result else {
      XCTFail("Should be alreadyStopped")
      return
    }
  }

  /// Tests that stopping a non-existent session returns alreadyStopped
  func testGivenNonExistentSession_WhenStopping_ThenReturnsAlreadyStopped() async {
    let now = Date()

    let result = await mockService.stopSession(
      profileId: UUID(), endTime: now, deviceId: "device-a")
    guard case .alreadyStopped = result else {
      XCTFail("Should be alreadyStopped for non-existent session")
      return
    }
  }

  /// Verifies that the maxRetriesExceeded error case exists and is usable
  func testGivenMaxRetriesExceededError_WhenCheckingDescription_ThenContainsRetry() {
    let error = SessionSyncError.maxRetriesExceeded
    XCTAssertNotNil(error.errorDescription)
    XCTAssertTrue(error.errorDescription!.contains("retry"))
  }

  /// Verifies that simulated CAS conflicts return alreadyActive
  /// to match real-world behavior when another device wins the race
  func testGivenSimulatedConflict_WhenStarting_ThenReturnsAlreadyActive() async {
    let now = Date()

    await mockService.reset()
    await mockService.setSimulateConflictCount(1)

    let result = await mockService.startSession(
      profileId: profileId,
      startTime: now,
      deviceId: "device-a"
    )

    guard case .alreadyActive(let session) = result else {
      XCTFail("Expected alreadyActive when conflict is simulated, got \(result)")
      return
    }
    XCTAssertTrue(session.isActive)
    XCTAssertEqual(session.sessionOriginDevice, "conflict-device")
  }

  /// Verifies that after conflicts are exhausted, normal behavior resumes
  func testGivenExhaustedConflicts_WhenStarting_ThenSucceedsNormally() async {
    let now = Date()

    await mockService.reset()
    await mockService.setSimulateConflictCount(2)

    // First two calls return alreadyActive (conflict)
    let conflict1 = await mockService.startSession(
      profileId: profileId, startTime: now, deviceId: "device-a")
    guard case .alreadyActive = conflict1 else {
      XCTFail("Expected alreadyActive on first conflict")
      return
    }

    let conflict2 = await mockService.startSession(
      profileId: profileId, startTime: now, deviceId: "device-a")
    guard case .alreadyActive = conflict2 else {
      XCTFail("Expected alreadyActive on second conflict")
      return
    }

    // Stop the conflict-winner's session so the normal path can start fresh
    _ = await mockService.stopSession(
      profileId: profileId, endTime: now, deviceId: "conflict-device")

    // Third call should succeed normally (conflicts exhausted, session stopped)
    let success = await mockService.startSession(
      profileId: profileId, startTime: now, deviceId: "device-a")
    guard case .started = success else {
      XCTFail("Expected started after conflicts exhausted and session stopped, got \(success)")
      return
    }
  }
}
