// FoqosTests/TriggerConfigurationModelTests.swift
import XCTest

@testable import FamilyFoqos

@MainActor
final class TriggerConfigurationModelTests: XCTestCase {

  func testAutoFixOnStartTriggerChange() {
    let model = TriggerConfigurationModel()
    model.stopConditions.sameNFC = true

    // Changing start to have no NFC should auto-fix
    model.startTriggers.manual = true
    model.startTriggersDidChange()

    XCTAssertFalse(model.stopConditions.sameNFC)
  }

  func testValidationErrorsUpdateOnChange() {
    let model = TriggerConfigurationModel()
    // Empty triggers should have errors

    XCTAssertFalse(model.validationErrors.isEmpty)

    model.startTriggers.manual = true
    model.stopConditions.manual = true
    model.validate()

    XCTAssertTrue(model.validationErrors.isEmpty)
  }

  func testIsStopEnabled() {
    let model = TriggerConfigurationModel()
    model.startTriggers.anyNFC = true

    XCTAssertTrue(model.isStopEnabled(.sameNFC))
    XCTAssertFalse(model.isStopEnabled(.sameQR))
  }

  func testReasonStopDisabled() {
    let model = TriggerConfigurationModel()
    model.startTriggers.manual = true

    XCTAssertNotNil(model.reasonStopDisabled(.sameNFC))
    XCTAssertNil(model.reasonStopDisabled(.manual))
  }
}
