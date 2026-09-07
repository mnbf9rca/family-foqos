// FoqosTests/BlockedProfilesTriggersTests.swift
import SwiftUI
import XCTest

@testable import FamilyFoqos

final class BlockedProfilesTriggersTests: XCTestCase {

  func testGivenNewProfile_WhenCheckingSchema_ThenReturnsVersion2() {
    let profile = BlockedProfiles(name: "Test")

    XCTAssertEqual(profile.profileSchemaVersion, 2)
  }

  func testGivenNewProfile_WhenCheckingTriggers_ThenBothAreInvalid() {
    let profile = BlockedProfiles(name: "Test")

    XCTAssertFalse(profile.startTriggers.isValid)
    XCTAssertFalse(profile.stopConditions.isValid)
  }

  func testGivenNewProfile_WhenSettingStartTriggers_ThenTriggersAreStored() {
    let profile = BlockedProfiles(name: "Test")
    var triggers = profile.startTriggers
    triggers.manual = true
    triggers.anyNFC = true
    profile.startTriggers = triggers

    XCTAssertTrue(profile.startTriggers.manual)
    XCTAssertTrue(profile.startTriggers.anyNFC)
    XCTAssertTrue(profile.startTriggers.isValid)
  }

  func testGivenNewProfile_WhenSettingStopConditions_ThenConditionsAreStored() {
    let profile = BlockedProfiles(name: "Test")
    var conditions = profile.stopConditions
    conditions.manual = true
    conditions.timer = true
    profile.stopConditions = conditions

    XCTAssertTrue(profile.stopConditions.manual)
    XCTAssertTrue(profile.stopConditions.timer)
    XCTAssertTrue(profile.stopConditions.isValid)
  }

  func testGivenNewProfile_WhenSettingStartNFCTagId_ThenIdIsStored() {
    let profile = BlockedProfiles(name: "Test")
    profile.startNFCTagId = "tag-123"
    XCTAssertEqual(profile.startNFCTagId, "tag-123")
  }

  func testGivenNewProfile_WhenSettingStopNFCTagId_ThenIdIsStored() {
    let profile = BlockedProfiles(name: "Test")
    profile.stopNFCTagId = "tag-456"
    XCTAssertEqual(profile.stopNFCTagId, "tag-456")
  }

  func testGivenNewProfile_WhenSettingStartQRCodeId_ThenIdIsStored() {
    let profile = BlockedProfiles(name: "Test")
    profile.startQRCodeId = "qr-123"
    XCTAssertEqual(profile.startQRCodeId, "qr-123")
  }

  func testGivenNewProfile_WhenSettingStopQRCodeId_ThenIdIsStored() {
    let profile = BlockedProfiles(name: "Test")
    profile.stopQRCodeId = "qr-456"
    XCTAssertEqual(profile.stopQRCodeId, "qr-456")
  }

  func testGivenNewProfile_WhenSettingStartSchedule_ThenScheduleIsStored() {
    let profile = BlockedProfiles(name: "Test")
    let schedule = ProfileScheduleTime(
      days: [.monday, .friday],
      hour: 9,
      minute: 0,
      updatedAt: Date()
    )
    profile.startSchedule = schedule

    XCTAssertEqual(profile.startSchedule?.days, [.monday, .friday])
    XCTAssertEqual(profile.startSchedule?.hour, 9)
  }

  func testGivenNewProfile_WhenSettingStopSchedule_ThenScheduleIsStored() {
    let profile = BlockedProfiles(name: "Test")
    let schedule = ProfileScheduleTime(
      days: [.monday, .friday],
      hour: 17,
      minute: 30,
      updatedAt: Date()
    )
    profile.stopSchedule = schedule

    XCTAssertEqual(profile.stopSchedule?.days, [.monday, .friday])
    XCTAssertEqual(profile.stopSchedule?.hour, 17)
  }

