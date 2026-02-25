import XCTest

@testable import FamilyFoqos

final class BlockedProfileSessionTests: XCTestCase {

  // MARK: - isActive

  func testGivenNewSession_WhenCheckingIsActive_ThenReturnsTrue() {
    let profile = BlockedProfiles(name: "Test")
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)

    XCTAssertTrue(session.isActive)
  }

  func testGivenEndedSession_WhenCheckingIsActive_ThenReturnsFalse() {
    let profile = BlockedProfiles(name: "Test")
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)
    session.endTime = Date()

    XCTAssertFalse(session.isActive)
  }

  // MARK: - isBreakActive

  func testGivenBreaksEnabledAndBreakStarted_WhenCheckingIsBreakActive_ThenReturnsTrue() {
    let profile = BlockedProfiles(name: "Test", enableBreaks: true)
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)
    session.breakStartTime = Date()

    XCTAssertTrue(session.isBreakActive)
  }

  func testGivenBreaksDisabled_WhenCheckingIsBreakActive_ThenReturnsFalse() {
    let profile = BlockedProfiles(name: "Test", enableBreaks: false)
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)
    session.breakStartTime = Date()

    XCTAssertFalse(session.isBreakActive)
  }

  func testGivenBreaksEnabledButNotStarted_WhenCheckingIsBreakActive_ThenReturnsFalse() {
    let profile = BlockedProfiles(name: "Test", enableBreaks: true)
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)

    XCTAssertFalse(session.isBreakActive)
  }

  func testGivenBreakEnded_WhenCheckingIsBreakActive_ThenReturnsFalse() {
    let now = Date()
    let profile = BlockedProfiles(name: "Test", enableBreaks: true)
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)
    session.breakStartTime = now.addingTimeInterval(-60)
    session.breakEndTime = now

    XCTAssertFalse(session.isBreakActive)
  }

  // MARK: - isBreakAvailable

  func testGivenBreaksEnabledAndNoBreakTaken_WhenCheckingIsBreakAvailable_ThenReturnsTrue() {
    let profile = BlockedProfiles(name: "Test", enableBreaks: true)
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)

    XCTAssertTrue(session.isBreakAvailable)
  }

  func testGivenBreaksEnabledAndBreakInProgress_WhenCheckingIsBreakAvailable_ThenReturnsTrue() {
    let profile = BlockedProfiles(name: "Test", enableBreaks: true)
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)
    session.breakStartTime = Date()

    XCTAssertTrue(session.isBreakAvailable)
  }

  func testGivenBreaksDisabled_WhenCheckingIsBreakAvailable_ThenReturnsFalse() {
    let profile = BlockedProfiles(name: "Test", enableBreaks: false)
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)

    XCTAssertFalse(session.isBreakAvailable)
  }

  func testGivenBreakAlreadyEnded_WhenCheckingIsBreakAvailable_ThenReturnsFalse() {
    let now = Date()
    let profile = BlockedProfiles(name: "Test", enableBreaks: true)
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)
    session.breakStartTime = now.addingTimeInterval(-60)
    session.breakEndTime = now

    XCTAssertFalse(session.isBreakAvailable)
  }
}
