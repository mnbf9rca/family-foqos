import XCTest

@testable import FamilyFoqos

final class StartupRecoveryCopyTests: XCTestCase {
  func testRecoveryIntroductionUsesPlainHonestLanguage() {
    XCTAssertEqual(StartupRecoveryCopy.title, "We found your family")
    XCTAssertEqual(
      StartupRecoveryCopy.introduction,
      "This device doesn't have local Family Foqos data, but this iCloud account is part of a Family Foqos family. Your family role has been restored.")
    for forbidden in ["no longer", "previous", "lost", "wiped"] {
      XCTAssertFalse(
        StartupRecoveryCopy.introduction.localizedCaseInsensitiveContains(forbidden))
    }
  }

  func testAvailabilityDisclosureStatesThatDeviceSyncRemainsOff() {
    XCTAssertEqual(
      StartupRecoveryCopy.availabilityDisclosure,
      "Family Foqos checked this iCloud account's Device Sync storage only to see whether synced profiles are available. Device Sync is still off.")
  }

  func testRoleOnlyNoticeExplainsWhyProfilesAreNotMerged() {
    XCTAssertEqual(StartupRecoveryCopy.roleRestoredTitle, "Your family role was restored")
    XCTAssertEqual(
      StartupRecoveryCopy.roleRestoredMessage,
      "This device already has local setup or profiles, so Family Foqos restored only its family role. Device Sync is off to avoid merging profiles automatically. You can review Device Sync in Settings.")
  }

  func testProfilePromptUsesSingularAndPluralGrammar() {
    XCTAssertEqual(
      StartupRecoveryCopy.profilePrompt(count: 1),
      "We found 1 synced profile. Restore it to this device?")
    XCTAssertEqual(
      StartupRecoveryCopy.profilePrompt(count: 3),
      "We found 3 synced profiles. Restore them to this device?")
  }

  func testNoProfileMessageDoesNotPromiseLocalOnlyRecovery() {
    XCTAssertEqual(
      StartupRecoveryCopy.noProfiles,
      "We couldn't find any profiles saved with Device Sync. Profiles that existed only on this device can't be recovered.")
  }
}
