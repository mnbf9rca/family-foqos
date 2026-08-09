import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class ScreenshotDemoSeederTests: XCTestCase {
  private var container: ModelContainer!

  override func setUp() async throws {
    try await super.setUp()
    container = try TestModelContainer.create()
    ScreenshotDemoMode.overrideForTesting = true
    ScreenshotDemoMode.scenarioOverrideForTesting = .homeActive
  }

  override func tearDown() async throws {
    ScreenshotDemoMode.overrideForTesting = nil
    ScreenshotDemoMode.scenarioOverrideForTesting = nil
    // Seeder mutates shared singletons; reset so later test classes see clean state.
    CloudKitManager.shared.isSignedIn = false
    CloudKitManager.shared.familyMembers = []
    CloudKitManager.shared.isConnectedToFamily = false
    CloudKitManager.shared.isShareOwner = false
    HeartbeatManager.shared.monitoredDevices = []
    LockCodeManager.shared.seedForScreenshots([])
    try await super.tearDown()
  }

  func testGivenDemoMode_WhenSeeding_ThenProfilesAndActiveSessionExist() throws {
    let now = Date()
    try ScreenshotDemoSeeder.seed(container: container, now: now)

    let context = container.mainContext
    let profiles = try context.fetch(FetchDescriptor<BlockedProfiles>())
    XCTAssertEqual(profiles.count, 4)
    XCTAssertTrue(profiles.contains { $0.isManaged })

    let sessions = try context.fetch(FetchDescriptor<BlockedProfileSession>())
    XCTAssertEqual(sessions.count, 1)
    let session = try XCTUnwrap(sessions.first)
    XCTAssertTrue(session.isActive)
    XCTAssertEqual(session.startTime, now.addingTimeInterval(-2400))
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

  func testGivenParentDashboardScenario_WhenSeeding_ThenProfilesExistWithoutActiveSession() throws {
    let now = Date()
    ScreenshotDemoMode.scenarioOverrideForTesting = .parentDashboard
    try ScreenshotDemoSeeder.seed(container: container, now: now)

    let context = container.mainContext
    let profiles = try context.fetch(FetchDescriptor<BlockedProfiles>())
    let sessions = try context.fetch(FetchDescriptor<BlockedProfileSession>())
    XCTAssertEqual(profiles.count, 4)
    XCTAssertTrue(sessions.isEmpty)
  }
}
