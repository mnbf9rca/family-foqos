// FoqosTests/StrategyManagerStartTests.swift
import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class StrategyManagerStartTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!
  private var manager: StrategyManager!
  private var suiteName: String!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "StrategyManagerStartTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    container = try TestModelContainer.create()
    context = container.mainContext
    manager = StrategyManager()
  }

  override func tearDown() async throws {
    manager.stopTimer()
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  private func activeSessions() throws -> [BlockedProfileSession] {
    try context.fetch(
      FetchDescriptor<BlockedProfileSession>(
        predicate: #Predicate { $0.endTime == nil }
      ))
  }

  func testGivenManualTriggerOnly_WhenDeterminingStartAction_ThenReturnsStartImmediately() {
    var start = ProfileStartTriggers()
    start.manual = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .startImmediately)
  }

  func testGivenNFCTriggerOnly_WhenDeterminingStartAction_ThenReturnsScanNFC() {
    var start = ProfileStartTriggers()
    start.anyNFC = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .scanNFC)
  }

  func testGivenQRTriggerOnly_WhenDeterminingStartAction_ThenReturnsScanQR() {
    var start = ProfileStartTriggers()
    start.anyQR = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .scanQR)
  }

  func testGivenScheduleTriggerOnly_WhenDeterminingStartAction_ThenReturnsWaitForSchedule() {
    var start = ProfileStartTriggers()
    start.schedule = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .waitForSchedule)
  }

  func testGivenDeepLinkTriggerOnly_WhenDeterminingStartAction_ThenReturnsDeepLinkOnly() {
    var start = ProfileStartTriggers()
    start.deepLink = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .deepLinkOnly)
  }

  func testGivenManualAndNFCTriggers_WhenDeterminingStartAction_ThenShowsPicker() {
    var start = ProfileStartTriggers()
    start.manual = true
    start.anyNFC = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .showPicker(options: [.startImmediately, .scanNFC]))
  }

  func testGivenNFCAndQRTriggers_WhenDeterminingStartAction_ThenShowsPicker() {
    var start = ProfileStartTriggers()
    start.anyNFC = true
    start.anyQR = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .showPicker(options: [.scanNFC, .scanQR]))
  }

  func testGivenManualNFCAndQRTriggers_WhenDeterminingStartAction_ThenShowsPickerWithAll() {
    var start = ProfileStartTriggers()
    start.manual = true
    start.anyNFC = true
    start.anyQR = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .showPicker(options: [.startImmediately, .scanNFC, .scanQR]))
  }

  func testGivenNoTriggers_WhenDeterminingStartAction_ThenReturnsCannotStart() {
    let start = ProfileStartTriggers()

    let action = StartStopActionResolver.determineStartAction(for: start)

    if case .cannotStart = action {
      // expected
    } else {
      XCTFail("Expected .cannotStart, got \(action)")
    }
  }

  func testGivenManualStartWithInvalidStop_WhenDeterminingStartAction_ThenReturnsCannotStart() {
    var start = ProfileStartTriggers()
    start.manual = true
    let stop = ProfileStopConditions()  // all false — invalid

    let action = StartStopActionResolver.determineStartAction(for: start, stopConditions: stop)

    if case .cannotStart = action {
      // expected
    } else {
      XCTFail("Expected .cannotStart, got \(action)")
    }
  }

  func testGivenManualStartWithValidStop_WhenDeterminingStartAction_ThenReturnsStartImmediately() {
    var start = ProfileStartTriggers()
    start.manual = true
    var stop = ProfileStopConditions()
    stop.manual = true

    let action = StartStopActionResolver.determineStartAction(for: start, stopConditions: stop)

    XCTAssertEqual(action, .startImmediately)
  }

  func testGivenActiveSession_WhenStartWithNFCTag_ThenNoSecondSessionAndErrorSurfaced() throws {
    let activeProfile = BlockedProfiles(name: "Active")
    let scannedProfile = BlockedProfiles(name: "Scanned")
    context.insert(activeProfile)
    context.insert(scannedProfile)
    _ = BlockedProfileSession.createSession(
      in: context, withTag: "existing", withProfile: activeProfile)
    try context.save()

    manager.startWithNFCTag(context: context, profile: scannedProfile, tagId: "tag-1")

    XCTAssertEqual(try activeSessions().count, 1)
    XCTAssertNotNil(manager.errorMessage)
  }

  func testGivenProfileNeedsAppSelection_WhenStartWithQRCode_ThenNoSessionAndErrorSurfaced()
    throws
  {
    let profile = BlockedProfiles(name: "Needs Apps")
    profile.needsAppSelection = true
    context.insert(profile)
    try context.save()

    manager.startWithQRCode(context: context, profile: profile, codeValue: "qr-1")

    XCTAssertNil(manager.activeSession)
    XCTAssertTrue(try activeSessions().isEmpty)
    XCTAssertNotNil(manager.errorMessage)
  }

  func testGivenActiveSession_WhenToggleBlockingStart_ThenNoSecondSessionAndErrorSurfaced()
    throws
  {
    let activeProfile = BlockedProfiles(name: "Active")
    let nextProfile = BlockedProfiles(name: "Next")
    nextProfile.blockingStrategyId = ManualBlockingStrategy.id
    context.insert(activeProfile)
    context.insert(nextProfile)
    _ = BlockedProfileSession.createSession(
      in: context, withTag: "existing", withProfile: activeProfile)
    try context.save()

    manager.toggleBlocking(context: context, activeProfile: nextProfile)

    XCTAssertEqual(try activeSessions().count, 1)
    XCTAssertNotNil(manager.errorMessage)
  }

  func testGivenProfileNeedsAppSelection_WhenToggleBlockingStart_ThenNoSessionAndErrorSurfaced()
    throws
  {
    let profile = BlockedProfiles(name: "Needs Apps")
    profile.needsAppSelection = true
    profile.blockingStrategyId = ManualBlockingStrategy.id
    context.insert(profile)
    try context.save()

    manager.toggleBlocking(context: context, activeProfile: profile)

    XCTAssertNil(manager.activeSession)
    XCTAssertTrue(try activeSessions().isEmpty)
    XCTAssertNotNil(manager.errorMessage)
  }

  func testGivenNoActiveSessionAndAppsSelected_WhenStartWithNFCTag_ThenSessionStarts() throws {
    let profile = BlockedProfiles(name: "Ready")
    context.insert(profile)
    try context.save()

    manager.startWithNFCTag(context: context, profile: profile, tagId: "tag-1")

    XCTAssertEqual(manager.activeSession?.blockedProfile.id, profile.id)
    XCTAssertNotNil(manager.timerTask)
  }

  func testGivenProfileNeedsAppSelection_WhenToggleSessionFromDeeplink_ThenNoSessionAndErrorSurfaced()
    async throws
  {
    let profile = BlockedProfiles(name: "Needs Apps")
    profile.needsAppSelection = true
    profile.startTriggers = ProfileStartTriggers(deepLink: true)
    context.insert(profile)
    try context.save()

    await manager.toggleSessionFromDeeplink(
      profile.id.uuidString,
      url: URL(string: "familyfoqos://profile/\(profile.id.uuidString)")!,
      context: context
    )

    XCTAssertNil(manager.activeSession)
    XCTAssertTrue(try activeSessions().isEmpty)
    XCTAssertNotNil(manager.errorMessage)
  }

  func testGivenProfileNeedsAppSelection_WhenToggleSessionFromDeeplinkSwitching_ThenCurrentSessionRemainsAndErrorSurfaced()
    async throws
  {
    let activeProfile = BlockedProfiles(name: "Active")
    activeProfile.stopConditions = ProfileStopConditions(deepLink: true)
    let nextProfile = BlockedProfiles(name: "Needs Apps")
    nextProfile.needsAppSelection = true
    nextProfile.startTriggers = ProfileStartTriggers(deepLink: true)
    context.insert(activeProfile)
    context.insert(nextProfile)
    let activeSession = BlockedProfileSession.createSession(
      in: context, withTag: "active", withProfile: activeProfile)
    try context.save()

    await manager.toggleSessionFromDeeplink(
      nextProfile.id.uuidString,
      url: URL(string: "familyfoqos://profile/\(nextProfile.id.uuidString)")!,
      context: context
    )

    XCTAssertNil(activeSession.endTime)
    XCTAssertEqual(try activeSessions().count, 1)
    XCTAssertNotNil(manager.errorMessage)
  }

  func testGivenGeofenceCheckInFlight_WhenToggleBlockingCalledAgain_ThenSecondCallIsIgnored()
    throws
  {
    let geofenceEvaluator = GeofenceEvaluator()
    geofenceEvaluator.beginGeofenceCheck()
    manager = StrategyManager(geofenceEvaluator: geofenceEvaluator)
    let profile = BlockedProfiles(name: "Manual")
    profile.blockingStrategyId = ManualBlockingStrategy.id
    context.insert(profile)
    try context.save()

    manager.toggleBlocking(context: context, activeProfile: profile)

    XCTAssertNil(manager.activeSession)
    XCTAssertTrue(try activeSessions().isEmpty)
    XCTAssertNotNil(manager.errorMessage)
  }

  func testGivenStaleGeofenceCheckInFlight_WhenToggleBlockingCalledAgain_ThenStartCanProceed()
    throws
  {
    let geofenceEvaluator = GeofenceEvaluator()
    geofenceEvaluator.beginGeofenceCheck(now: Date().addingTimeInterval(-120))
    manager = StrategyManager(geofenceEvaluator: geofenceEvaluator)
    let profile = BlockedProfiles(name: "Manual")
    profile.blockingStrategyId = ManualBlockingStrategy.id
    context.insert(profile)
    try context.save()

    manager.toggleBlocking(context: context, activeProfile: profile)

    XCTAssertEqual(manager.activeSession?.blockedProfile.id, profile.id)
    XCTAssertFalse(geofenceEvaluator.isCheckingGeofence)
  }

  func testGivenRecoveredStaleGeofenceCheck_WhenOldGenerationCompletes_ThenCurrentStateIsNotMutated()
    throws
  {
    let now = Date()
    let geofenceEvaluator = GeofenceEvaluator()
    let staleGeneration = geofenceEvaluator.beginGeofenceCheck(
      now: now.addingTimeInterval(-120))
    XCTAssertTrue(geofenceEvaluator.recoverStaleGeofenceCheck(now: now))
    let currentGeneration = geofenceEvaluator.beginGeofenceCheck(now: now)

    let didCompleteStaleGeneration = geofenceEvaluator.completeGeofenceCheck(
      expectedGeneration: staleGeneration
    ) {
      geofenceEvaluator.errorMessage = "stale completion mutated state"
      geofenceEvaluator.geofenceWarningMessage = "stale warning"
      geofenceEvaluator.showGeofenceStartWarning = true
    }

    XCTAssertFalse(didCompleteStaleGeneration)
    XCTAssertTrue(geofenceEvaluator.isCheckingGeofence)
    XCTAssertNil(geofenceEvaluator.errorMessage)
    XCTAssertEqual(geofenceEvaluator.geofenceWarningMessage, "")
    XCTAssertFalse(geofenceEvaluator.showGeofenceStartWarning)

    let didCompleteCurrentGeneration = geofenceEvaluator.completeGeofenceCheck(
      expectedGeneration: currentGeneration
    ) {
      geofenceEvaluator.errorMessage = "current completion"
    }

    XCTAssertTrue(didCompleteCurrentGeneration)
    XCTAssertFalse(geofenceEvaluator.isCheckingGeofence)
    XCTAssertEqual(geofenceEvaluator.errorMessage, "current completion")
  }

  func testGivenRecoveredStaleGeofenceCheck_WhenEmergencyGenerationCompletes_ThenOldGenerationIsRejected()
    throws
  {
    let now = Date()
    let geofenceEvaluator = GeofenceEvaluator()
    let staleGeneration = geofenceEvaluator.beginGeofenceCheck(
      now: now.addingTimeInterval(-120))
    XCTAssertTrue(geofenceEvaluator.recoverStaleGeofenceCheck(now: now))
    let currentGeneration = geofenceEvaluator.beginGeofenceCheck(now: now)

    XCTAssertFalse(
      geofenceEvaluator.isCurrentGeofenceCheck(expectedGeneration: staleGeneration)
    )
    XCTAssertTrue(
      geofenceEvaluator.isCurrentGeofenceCheck(expectedGeneration: currentGeneration)
    )
  }

  func testGivenActiveSessionFetchFails_WhenRejectionForStart_ThenFailsClosed() throws {
    let profile = BlockedProfiles(name: "Manual")
    context.insert(profile)
    try context.save()

    let rejection = manager.rejectionForStart(profile) {
      throw CocoaError(.fileReadUnknown)
    }

    XCTAssertEqual(rejection, "Couldn't verify whether a session is already active. Try again.")
  }
  func testSpecificNFCStartsWithSpare() throws {
    let profile = BlockedProfiles(name: "Keys")
    profile.startTriggers = ProfileStartTriggers(specificNFC: true)
    profile.physicalKeys = ProfilePhysicalKeys(startNFC: [PhysicalKey(name: "Home", value: "X"), PhysicalKey(name: "Spare", value: "Y")])
    context.insert(profile)
    try context.save()
    manager.startWithNFCTag(context: context, profile: profile, tagId: "Y")
    XCTAssertEqual(manager.activeSession?.blockedProfile.id, profile.id)
  }

  func testSpecificNFCRejectsUnknownKey() throws {
    let profile = BlockedProfiles(name: "Keys")
    profile.startTriggers = ProfileStartTriggers(specificNFC: true)
    profile.physicalKeys = ProfilePhysicalKeys(startNFC: [PhysicalKey(name: "Home", value: "X"), PhysicalKey(name: "Spare", value: "Y")])
    context.insert(profile)
    try context.save()
    manager.startWithNFCTag(context: context, profile: profile, tagId: "Z")
    XCTAssertTrue(try activeSessions().isEmpty)
    XCTAssertTrue(manager.errorMessage?.contains("doesn't match") == true)
  }

  func testSpecificQRStartsWithSpare() throws {
    let profile = BlockedProfiles(name: "Keys")
    profile.startTriggers = ProfileStartTriggers(specificQR: true)
    profile.physicalKeys = ProfilePhysicalKeys(startQR: [PhysicalKey(name: "Home", value: "X"), PhysicalKey(name: "Spare", value: "Y")])
    context.insert(profile)
    try context.save()
    manager.startWithQRCode(context: context, profile: profile, codeValue: "Y")
    XCTAssertEqual(manager.activeSession?.blockedProfile.id, profile.id)
  }

  func testSpecificQRRejectsUnknownKey() throws {
    let profile = BlockedProfiles(name: "Keys")
    profile.startTriggers = ProfileStartTriggers(specificQR: true)
    profile.physicalKeys = ProfilePhysicalKeys(startQR: [PhysicalKey(name: "Home", value: "X"), PhysicalKey(name: "Spare", value: "Y")])
    context.insert(profile)
    try context.save()
    manager.startWithQRCode(context: context, profile: profile, codeValue: "Z")
    XCTAssertTrue(try activeSessions().isEmpty)
    XCTAssertTrue(manager.errorMessage?.contains("doesn't match") == true)
  }

}
