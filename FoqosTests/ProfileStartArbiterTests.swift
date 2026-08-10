import XCTest

@testable import FamilyFoqos

final class ProfileStartArbiterTests: XCTestCase {
  private let idA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  private let idB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

  func testGivenNoExistingSession_WhenDeciding_ThenStart() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)

    XCTAssertEqual(
      ProfileStartArbiter.decide(
        incomingStartTime: now,
        incomingProfileId: idB,
        existingStartTime: nil,
        existingProfileId: nil),
      .start)
  }

  func testGivenSameProfileActive_WhenDeciding_ThenRejectDuplicate() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)

    XCTAssertEqual(
      ProfileStartArbiter.decide(
        incomingStartTime: now,
        incomingProfileId: idB,
        existingStartTime: now.addingTimeInterval(-1),
        existingProfileId: idB),
      .reject)
  }

  func testGivenIncomingNewer_WhenDeciding_ThenAdopt() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)

    XCTAssertEqual(
      ProfileStartArbiter.decide(
        incomingStartTime: now,
        incomingProfileId: idB,
        existingStartTime: now.addingTimeInterval(-60),
        existingProfileId: idA),
      .adopt)
  }

  func testGivenIncomingOlder_WhenDeciding_ThenReject() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)

    XCTAssertEqual(
      ProfileStartArbiter.decide(
        incomingStartTime: now.addingTimeInterval(-60),
        incomingProfileId: idB,
        existingStartTime: now,
        existingProfileId: idA),
      .reject)
  }

  func testGivenEqualStartTimes_WhenDeciding_ThenHigherProfileIdWins() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)

    XCTAssertEqual(
      ProfileStartArbiter.decide(
        incomingStartTime: now,
        incomingProfileId: idB,
        existingStartTime: now,
        existingProfileId: idA),
      .adopt)
    XCTAssertEqual(
      ProfileStartArbiter.decide(
        incomingStartTime: now,
        incomingProfileId: idA,
        existingStartTime: now,
        existingProfileId: idB),
      .reject)
  }
}
