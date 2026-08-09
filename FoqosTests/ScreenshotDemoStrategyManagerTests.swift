@preconcurrency import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class ScreenshotDemoStrategyManagerTests: XCTestCase {
  private var suiteName = ""
  private var container: ModelContainer!
  private var context: ModelContext!
  private var applier: RecordingRestrictionApplier!
  private var registrar: RecordingBackstopRegistrar!
  private var manager: StrategyManager!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "ScreenshotDemoStrategyManagerTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    container = try TestModelContainer.create()
    context = ModelContext(container)
    applier = RecordingRestrictionApplier()
    registrar = RecordingBackstopRegistrar()
    manager = StrategyManager(appBlocker: applier, backstopRegistrar: registrar)
    ScreenshotDemoMode.overrideForTesting = true
  }

  override func tearDown() async throws {
    manager.stopTimer()
    ScreenshotDemoMode.overrideForTesting = nil
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func testGivenDemoMode_WhenLoadingScreenshotSession_ThenLoadsDirectlyWithoutSideEffects() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Homework")
    let session = BlockedProfileSession(
      tag: "demo", blockedProfile: profile, startTime: now.addingTimeInterval(-2400))
    context.insert(profile)
    context.insert(session)
    try context.save()

    try manager.loadScreenshotDemoSession(context: context)

    XCTAssertEqual(manager.activeSession?.id, session.id)
    XCTAssertTrue(manager.isBlocking)
    XCTAssertNotNil(manager.timerTask)
    XCTAssertTrue(applier.calls.isEmpty)
    XCTAssertTrue(registrar.calls.isEmpty)
    XCTAssertNil(SharedData.getActiveSharedSession())
  }

  func testGivenDemoMode_WhenReconcilingGrants_ThenDoesNotApplyRestrictions() {
    manager.reconcileGrants(context: context)

    XCTAssertTrue(applier.calls.isEmpty)
    XCTAssertTrue(registrar.calls.isEmpty)
  }

  func testGivenDemoMode_WhenLoadingProductionSession_ThenDoesNotImportSharedSession() throws {
    let profile = BlockedProfiles(name: "Production Profile")
    context.insert(profile)
    let sharedSession = BlockedProfileSession.createSession(
      in: context, withTag: "scheduled", withProfile: profile)
    try context.save()
    context.delete(sharedSession)
    try context.save()

    try manager.loadActiveSession(context: context)

    let sessions = try context.fetch(FetchDescriptor<BlockedProfileSession>())
    XCTAssertTrue(sessions.isEmpty)
    XCTAssertNil(manager.activeSession)
  }
}
