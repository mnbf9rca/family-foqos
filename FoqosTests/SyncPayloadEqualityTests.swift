import XCTest

@testable import FamilyFoqos

final class SyncPayloadEqualityTests: XCTestCase {
  private func makeProfile(name: String, now: Date, originDeviceId: String, version: Int)
    -> SyncedProfile
  {
    let source = BlockedProfiles(id: UUID(), name: name, syncVersion: version)
    var synced = SyncedProfile(from: source, originDeviceId: originDeviceId)
    synced.createdAt = now
    synced.updatedAt = now
    return synced
  }

  func testGivenSameFieldsDifferentMetadata_WhenComparedProfiles_ThenPayloadEqual() {
    let now = Date()
    let id = UUID()
    let base = BlockedProfiles(id: id, name: "Focus", syncVersion: 5)
    var a = SyncedProfile(from: base, originDeviceId: "device-A")
    var b = SyncedProfile(from: base, originDeviceId: "device-B")
    a.createdAt = now
    a.updatedAt = now
    a.version = 5
    a.lastModified = now
    b.createdAt = now
    b.updatedAt = now
    b.version = 99
    b.lastModified = now.addingTimeInterval(1000)
    XCTAssertTrue(SyncPayloadEquality.profilesPayloadEqual(a, b))
  }

  func testGivenDifferentName_WhenComparedProfiles_ThenNotPayloadEqual() {
    let now = Date()
    let a = makeProfile(name: "Focus", now: now, originDeviceId: "device-A", version: 5)
    let b = makeProfile(name: "Work", now: now, originDeviceId: "device-A", version: 5)
    XCTAssertFalse(SyncPayloadEquality.profilesPayloadEqual(a, b))
  }

  func testGivenSameFieldsDifferentMetadata_WhenComparedLocations_ThenPayloadEqual() {
    let now = Date()
    let id = UUID()
    let a = SyncedLocation(
      locationId: id, name: "Home", latitude: 1, longitude: 2,
      defaultRadiusMeters: 100, isLocked: false, lastModified: now)
    let b = SyncedLocation(
      locationId: id, name: "Home", latitude: 1, longitude: 2,
      defaultRadiusMeters: 100, isLocked: false, lastModified: now.addingTimeInterval(5000))
    XCTAssertTrue(SyncPayloadEquality.locationsPayloadEqual(a, b))
  }

  func testGivenDifferentRadius_WhenComparedLocations_ThenNotPayloadEqual() {
    let now = Date()
    let id = UUID()
    let a = SyncedLocation(
      locationId: id, name: "Home", latitude: 1, longitude: 2,
      defaultRadiusMeters: 100, isLocked: false, lastModified: now)
    let b = SyncedLocation(
      locationId: id, name: "Home", latitude: 1, longitude: 2,
      defaultRadiusMeters: 250, isLocked: false, lastModified: now)
    XCTAssertFalse(SyncPayloadEquality.locationsPayloadEqual(a, b))
  }

  func testGivenSameFieldsDifferentMetadata_WhenComparedEmergency_ThenPayloadEqual() {
    let now = Date()
    let a = SyncedEmergencySettings(
      unblocksRemaining: 3, resetPeriodInDays: 28, lastResetDate: now,
      settingsLocked: false, version: 1, lastModified: now, originDeviceId: "device-A")
    let b = SyncedEmergencySettings(
      unblocksRemaining: 3, resetPeriodInDays: 28, lastResetDate: now,
      settingsLocked: false, version: 42, lastModified: now.addingTimeInterval(9),
      originDeviceId: "device-B")
    XCTAssertTrue(SyncPayloadEquality.emergencyPayloadEqual(a, b))
  }

  func testGivenByteDifferentButSemanticallyEqualTriggersData_WhenComparedProfiles_ThenPayloadEqual() {
    let now = Date()
    let triggers = ProfileStartTriggers(manual: true, anyNFC: false, schedule: true)

    // Same decoded value, different raw bytes (compact vs. pretty-printed encoding).
    let compactEncoder = JSONEncoder()
    let prettyEncoder = JSONEncoder()
    prettyEncoder.outputFormatting = .prettyPrinted
    let compactData = try! compactEncoder.encode(triggers)
    let prettyData = try! prettyEncoder.encode(triggers)
    XCTAssertNotEqual(compactData, prettyData, "test setup must exercise byte-different Data")

    let base = BlockedProfiles(id: UUID(), name: "Focus", syncVersion: 5)
    var a = SyncedProfile(from: base, originDeviceId: "device-A")
    var b = SyncedProfile(from: base, originDeviceId: "device-A")
    a.createdAt = now
    a.updatedAt = now
    b.createdAt = now
    b.updatedAt = now
    a.startTriggersData = compactData
    b.startTriggersData = prettyData

    XCTAssertEqual(a.startTriggers, triggers)
    XCTAssertEqual(b.startTriggers, triggers)
    XCTAssertTrue(SyncPayloadEquality.profilesPayloadEqual(a, b))
  }
}
