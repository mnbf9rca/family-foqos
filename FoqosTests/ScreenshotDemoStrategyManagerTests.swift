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

  func testGivenDemoBreak_WhenTimerTicks_ThenSharedGrantRemainsUnchanged() async throws {
    let now = Date()
    let expectedSharedSession = try seedExpiredBreak(now: now)

    try manager.loadScreenshotDemoSession(context: context)
    try await Task.sleep(for: .milliseconds(1200))

    XCTAssertEqual(SharedData.getActiveSharedSession(), expectedSharedSession)
    XCTAssertTrue(applier.calls.isEmpty)
    XCTAssertTrue(registrar.calls.isEmpty)
  }

  func testGivenDemoGuardInactive_WhenTimerTicks_ThenSharedGrantExpires() async throws {
    let now = Date()
    let expectedSharedSession = try seedExpiredBreak(now: now)
    ScreenshotDemoMode.overrideForTesting = false

    try manager.loadScreenshotDemoSession(context: context)
    try await Task.sleep(for: .milliseconds(1200))

    XCTAssertNotEqual(SharedData.getActiveSharedSession(), expectedSharedSession)
    XCTAssertNotNil(SharedData.getActiveSharedSession()?.breakEndTime)
  }

  private func seedExpiredBreak(now: Date) throws -> SharedData.SessionSnapshot {
    let profile = BlockedProfiles(name: "Homework", enableBreaks: true)
    let session = BlockedProfileSession(
      tag: "demo", blockedProfile: profile, startTime: now.addingTimeInterval(-2400))
    session.breakStartTime = now.addingTimeInterval(-120)
    session.breakEndDeadline = now.addingTimeInterval(-1)
    context.insert(profile)
    context.insert(session)
    try context.save()

    let expectedSharedSession = session.toSnapshot()
    SharedData.createActiveSharedSession(for: expectedSharedSession)
    return expectedSharedSession
  }

  func testGivenDemoMode_WhenTogglingBlocking_ThenDoesNotStartSession() throws {
    let profile = BlockedProfiles(name: "Homework")
    profile.blockingStrategyId = ManualBlockingStrategy.id
    context.insert(profile)
    try context.save()

    manager.toggleBlocking(context: context, activeProfile: profile)

    XCTAssertNil(manager.activeSession)
    XCTAssertTrue(try context.fetch(FetchDescriptor<BlockedProfileSession>()).isEmpty)
    XCTAssertTrue(applier.calls.isEmpty)
    XCTAssertTrue(registrar.calls.isEmpty)
  }
}
