import XCTest

@testable import FamilyFoqos

final class BlockedProfileCarouselTests: XCTestCase {
  func testGivenCurrentPageStillPresent_WhenProfilesChange_ThenCurrentPageKept() {
    let currentId = UUID()
    let nextId = UUID()

    let resolved = BlockedProfileCarousel.resolvedCurrentProfileId(
      currentProfileId: currentId,
      validProfileIds: [currentId, nextId]
    )

    XCTAssertEqual(resolved, currentId)
  }

  func testGivenCurrentPageRemoved_WhenProfilesChange_ThenFallsBackToFirst() {
    let removedId = UUID()
    let firstRemainingId = UUID()
    let secondRemainingId = UUID()

    let resolved = BlockedProfileCarousel.resolvedCurrentProfileId(
      currentProfileId: removedId,
      validProfileIds: [firstRemainingId, secondRemainingId]
    )

    XCTAssertEqual(resolved, firstRemainingId)
  }

  func testGivenPendingStartingPageAppears_WhenProfilesChange_ThenInitialSetupRuns() {
    let currentId = UUID()
    let startingId = UUID()

    let shouldRunInitialSetup = BlockedProfileCarousel.shouldRunInitialSetupOnProfilesChange(
      currentProfileId: currentId,
      startingProfileId: startingId,
      validProfileIds: [currentId, startingId]
    )

    XCTAssertTrue(shouldRunInitialSetup)
  }
}