  func testGivenProfileWithV2Triggers_WhenCloning_ThenAllTriggerDataIsCopied() {
    let source = BlockedProfiles(name: "Source")

    // Set V2 trigger data on source
    var start = source.startTriggers
    start.anyNFC = true
    start.schedule = true
    source.startTriggers = start

    var stop = source.stopConditions
    stop.sameNFC = true
    stop.timer = true
    source.stopConditions = stop

    source.startNFCTagId = "nfc-start-123"
    source.startQRCodeId = "qr-start-456"
    source.stopNFCTagId = "nfc-stop-789"
    source.stopQRCodeId = "qr-stop-012"

    source.startSchedule = ProfileScheduleTime(
      days: [.monday, .wednesday], hour: 9, minute: 0, updatedAt: Date()
    )
    source.stopSchedule = ProfileScheduleTime(
      days: [.monday, .wednesday], hour: 17, minute: 0, updatedAt: Date()
    )

    // Clone (without ModelContext — just test the field copy logic)
    let cloned = BlockedProfiles(name: "Clone")
    cloned.startTriggers = source.startTriggers
    cloned.stopConditions = source.stopConditions
    cloned.startNFCTagId = source.startNFCTagId
    cloned.startQRCodeId = source.startQRCodeId
    cloned.stopNFCTagId = source.stopNFCTagId
    cloned.stopQRCodeId = source.stopQRCodeId
    cloned.startSchedule = source.startSchedule
    cloned.stopSchedule = source.stopSchedule

    XCTAssertEqual(cloned.startTriggers.anyNFC, true)
    XCTAssertEqual(cloned.startTriggers.schedule, true)
    XCTAssertEqual(cloned.stopConditions.sameNFC, true)
    XCTAssertEqual(cloned.stopConditions.timer, true)
    XCTAssertEqual(cloned.startNFCTagId, "nfc-start-123")
    XCTAssertEqual(cloned.startQRCodeId, "qr-start-456")
    XCTAssertEqual(cloned.stopNFCTagId, "nfc-stop-789")
    XCTAssertEqual(cloned.stopQRCodeId, "qr-stop-012")
    XCTAssertEqual(cloned.startSchedule?.hour, 9)
    XCTAssertEqual(cloned.stopSchedule?.hour, 17)
  }
  @MainActor
  func testSpecificListsRequireKeysAndDuplicateScansAreRejected() {
    let model = TriggerConfigurationModel()
    model.startTriggers = ProfileStartTriggers(specificNFC: true, specificQR: true)
    model.stopConditions = ProfileStopConditions(specificNFC: true, specificQR: true)
    let slots: [(ReferenceWritableKeyPath<TriggerConfigurationModel, [PhysicalKey]>, String, String)] = [
      (\.startNFC, "Tag", "Scan an NFC tag to use as the start trigger"),
      (\.startQR, "Code", "Scan a QR code to use as the start trigger"),
      (\.stopNFC, "Tag", "Scan an NFC tag to use as the stop condition"),
      (\.stopQR, "Code", "Scan a QR code to use as the stop condition"),
    ]
    model.validate()
    for (slot, label, error) in slots {
      XCTAssertTrue(model.validationErrors.contains(error))
      XCTAssertNil(model.appendKey(value: "X", to: slot, label: label))
      XCTAssertFalse(model.validationErrors.contains(error))
      XCTAssertEqual(model[keyPath: slot], [PhysicalKey(name: "\(label) 1", value: "X")])
      XCTAssertEqual(model.appendKey(value: "X", to: slot, label: label), "This \(label.lowercased() == "tag" ? "tag" : "QR code") is already on the list")
      XCTAssertEqual(model[keyPath: slot].count, 1)
    }
  }

  @MainActor
  func testBlankKeyNamesBecomeDefaultsOnSaveAndListsReload() throws {
    let model = TriggerConfigurationModel()
    let unnamed = [PhysicalKey(name: "  ", value: "X")]
    model.startNFC = unnamed
    model.stopNFC = unnamed
    model.startQR = unnamed
    model.stopQR = unnamed
    let profile = BlockedProfiles(name: "Keys")
    model.saveToProfile(profile)
    XCTAssertEqual(profile.physicalKeys.startNFC.first?.name, "NFC tag")
    XCTAssertEqual(profile.physicalKeys.stopNFC.first?.name, "NFC tag")
    XCTAssertEqual(profile.physicalKeys.startQR.first?.name, "QR code")
    XCTAssertEqual(profile.physicalKeys.stopQR.first?.name, "QR code")
    let reloaded = TriggerConfigurationModel()
    let container = try TestModelContainer.create()
    container.mainContext.insert(profile)
    try reloaded.loadFromProfile(profile, in: container.mainContext)
    XCTAssertEqual(reloaded.startNFC, profile.physicalKeys.startNFC)
    XCTAssertEqual(reloaded.stopQR, profile.physicalKeys.stopQR)
  }

  @MainActor
  func testDeletingLastKeyRefreshesValidationAndDisabledDeletionDoesNothing() {
    let model = TriggerConfigurationModel()
    model.startTriggers = ProfileStartTriggers(specificNFC: true)
    model.startNFC = [PhysicalKey(name: "Tag", value: "X")]
    model.validate()
    let keys = Binding(get: { model.startNFC }, set: { model.startNFC = $0 })
    for disabled in [true, false] {
      var callbacks = 0
      let rows = PhysicalKeyRows(
        keys: keys, label: "Tag", disabled: disabled, onScan: {},
        onChange: {
          callbacks += 1
          model.startTriggersDidChange()
        })
      rows.delete(at: IndexSet(integer: 0))
      XCTAssertEqual(callbacks, disabled ? 0 : 1)
      XCTAssertEqual(model.startNFC.isEmpty, !disabled)
      XCTAssertEqual(model.validationErrors.contains("Scan an NFC tag to use as the start trigger"), !disabled)
    }
  }

}
