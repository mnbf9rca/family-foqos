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
    // Empty triggers should have errors after validation
    model.validate()

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

  func testValidationErrorsClearWhenStopConditionAdded() {
    let model = TriggerConfigurationModel()
    model.startTriggers.manual = true
    model.startTriggersDidChange()

    // At this point we have a start trigger but no stop condition
    XCTAssertTrue(
      model.validationErrors.contains { $0.contains("stop condition") },
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

  func testValidationErrorsAppearWhenStopConditionRemoved() {
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
      model.validationErrors.contains { $0.contains("stop condition") },
      "Should have stop condition error after removing stop"
    )
  }
}
