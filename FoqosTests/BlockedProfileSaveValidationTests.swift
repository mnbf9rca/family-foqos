import FamilyControls
import FoqosShared
import SwiftData
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
  func testEditorSaveAndCloneRejectBeforeEffects() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let suiteName = "SaveValidation-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    let valid = TriggerConfigurationModel()
    valid.startTriggers = .init(manual: true)
    valid.stopConditions = .init(manual: true)
    let source = try BlockedProfiles.createProfile(in: context, name: "Original", triggerConfiguration: valid)
    let snapshot = SharedData.snapshot(for: source.id.uuidString)
    let rows: [(ProfileStartTriggers, ProfileStopConditions, String)] = [
      (.init(manual: true), .init(), "Add at least one stop before saving this profile."),
      (.init(manual: true, anyNFC: true), .init(nfc: .same), "Same NFC tag only works after an NFC start. Add another stop for other starts."),
      (.init(manual: true), .init(nfc: .specific), "Choose at least one NFC tag."),
      (.init(manual: true), .init(timer: true), "Choose a timer from 15 minutes to 23 hours 59 minutes."),
    ]
    for (starts, stops, message) in rows {
      let draft = TriggerConfigurationModel()
      draft.startTriggers = starts
      draft.stopConditions = stops
      XCTAssertThrowsError(try BlockedProfiles.createProfile(in: context, name: "Rejected", triggerConfiguration: draft)) { error in
        XCTAssertTrue(error.localizedDescription.contains(message))
      }
      XCTAssertThrowsError(try BlockedProfiles.updateProfile(source, in: context, now: now, name: "Changed", triggerConfiguration: draft)) { error in
        XCTAssertTrue(error.localizedDescription.contains(message))
      }
      XCTAssertEqual(source.name, "Original")
      XCTAssertEqual(source.stopConditions, ProfileStopConditions(manual: true))
      XCTAssertEqual(SharedData.snapshot(for: source.id.uuidString), snapshot)
      XCTAssertEqual(try BlockedProfiles.fetchProfiles(in: context).count, 1)
      let candidate = BlockedProfiles(name: "Candidate", createdAt: now, updatedAt: now)
      candidate.startTriggers = starts
      candidate.stopConditions = stops
      context.insert(candidate)
      try context.save()
      let count = try BlockedProfiles.fetchProfiles(in: context).count
      XCTAssertThrowsError(try BlockedProfiles.cloneProfile(candidate, in: context, newName: "Rejected")) { error in
        XCTAssertTrue(error.localizedDescription.contains(message))
      }
      XCTAssertEqual(try BlockedProfiles.fetchProfiles(in: context).count, count)
      context.delete(candidate)
      try context.save()
    }
    for id: String? in [nil, "ShortcutTimerBlockingStrategy"] {
      let legacy = BlockedProfiles(name: "Invalid legacy", createdAt: now, updatedAt: now)
      legacy.blockingStrategyId = id
      legacy.profileSchemaVersion = 1
      context.insert(legacy)
      try context.save()
      XCTAssertThrowsError(try BlockedProfiles.cloneProfile(legacy, in: context, newName: "Rejected"))
      XCTAssertEqual(legacy.profileSchemaVersion, 1)
      XCTAssertNil(SharedData.snapshot(for: legacy.id.uuidString))
      XCTAssertTrue(try SavedTag.fetchAll(in: context).isEmpty)
    }
    let unreadable = BlockedProfiles(name: "Unreadable", createdAt: now, updatedAt: now)
    unreadable.startTriggers = .init(manual: true)
    unreadable.stopConditionsData = Data("bad".utf8)
    context.insert(unreadable)
    try context.save()
    XCTAssertThrowsError(try BlockedProfiles.cloneProfile(unreadable, in: context, newName: "Rejected")) { error in
      XCTAssertEqual(error.localizedDescription, "These settings couldn’t be saved. Please check this profile and try again.")
    }
    XCTAssertEqual(unreadable.stopConditionsData, Data("bad".utf8))
    XCTAssertNil(SharedData.snapshot(for: unreadable.id.uuidString))
  }

  func testReadOnlyStoreSaveFailurePublishesNothingAndRestoresLiveConfiguration() throws {
    let now = Date()
    let schema = Schema([BlockedProfiles.self, BlockedProfileSession.self, SavedLocation.self, SavedTag.self])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("readonly.store")
    let id = UUID()
    do {
      let writable = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
      let context = ModelContext(writable)
      let profile = BlockedProfiles(id: id, name: "Original", createdAt: now, updatedAt: now)
      profile.startTriggers = .init(manual: true)
      profile.stopConditions = .init(manual: true)
      context.insert(profile)
      try context.save()
    }
    let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none)])
    let context = container.mainContext
    let source = try XCTUnwrap(BlockedProfiles.findProfile(byID: id, in: context))
    let suiteName = "ReadOnlySave-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    BlockedProfiles.updateSnapshot(for: source)
    let originalSnapshot = SharedData.snapshot(for: id.uuidString)
    let draft = TriggerConfigurationModel()
    draft.startTriggers = .init(manual: true)
    draft.stopConditions = .init(timer: true, timerDurationMinutes: 37, allowChangingTimerBeforeStart: true)
    XCTAssertThrowsError(try BlockedProfiles.updateProfile(source, in: context, now: now, name: "Changed", triggerConfiguration: draft))
    XCTAssertEqual(source.name, "Original")
    XCTAssertEqual(source.startTriggers, ProfileStartTriggers(manual: true))
    XCTAssertEqual(source.stopConditions, ProfileStopConditions(manual: true))
    XCTAssertEqual(source.updatedAt, now)
    XCTAssertEqual(SharedData.snapshot(for: id.uuidString), originalSnapshot)
    XCTAssertThrowsError(try BlockedProfiles.createProfile(in: context, name: "Rejected", triggerConfiguration: draft))
    XCTAssertThrowsError(try BlockedProfiles.cloneProfile(source, in: context, newName: "Rejected"))
    XCTAssertEqual(try BlockedProfiles.fetchProfiles(in: context).map(\.id), [id])
    XCTAssertEqual(SharedData.profileSnapshots.count, 1)
    XCTAssertEqual(SharedData.snapshot(for: id.uuidString), originalSnapshot)
  }

  func testUnreadableStoredSettingsCanBeRepairedByDraftSave() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Repair", createdAt: now, updatedAt: now)
    profile.startTriggersData = Data("bad-start".utf8)
    profile.stopConditionsData = Data("bad-stop".utf8)
    context.insert(profile)
    try context.save()
    XCTAssertTrue(profile.hasInvalidConditionSettings)
    let draft = TriggerConfigurationModel()
    try draft.loadFromProfile(profile, in: context)
    XCTAssertFalse(draft.startTriggers.isValid)
    XCTAssertFalse(draft.stopConditions.isValid)
    draft.startTriggers.manual = true
    draft.stopConditions.manual = true
    _ = try BlockedProfiles.updateProfile(profile, in: context, now: now, triggerConfiguration: draft)
    let reloaded = try XCTUnwrap(BlockedProfiles.findProfile(byID: profile.id, in: ModelContext(container)))
    XCTAssertTrue(reloaded.conditionSettingsReadable)
    XCTAssertFalse(reloaded.hasInvalidConditionSettings)
    XCTAssertFalse(reloaded.stopConditions.requiresEditingAfterConversion)
  }

}
