import XCTest

@testable import FamilyFoqos

final class ConcurrentSessionTests: XCTestCase {

  var mockService: MockSessionSyncService!
  let profileId = UUID()

  override func setUp() async throws {
    mockService = MockSessionSyncService()
  }

  /// Simulates the original bug: stale start after stop
  func testStaleStartAfterStopIsRejected() async {
    // Device A starts
    let startResult = await mockService.startSession(
      profileId: profileId,
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
  func testConcurrentScheduleTriggersFirstWins() async {
    // Simulate Device A winning the race (Device B gets conflict)
    await mockService.reset()
    await mockService.setSimulateConflictOnce(true)

    // Device B tries to start (but A already won)
    let resultB = await mockService.startSession(
      profileId: profileId,
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
  func testMultiDeviceStartStop() async {
    // Device A starts
    _ = await mockService.startSession(profileId: profileId, deviceId: "device-a")

    // Device B tries to start - should join A's session
    let resultB = await mockService.startSession(profileId: profileId, deviceId: "device-b")
    guard case .alreadyActive = resultB else {
      XCTFail("B should join A's session")
      return
    }

    // Device C tries to start - should also join
    let resultC = await mockService.startSession(profileId: profileId, deviceId: "device-c")
    guard case .alreadyActive = resultC else {
      XCTFail("C should join A's session")
      return
    }

    // Device B stops
    let stopResult = await mockService.stopSession(profileId: profileId, deviceId: "device-b")
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
  func testStopAlreadyStoppedSession() async {
    // Start and stop
    _ = await mockService.startSession(profileId: profileId, deviceId: "device-a")
    _ = await mockService.stopSession(profileId: profileId, deviceId: "device-a")

    // Try to stop again
    let result = await mockService.stopSession(profileId: profileId, deviceId: "device-b")
    guard case .alreadyStopped = result else {
      XCTFail("Should be alreadyStopped")
      return
    }
  }

  /// Tests that stopping a non-existent session returns alreadyStopped
  func testStopNonExistentSession() async {
    let result = await mockService.stopSession(profileId: UUID(), deviceId: "device-a")
    guard case .alreadyStopped = result else {
      XCTFail("Should be alreadyStopped for non-existent session")
      return
    }
  }
}
