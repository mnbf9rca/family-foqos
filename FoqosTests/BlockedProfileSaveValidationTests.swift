import FamilyControls
import XCTest

@testable import FamilyFoqos

@MainActor
final class BlockedProfileSaveValidationTests: XCTestCase {
  func testGivenNoAppsCategoriesWebDomainsOrDomains_WhenValidatingSave_ThenReturnsMessage() {
    let message = BlockedProfileView.emptyProfileValidationMessage(
      selection: FamilyActivitySelection(),
      domains: [],
      enableAllowMode: false,
      enableAllowModeDomains: false,
      needsAppSelection: false
    )

    XCTAssertEqual(
      message,
      "This profile does not block anything yet. Select apps, app categories, Safari websites, or domains before saving."
    )
  }

  func testGivenDomainOnlyProfile_WhenValidatingSave_ThenAllowsSave() {
    let message = BlockedProfileView.emptyProfileValidationMessage(
      selection: FamilyActivitySelection(),
      domains: ["example.com"],
      enableAllowMode: false,
      enableAllowModeDomains: false,
      needsAppSelection: false
    )

    XCTAssertNil(message)
  }

  func testGivenAllowModeContent_WhenValidatingSave_ThenAllowsSave() {
    let message = BlockedProfileView.emptyProfileValidationMessage(
      selection: FamilyActivitySelection(),
      domains: [],
      enableAllowMode: true,
      enableAllowModeDomains: false,
      needsAppSelection: false
    )

    XCTAssertNil(message)
  }

  func testGivenAppsSelected_WhenValidatingSave_ThenAllowsSave() {
    let message = BlockedProfileView.emptyProfileValidationMessage(
      selectedItemsCount: 1,
      domains: [],
      enableAllowMode: false,
      enableAllowModeDomains: false,
      needsAppSelection: false
    )

    XCTAssertNil(message)
  }

  func testGivenNeedsAppSelectionProfileStillEmpty_WhenValidatingSave_ThenMessageGuidesSelection() {
    let message = BlockedProfileView.emptyProfileValidationMessage(
      selection: FamilyActivitySelection(),
      domains: [],
      enableAllowMode: false,
      enableAllowModeDomains: false,
      needsAppSelection: true
    )

    XCTAssertEqual(
      message,
      "This synced profile still needs an app selection. Select apps, app categories, Safari websites, or domains before saving."
    )
  }
}
