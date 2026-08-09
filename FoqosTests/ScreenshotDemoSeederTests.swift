import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class ScreenshotDemoSeederTests: XCTestCase {
  private var container: ModelContainer!
  private let defaultsKeys = [
    "family_foqos_app_mode",
    "family_foqos_has_selected_mode",
    "family_foqos_has_completed_onboarding",
    "family_foqos_show_intro_screen",
    "family_foqos_show_mode_selection",
  ]
  private var originalDefaults: [String: Any] = [:]
  private var originallyAbsentKeys: Set<String> = []
  private var originalMode: AppMode = .individual
  private var originalHasSelectedMode = false

  override func setUp() async throws {
    try await super.setUp()
    container = try TestModelContainer.create()
    originalDefaults.removeAll()
    originallyAbsentKeys.removeAll()
    originalMode = AppModeManager.shared.currentMode
    originalHasSelectedMode = AppModeManager.shared.hasSelectedMode
    for key in defaultsKeys {
      if let value = UserDefaults.standard.object(forKey: key) {
        originalDefaults[key] = value
      } else {
        originallyAbsentKeys.insert(key)
      }
    }
    ScreenshotDemoMode.overrideForTesting = true
    ScreenshotDemoMode.scenarioOverrideForTesting = .homeActive
  }

  override func tearDown() async throws {
    // Seeder mutates shared singletons; reset so later test classes see clean state.
    CloudKitManager.shared.isSignedIn = false
    CloudKitManager.shared.familyMembers = []
    CloudKitManager.shared.isConnectedToFamily = false
    CloudKitManager.shared.isShareOwner = false
    HeartbeatManager.shared.monitoredDevices = []
    LockCodeManager.shared.seedForScreenshots([])
    AppModeManager.shared.currentMode = originalMode
    AppModeManager.shared.hasSelectedMode = originalHasSelectedMode
    await Task.yield()
    for key in defaultsKeys {
      if originallyAbsentKeys.contains(key) {
        UserDefaults.standard.removeObject(forKey: key)
      } else if let value = originalDefaults[key] {
        UserDefaults.standard.set(value, forKey: key)
      }
    }
    ScreenshotDemoMode.scenarioOverrideForTesting = nil
    ScreenshotDemoMode.overrideForTesting = nil
    try await super.tearDown()
  }

  func testGivenDemoMode_WhenSeeding_ThenProfilesHistoryAndActiveSessionExist() throws {
    let now = Date()
    try ScreenshotDemoSeeder.seed(container: container, now: now)

    let context = container.mainContext
    let profiles = try context.fetch(FetchDescriptor<BlockedProfiles>())
    XCTAssertEqual(profiles.count, 4)
    XCTAssertTrue(profiles.contains { $0.isManaged })
    XCTAssertFalse(profiles.contains { $0.needsMigration })

    let sessions = try context.fetch(FetchDescriptor<BlockedProfileSession>())
    let activeSessions = sessions.filter(\.isActive)
    let completedSessions = sessions.filter { !$0.isActive }
    XCTAssertEqual(sessions.count, 17)
    XCTAssertEqual(activeSessions.count, 1)
    XCTAssertEqual(completedSessions.count, 16)

    let activeSession = try XCTUnwrap(activeSessions.first)
    XCTAssertEqual(activeSession.blockedProfile.name, "Homework")
    XCTAssertEqual(activeSession.startTime, now.addingTimeInterval(-2400))

    XCTAssertEqual(
      Set(completedSessions.map { Int($0.duration(now: now)) }),
      Set([1800, 5400, 12600, 19800]))
    XCTAssertEqual(
      Set(completedSessions.map { $0.blockedProfile.name }),
      Set(["School Nights", "Homework", "Bedtime", "Deep Focus"]))
    XCTAssertEqual(
      completedSessions.compactMap(\.endTime).min(),
      now.addingTimeInterval(-21 * 86400))
    XCTAssertEqual(
      completedSessions.compactMap(\.endTime).max(),
      now.addingTimeInterval(-86400))
  }

  func testGivenDemoMode_WhenSeeding_ThenFamilyStateIsStaged() throws {
    try ScreenshotDemoSeeder.seed(container: container, now: Date())

    XCTAssertTrue(CloudKitManager.shared.isSignedIn)
    XCTAssertEqual(CloudKitManager.shared.familyMembers.parents.count, 1)
    XCTAssertEqual(CloudKitManager.shared.familyMembers.children.count, 2)
    XCTAssertTrue(LockCodeManager.shared.hasAnyLockCode)
    XCTAssertEqual(HeartbeatManager.shared.monitoredDevices.count, 2)
  }

  func testGivenDemoModeInactive_WhenSeeding_ThenThrowsNothingAndSeedsNothing() throws {
    ScreenshotDemoMode.overrideForTesting = false
    try ScreenshotDemoSeeder.seed(container: container, now: Date())
    let profiles = try container.mainContext.fetch(FetchDescriptor<BlockedProfiles>())
    XCTAssertTrue(profiles.isEmpty)
  }

  func testGivenParentDashboardScenario_WhenSeeding_ThenProfilesAndCompletedHistoryExist() throws {
    let now = Date()
    ScreenshotDemoMode.scenarioOverrideForTesting = .parentDashboard
    try ScreenshotDemoSeeder.seed(container: container, now: now)

    let context = container.mainContext
    let profiles = try context.fetch(FetchDescriptor<BlockedProfiles>())
    let sessions = try context.fetch(FetchDescriptor<BlockedProfileSession>())
    XCTAssertEqual(profiles.count, 4)
    XCTAssertEqual(sessions.count, 16)
    XCTAssertTrue(sessions.allSatisfy { !$0.isActive })
  }
}
