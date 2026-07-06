@preconcurrency import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class StrategyManagerBackgroundTests: XCTestCase {

  private var container: ModelContainer!
  private var context: ModelContext!
  private var manager: StrategyManager!
  private var testSuiteName: String!

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "StrategyManagerBackgroundTests-\(UUID().uuidString)"
    SharedData.configure(
      suite: UserDefaults(suiteName: testSuiteName)!
    )
    container = try TestModelContainer.create()
    context = container.mainContext
    manager = StrategyManager()
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: testSuiteName)
    try await super.tearDown()
  }

  // MARK: - startSessionFromBackground

  func testGivenNoProfile_WhenStartingFromBackground_ThenThrowsProfileNotFound() {
    XCTAssertThrowsError(
      try manager.startSessionFromBackground(UUID(), context: context)
    ) { error in
      XCTAssertTrue(error is IntentError)
      if case IntentError.profileNotFound = error {
      } else {
        XCTFail("Expected profileNotFound, got \(error)")
      }
    }
  }

  func testGivenActiveSession_WhenStartingFromBackground_ThenThrowsSessionAlreadyActive() throws {
    let profile = BlockedProfiles(name: "Test")
    context.insert(profile)
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)
    context.insert(session)
    try context.save()

    XCTAssertThrowsError(
      try manager.startSessionFromBackground(profile.id, context: context)
    ) { error in
      if case IntentError.sessionAlreadyActive = error {
      } else {
        XCTFail("Expected sessionAlreadyActive, got \(error)")
      }
    }
  }

  func testGivenDurationTooShort_WhenStartingFromBackground_ThenThrowsDurationOutOfRange() throws {
    let profile = BlockedProfiles(name: "Test")
    context.insert(profile)
    try context.save()

    XCTAssertThrowsError(
      try manager.startSessionFromBackground(
        profile.id, context: context, durationInMinutes: 14
      )
    ) { error in
      if case IntentError.durationOutOfRange = error {
      } else {
        XCTFail("Expected durationOutOfRange, got \(error)")
      }
    }
  }

  func testGivenDurationTooLong_WhenStartingFromBackground_ThenThrowsDurationOutOfRange() throws {
    let profile = BlockedProfiles(name: "Test")
    context.insert(profile)
    try context.save()

    XCTAssertThrowsError(
      try manager.startSessionFromBackground(
        profile.id, context: context, durationInMinutes: 1441
      )
    ) { error in
      if case IntentError.durationOutOfRange = error {
      } else {
        XCTFail("Expected durationOutOfRange, got \(error)")
      }
    }
  }

  func testGivenDurationExactly1440_WhenStartingFromBackground_ThenThrowsDurationOutOfRange() throws {
    let profile = BlockedProfiles(name: "Test")
    context.insert(profile)
    try context.save()

    XCTAssertThrowsError(
      try manager.startSessionFromBackground(
        profile.id, context: context, durationInMinutes: 1440
      )
    ) { error in
      if case IntentError.durationOutOfRange = error {
      } else {
        XCTFail("Expected durationOutOfRange, got \(error)")
      }
    }
  }

  // MARK: - stopSessionFromBackground

  func testGivenNoProfile_WhenStoppingFromBackground_ThenThrowsProfileNotFound() async {
    do {
      try await manager.stopSessionFromBackground(UUID(), context: context)
      XCTFail("Expected error to be thrown")
    } catch let error as IntentError {
      if case .profileNotFound = error {
      } else {
        XCTFail("Expected profileNotFound, got \(error)")
      }
    } catch {
      XCTFail("Expected IntentError, got \(error)")
    }
  }

  func testGivenNoActiveSession_WhenStoppingFromBackground_ThenThrowsNoActiveSession() async throws {
    let profile = BlockedProfiles(name: "Test")
    context.insert(profile)
    try context.save()

    do {
      try await manager.stopSessionFromBackground(profile.id, context: context)
      XCTFail("Expected error to be thrown")
    } catch let error as IntentError {
      if case .noActiveSession = error {
      } else {
        XCTFail("Expected noActiveSession, got \(error)")
      }
    } catch {
      XCTFail("Expected IntentError, got \(error)")
    }
  }

  func testGivenActiveSessionOnDifferentProfile_WhenStoppingFromBackground_ThenThrowsNoActiveSession()
    async throws
  {
    let profileA = BlockedProfiles(name: "Profile A")
    let profileB = BlockedProfiles(name: "Profile B")
    context.insert(profileA)
    context.insert(profileB)
    let session = BlockedProfileSession(tag: "test", blockedProfile: profileA)
    context.insert(session)
    try context.save()

    do {
      try await manager.stopSessionFromBackground(profileB.id, context: context)
      XCTFail("Expected error to be thrown")
    } catch let error as IntentError {
      if case .noActiveSession = error {
      } else {
        XCTFail("Expected noActiveSession, got \(error)")
      }
    } catch {
      XCTFail("Expected IntentError, got \(error)")
    }
  }

  func testGivenBackgroundStopsDisabled_WhenStoppingFromBackground_ThenThrowsBackgroundStopsDisabled()
    async throws
  {
    let profile = BlockedProfiles(name: "Test")
    profile.disableBackgroundStops = true
    context.insert(profile)
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)
    context.insert(session)
    try context.save()

    do {
      try await manager.stopSessionFromBackground(profile.id, context: context)
      XCTFail("Expected error to be thrown")
    } catch let error as IntentError {
      if case .backgroundStopsDisabled = error {
      } else {
        XCTFail("Expected backgroundStopsDisabled, got \(error)")
      }
    } catch {
      XCTFail("Expected IntentError, got \(error)")
    }
  }
}
