import FamilyControls
import XCTest

@testable import FamilyFoqos

final class ProfileAppSelectionStateTests: XCTestCase {
  func testGivenSyncedProfileStillHasEmptySelection_WhenSavingEdit_ThenStillNeedsAppSelection() {
    let selection = FamilyActivitySelection()

    XCTAssertTrue(
      BlockedProfiles.needsAppSelectionAfterLocalSave(
        currentNeedsAppSelection: true,
        selection: selection
      )
    )
  }

  func testGivenProfileAlreadyHasLocalSelection_WhenSavingEdit_ThenDoesNotNeedAppSelection() {
    let selection = FamilyActivitySelection()

    XCTAssertFalse(
      BlockedProfiles.needsAppSelectionAfterLocalSave(
        currentNeedsAppSelection: false,
        selection: selection
      )
    )
  }
}
