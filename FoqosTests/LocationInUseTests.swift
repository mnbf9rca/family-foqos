import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class LocationInUseTests: XCTestCase {
  private func makeProfile(locationId: UUID, in context: ModelContext) throws -> BlockedProfiles {
    let profile = BlockedProfiles(name: "Homework")
    profile.geofenceRule = ProfileGeofenceRule(
      ruleType: .outside,
      locationReferences: [ProfileLocationReference(savedLocationId: locationId)],
      allowEmergencyOverride: true)
    context.insert(profile)
    try context.save()
    return profile
  }

  func testGivenRemotelyActiveProfileWithGeofence_WhenComputingInUse_ThenLocationLocked()
    throws
  {
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let locationId = UUID()
    let profile = try makeProfile(locationId: locationId, in: context)

    let inUse = SavedLocationsView.locationsInUse(
      profiles: [profile],
      hasLocalActiveSession: { _ in false },
      remotelyActiveProfileIds: [profile.id])

    XCTAssertEqual(
      inUse[locationId], profile.name,
      "#311: a location used by a profile running on another device must be locked here")
  }

  func testGivenInactiveProfileWithGeofence_WhenComputingInUse_ThenLocationFree() throws {
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let locationId = UUID()
    let profile = try makeProfile(locationId: locationId, in: context)

    let inUse = SavedLocationsView.locationsInUse(
      profiles: [profile],
      hasLocalActiveSession: { _ in false },
      remotelyActiveProfileIds: [])

    XCTAssertNil(inUse[locationId])
  }
}
