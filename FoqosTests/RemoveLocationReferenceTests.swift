import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class RemoveLocationReferenceTests: XCTestCase {

  private func profile(
    _ context: ModelContext,
    name: String,
    rule: ProfileGeofenceRule?
  ) throws -> BlockedProfiles {
    let profile = BlockedProfiles(id: UUID(), name: name)
    profile.geofenceRule = rule
    context.insert(profile)
    try context.save()
    return profile
  }

  func testGivenProfilesReferencingLocation_WhenRemoved_ThenStrippedAndChangedIdsReturned() throws {
    let container = try TestModelContainer.create()
    let context = ModelContext(container)
    let locId = UUID()
    let ruleWith = ProfileGeofenceRule(
      ruleType: .outside,
      locationReferences: [ProfileLocationReference(savedLocationId: locId)],
      allowEmergencyOverride: true)
    let referencing = try profile(context, name: "Ref", rule: ruleWith)
    _ = try profile(context, name: "Unrelated", rule: nil)

    let changed = try BlockedProfiles.removeLocationReference(locId, in: context)
    try context.save()

    XCTAssertEqual(changed, [referencing.id])
    let reread = try XCTUnwrap(BlockedProfiles.findProfile(byID: referencing.id, in: context))
    XCTAssertNil(reread.geofenceRule, "rule with only that reference is nulled when it empties")
  }

  func testGivenMultiRefRule_WhenOneRemoved_ThenOthersKept() throws {
    let container = try TestModelContainer.create()
    let context = ModelContext(container)
    let locId = UUID()
    let keepId = UUID()
    let rule = ProfileGeofenceRule(
      ruleType: .within,
      locationReferences: [
        ProfileLocationReference(savedLocationId: locId),
        ProfileLocationReference(savedLocationId: keepId),
      ],
      allowEmergencyOverride: true)
    let profile = try profile(context, name: "Multi", rule: rule)

    let changed = try BlockedProfiles.removeLocationReference(locId, in: context)
    try context.save()

    XCTAssertEqual(changed, [profile.id])
    let reread = try XCTUnwrap(BlockedProfiles.findProfile(byID: profile.id, in: context))
    XCTAssertEqual(reread.geofenceRule?.locationReferences.map { $0.savedLocationId }, [keepId])
  }

  func testGivenNoReferences_WhenRemoved_ThenNoChange() throws {
    let container = try TestModelContainer.create()
    let context = ModelContext(container)
    _ = try profile(context, name: "None", rule: nil)
    let changed = try BlockedProfiles.removeLocationReference(UUID(), in: context)
    XCTAssertTrue(changed.isEmpty)
  }
}
