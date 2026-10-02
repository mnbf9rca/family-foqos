// FoqosTests/TriggerConfigurationModelTests.swift
import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class TriggerConfigurationModelTests: XCTestCase {

  func testLeavingSpecificStartClearsOnlyThatRolesAssignments() throws {
    let now = Date()
    for (nfc, qr) in [(NFCStartOption.none, QRStartOption.none), (.any, .any)] {
      let container = try TestModelContainer.create()
      let context = container.mainContext
      let profile = BlockedProfiles(name: "Profile", createdAt: now, updatedAt: now)
      context.insert(profile)
      let model = TriggerConfigurationModel()
      model.startTriggers.specificNFC = true
      model.startTriggers.specificQR = true
      model.stopConditions.specificNFC = true
      model.startNFCTagIds = ["start-nfc"]
      model.startQRCodeIds = ["start-qr"]
      model.stopNFCTagIds = ["stop-nfc"]

      nfc.apply(to: &model.startTriggers)
      model.startTriggersDidChange()
      XCTAssertTrue(model.startNFCTagIds.isEmpty)
      XCTAssertEqual(model.startQRCodeIds, ["start-qr"])
      XCTAssertEqual(model.stopNFCTagIds, ["stop-nfc"])
      qr.apply(to: &model.startTriggers)
      model.startTriggersDidChange()
      XCTAssertTrue(model.startQRCodeIds.isEmpty)
      model.saveToProfile(profile)
      try context.save()
      XCTAssertEqual(SavedTag.assignments(profiles: [profile]), ["stop-nfc": ["Profile"]])
      NFCStartOption.specific.apply(to: &model.startTriggers)
      model.startTriggersDidChange()
      XCTAssertTrue(model.validationErrors.contains("Choose at least one NFC tag."))
    }
  }

  func testLeavingSpecificStopClearsOnlyThatRolesAssignments() throws {
    let now = Date()
    for (nfc, qr) in [(NFCStopOption.none, QRStopOption.none), (.any, .any), (.same, .same)] {
      let container = try TestModelContainer.create()
      let context = container.mainContext
      let profile = BlockedProfiles(name: "Profile", createdAt: now, updatedAt: now)
      context.insert(profile)
      let model = TriggerConfigurationModel()
      model.startTriggers.specificNFC = true
      model.startTriggers.anyQR = true
      model.stopConditions.specificNFC = true
      model.stopConditions.specificQR = true
      model.startNFCTagIds = ["start-nfc"]
      model.stopNFCTagIds = ["stop-nfc"]
      model.stopQRCodeIds = ["stop-qr"]

      nfc.apply(to: &model.stopConditions)
      model.stopConditionsDidChange()
      XCTAssertTrue(model.stopNFCTagIds.isEmpty)
      XCTAssertEqual(model.stopQRCodeIds, ["stop-qr"])
      XCTAssertEqual(model.startNFCTagIds, ["start-nfc"])
      qr.apply(to: &model.stopConditions)
      model.stopConditionsDidChange()
      XCTAssertTrue(model.stopQRCodeIds.isEmpty)
      model.saveToProfile(profile)
      try context.save()
      XCTAssertEqual(SavedTag.assignments(profiles: [profile]), ["start-nfc": ["Profile"]])
      QRStopOption.specific.apply(to: &model.stopConditions)
      model.stopConditionsDidChange()
      XCTAssertTrue(model.validationErrors.contains("Choose at least one QR code."))
    }
  }

  func testGivenSameNFCWithNoNFCStart_WhenStartTriggersChange_ThenPreservesStop() {
    let model = TriggerConfigurationModel()
    model.stopConditions.sameNFC = true

    // Changing start to have no NFC should auto-fix
    model.startTriggers.manual = true
    model.startTriggersDidChange()

    XCTAssertTrue(model.stopConditions.sameNFC)
  }

  func testGivenEmptyTriggers_WhenValidating_ThenShowsErrorsThatClearWhenValid() {
    let model = TriggerConfigurationModel()
    // Empty triggers should have errors after validation
    model.validate()

    XCTAssertFalse(model.validationErrors.isEmpty)

    model.startTriggers.manual = true
    model.stopConditions.manual = true
    model.validate()

    XCTAssertTrue(model.validationErrors.isEmpty)
  }

  func testGivenStartWithNoStop_WhenAddingStopCondition_ThenValidationErrorsCleared() {
    let model = TriggerConfigurationModel()
    model.startTriggers.manual = true
    model.startTriggersDidChange()

    // At this point we have a start trigger but no stop condition
    XCTAssertTrue(
      model.validationErrors.contains { $0 == "Add at least one stop before saving this profile." },
      "Should have stop condition error before adding stop"
    )

    // Add a stop condition - validation errors should auto-clear
    model.stopConditions.manual = true
    model.stopConditionsDidChange()

    XCTAssertTrue(
      model.validationErrors.isEmpty,
      "Validation errors should clear after adding valid stop condition"
    )
  }

  func testGivenValidStartAndStop_WhenRemovingStopCondition_ThenValidationErrorAppears() {
    let model = TriggerConfigurationModel()
    model.startTriggers.manual = true
    model.stopConditions.manual = true
    model.startTriggersDidChange()

    // Valid state - no errors
    XCTAssertTrue(model.validationErrors.isEmpty, "Should have no errors when valid")

    // Remove stop condition - should trigger validation error
    model.stopConditions.manual = false
    model.stopConditionsDidChange()

    XCTAssertTrue(
      model.validationErrors.contains { $0 == "Add at least one stop before saving this profile." },
      "Should have stop condition error after removing stop"
    )
  }

  func testGivenMatchingScheduleTimes_WhenValidating_ThenShowsEqualTimeError() {
    let now = Date()
    let model = TriggerConfigurationModel()
    model.startTriggers.schedule = true
    model.stopConditions.schedule = true
    model.startSchedule = ProfileScheduleTime(
      days: [.monday], hour: 10, minute: 0, updatedAt: now
    )
    model.stopSchedule = ProfileScheduleTime(
      days: [.monday], hour: 10, minute: 0, updatedAt: now
    )
    model.validate()

    XCTAssertTrue(
      model.validationErrors.contains { $0 == "Choose different moments for scheduled start and stop." },
      "Should have error when start and stop schedule times are equal"
    )
  }

  func testGivenDifferentScheduleTimes_WhenValidating_ThenNoEqualTimeError() {
    let now = Date()
    let model = TriggerConfigurationModel()
    model.startTriggers.schedule = true
    model.stopConditions.schedule = true
    model.startSchedule = ProfileScheduleTime(
      days: [.monday], hour: 10, minute: 0, updatedAt: now
    )
    model.stopSchedule = ProfileScheduleTime(
      days: [.monday], hour: 17, minute: 0, updatedAt: now
    )
    model.validate()

    XCTAssertFalse(
      model.validationErrors.contains { $0 == "Choose different moments for scheduled start and stop." },
      "Should not have equal-time error when times differ"
    )
  }
  func testStartChangesPreserveEveryStopOwnedSetting() throws {
    let now = Date()
    let model = TriggerConfigurationModel()
    model.stopConditions = .init(timer: true, schedule: true, nfc: .same, qr: .specific, timerDurationMinutes: 37, allowChangingTimerBeforeStart: true)
    model.stopNFCTagIds = ["dormant-nfc"]
    model.stopQRCodeIds = ["stop-qr"]
    model.stopSchedule = .init(days: [.friday], hour: 17, minute: 30, updatedAt: now)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let stops = try encoder.encode(model.stopConditions)
    let schedule = try encoder.encode(model.stopSchedule)
    for start in [ProfileStartTriggers(anyNFC: true), .init(anyQR: true), .init(manual: true), .init(deepLink: true), .init(schedule: true)] {
      model.startTriggers = start
      model.startTriggersDidChange()
      XCTAssertEqual(try encoder.encode(model.stopConditions), stops)
      XCTAssertEqual(try encoder.encode(model.stopSchedule), schedule)
      XCTAssertEqual(model.stopQRCodeIds, ["stop-qr"])
    }
    model.stopConditions.timer = false
    model.stopConditionsDidChange()
    model.stopConditions.timer = true
    model.stopConditionsDidChange()
    XCTAssertEqual(try encoder.encode(model.stopConditions), stops)
    XCTAssertEqual(model.stopNFCTagIds, ["dormant-nfc"])
  }

}
