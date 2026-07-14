import Foundation
import XCTest

@testable import FamilyFoqos

final class LiveActivityManagerTests: XCTestCase {
  func testGivenNoActivityAndEnabled_WhenDecide_ThenStart() {
    XCTAssertEqual(
      LiveActivityManager.decideAction(
        currentProfileId: nil,
        incomingProfileId: UUID(),
        enableLiveActivity: true,
        hasCurrentActivity: false
      ),
      .start
    )
  }

  func testGivenNoActivityAndDisabled_WhenDecide_ThenSkip() {
    XCTAssertEqual(
      LiveActivityManager.decideAction(
        currentProfileId: nil,
        incomingProfileId: UUID(),
        enableLiveActivity: false,
        hasCurrentActivity: false
      ),
      .skip
    )
  }

  func testGivenActivityForSameProfileEnabled_WhenDecide_ThenUpdate() {
    let profileId = UUID()

    XCTAssertEqual(
      LiveActivityManager.decideAction(
        currentProfileId: profileId,
        incomingProfileId: profileId,
        enableLiveActivity: true,
        hasCurrentActivity: true
      ),
      .update
    )
  }

  func testGivenActivityForDifferentProfileEnabled_WhenDecide_ThenRecreate() {
    XCTAssertEqual(
      LiveActivityManager.decideAction(
        currentProfileId: UUID(),
        incomingProfileId: UUID(),
        enableLiveActivity: true,
        hasCurrentActivity: true
      ),
      .recreate
    )
  }

  func testGivenActivityForDifferentProfileDisabled_WhenDecide_ThenEnd() {
    XCTAssertEqual(
      LiveActivityManager.decideAction(
        currentProfileId: UUID(),
        incomingProfileId: UUID(),
        enableLiveActivity: false,
        hasCurrentActivity: true
      ),
      .end
    )
  }

  func testGivenActivityForSameProfileDisabled_WhenDecide_ThenEnd() {
    let profileId = UUID()

    XCTAssertEqual(
      LiveActivityManager.decideAction(
        currentProfileId: profileId,
        incomingProfileId: profileId,
        enableLiveActivity: false,
        hasCurrentActivity: true
      ),
      .end
    )
  }

  func testGivenActivityButUnknownProfileEnabled_WhenDecide_ThenRecreate() {
    XCTAssertEqual(
      LiveActivityManager.decideAction(
        currentProfileId: nil,
        incomingProfileId: UUID(),
        enableLiveActivity: true,
        hasCurrentActivity: true
      ),
      .recreate
    )
  }

  func testGivenActivityButUnknownProfileDisabled_WhenDecide_ThenEnd() {
    XCTAssertEqual(
      LiveActivityManager.decideAction(
        currentProfileId: nil,
        incomingProfileId: UUID(),
        enableLiveActivity: false,
        hasCurrentActivity: true
      ),
      .end
    )
  }
}
