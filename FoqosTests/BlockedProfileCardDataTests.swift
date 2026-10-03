import FamilyControls
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class BlockedProfileCardDataTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!

  override func setUp() async throws {
    try await super.setUp()
    container = try TestModelContainer.create()
    context = container.mainContext
  }

  override func tearDown() async throws {
    context = nil
    container = nil
    try await super.tearDown()
  }

  func testV2SummariesFollowIndependentConditionsInsteadOfStrategy() throws {
    let profile = BlockedProfiles(name: "V2", blockingStrategyId: NFCBlockingStrategy.id)
    profile.startTriggers = ProfileStartTriggers(manual: true, shortcuts: true)
    profile.stopConditions = ProfileStopConditions(timer: true, timerDurationMinutes: 45)
    context.insert(profile)
    let card = makeCard(profile)
    XCTAssertEqual(card.startSummary, "Tap to start, Siri and Shortcuts")
    XCTAssertEqual(card.stopSummary, "Timer")
  }

  func testTagSummariesPreserveKindsAndIndependentOtherConditions() throws {
    let profile = BlockedProfiles(name: "Tags", blockingStrategyId: ManualBlockingStrategy.id)
    profile.startTriggers = ProfileStartTriggers(anyNFC: true, specificQR: true, schedule: true, deepLink: true)
    profile.stopConditions = ProfileStopConditions(manual: true, schedule: true, nfc: .same, qr: .specific)
    context.insert(profile)
    let card = makeCard(profile)
    XCTAssertEqual(card.startSummary, "NFC: Any tag, QR: Specific code, Schedule, Written NFC / printed QR")
    XCTAssertEqual(card.stopSummary, "Tap to stop, NFC: Same tag, QR: Specific code, Schedule")
    profile.stopConditions = ProfileStopConditions(nfc: .specific, qr: .any)
    XCTAssertEqual(makeCard(profile).stopSummary, "NFC: Specific tag, QR: Any code")
  }

  func testV1StrategyIsRetainedOnlyForUnmigratedProfile() throws {
    let profile = BlockedProfiles(name: "V1", blockingStrategyId: NFCBlockingStrategy.id)
    context.insert(profile)
    profile.profileSchemaVersion = 1
    XCTAssertNil(makeCard(profile).startSummary)
    XCTAssertNil(makeCard(profile).stopSummary)
    profile.profileSchemaVersion = 2
    XCTAssertEqual(makeCard(profile).startSummary, "None")
    XCTAssertEqual(makeCard(profile).stopSummary, "None")
  }

  func testDeadlineSnapshotTracksActiveSessionAndSurvivesDeletion() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Deadline")
    context.insert(profile)
    let completed = BlockedProfileSession(tag: "old", blockedProfile: profile, startTime: now.addingTimeInterval(-3600))
    completed.timerEndTime = now.addingTimeInterval(-1800)
    completed.endTime = now.addingTimeInterval(-1800)
    context.insert(completed)
    let active = BlockedProfileSession(tag: "manual", blockedProfile: profile, startTime: now)
    active.timerEndTime = now.addingTimeInterval(1800)
    context.insert(active)
    try context.save()
    let before = profile.cardData
    XCTAssertEqual(before.timerEndTime, now.addingTimeInterval(1800))
    active.timerEndTime = now.addingTimeInterval(2700)
    XCTAssertEqual(profile.cardData.timerEndTime, now.addingTimeInterval(2700))
    context.delete(active)
    context.delete(completed)
    context.delete(profile)
    try context.save()
    XCTAssertEqual(before.timerEndTime, now.addingTimeInterval(1800))
  }

  private func makeCard(_ profile: BlockedProfiles) -> BlockedProfileCard {
    BlockedProfileCard(data: profile.cardData, onStartTapped: {}, onStopTapped: {}, onEditTapped: {}, onBreakTapped: {})
  }

  func testGivenProfile_WhenCardData_ThenMapsScalarAndDerivedFields() throws {
    let profile = BlockedProfiles(
      id: UUID(), name: "Work", selectedActivity: FamilyActivitySelection(),
      blockingStrategyId: NFCBlockingStrategy.id, enableLiveActivity: true,
      reminderTimeInSeconds: 3600
    )
    context.insert(profile)

    let data = profile.cardData

    XCTAssertEqual(data.id, profile.id)
    XCTAssertEqual(data.name, "Work")
    XCTAssertTrue(data.enableLiveActivity)
    XCTAssertTrue(data.hasReminders)
    XCTAssertEqual(data.blockingStrategyId, NFCBlockingStrategy.id)
    XCTAssertEqual(data.sessionCount, 0)
    XCTAssertEqual(data.domainsCount, 0)
    XCTAssertFalse(data.isNewerSchemaVersion)
    XCTAssertEqual(data.profileSchemaVersion, BlockedProfiles.currentSchemaVersion)
  }

  func testGivenModelMutated_WhenCardDataRebuilt_ThenReflectsChange() throws {
    let profile = BlockedProfiles(
      id: UUID(), name: "Before", selectedActivity: FamilyActivitySelection())
    context.insert(profile)

    let before = profile.cardData
    XCTAssertEqual(before.name, "Before")

    profile.name = "After"
    let after = profile.cardData

    XCTAssertEqual(after.name, "After")
    XCTAssertEqual(before.name, "Before")
  }

  func testGivenCardDataThenModelDeletedAndSaved_ThenValuesStillReadableNoTrap() throws {
    let profile = BlockedProfiles(
      id: UUID(), name: "Gaming", selectedActivity: FamilyActivitySelection(),
      blockingStrategyId: QRCodeBlockingStrategy.id
    )
    context.insert(profile)
    try context.save()

    let data = profile.cardData

    context.delete(profile)
    try context.save()

    XCTAssertFalse(profile.isPersistentModelValid)
    XCTAssertEqual(data.name, "Gaming")
    XCTAssertEqual(data.blockingStrategyId, QRCodeBlockingStrategy.id)
  }
}
