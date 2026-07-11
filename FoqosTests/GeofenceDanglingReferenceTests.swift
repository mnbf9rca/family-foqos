import FoqosShared
import XCTest

@testable import FamilyFoqos

@MainActor
final class GeofenceDanglingReferenceTests: XCTestCase {

  private func rule(_ type: GeofenceRuleType, refs: [UUID]) -> ProfileGeofenceRule {
    ProfileGeofenceRule(
      ruleType: type,
      locationReferences: refs.map { ProfileLocationReference(savedLocationId: $0) },
      allowEmergencyOverride: true)
  }

  func testGivenOutsideRuleWithOnlyDanglingRef_WhenEvaluated_ThenSatisfied() async {
    // No SavedLocation matches the reference => the rule has no live constraint => stoppable.
    let result = await LocationManager.shared.checkGeofenceRule(
      rule: rule(.outside, refs: [UUID()]), savedLocations: [])
    XCTAssertTrue(result.isSatisfied, "an all-dangling .outside rule must not be unsatisfiable")
  }

  func testGivenWithinRuleWithOnlyDanglingRef_WhenEvaluated_ThenSatisfied() async {
    let result = await LocationManager.shared.checkGeofenceRule(
      rule: rule(.within, refs: [UUID()]), savedLocations: [])
    XCTAssertTrue(result.isSatisfied, "an all-dangling .within rule must not fail forever")
  }
}
