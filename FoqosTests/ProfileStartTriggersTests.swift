// FoqosTests/ProfileStartTriggersTests.swift
import CloudKit
import XCTest

@testable import FamilyFoqos

final class ProfileStartTriggersTests: XCTestCase {

  func testGivenNewTriggers_WhenCheckingDefaults_ThenAllFalse() {
    let triggers = ProfileStartTriggers()
    XCTAssertFalse(triggers.manual)
    XCTAssertFalse(triggers.anyNFC)
    XCTAssertFalse(triggers.specificNFC)
    XCTAssertFalse(triggers.anyQR)
    XCTAssertFalse(triggers.specificQR)
    XCTAssertFalse(triggers.schedule)
    XCTAssertFalse(triggers.deepLink)
  }

  func testGivenAnyNFCTrue_WhenCheckingHasNFC_ThenReturnsTrue() {
    var triggers = ProfileStartTriggers()
    triggers.anyNFC = true
    XCTAssertTrue(triggers.hasNFC)
  }

  func testGivenSpecificNFCTrue_WhenCheckingHasNFC_ThenReturnsTrue() {
    var triggers = ProfileStartTriggers()
    triggers.specificNFC = true
    XCTAssertTrue(triggers.hasNFC)
  }

  func testGivenAnyQRTrue_WhenCheckingHasQR_ThenReturnsTrue() {
    var triggers = ProfileStartTriggers()
    triggers.anyQR = true
    XCTAssertTrue(triggers.hasQR)
  }

  func testGivenSpecificQRTrue_WhenCheckingHasQR_ThenReturnsTrue() {
    var triggers = ProfileStartTriggers()
    triggers.specificQR = true
    XCTAssertTrue(triggers.hasQR)
  }

  func testGivenNoTriggersSet_WhenCheckingIsValid_ThenReturnsFalse() {
    let triggers = ProfileStartTriggers()
    XCTAssertFalse(triggers.isValid)
  }

  func testGivenManualTriggerSet_WhenCheckingIsValid_ThenReturnsTrue() {
    var triggers = ProfileStartTriggers()
    triggers.manual = true
    XCTAssertTrue(triggers.isValid)
  }

  func testGivenTriggersWithValues_WhenEncodingAndDecoding_ThenRoundTrips() throws {
    var original = ProfileStartTriggers()
    original.manual = true
    original.anyNFC = true
    original.schedule = true

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ProfileStartTriggers.self, from: data)

    XCTAssertEqual(original, decoded)
  }
  func testLegacyV3TriggerBlobPreservesFlagsAndWritesManualDerivedPermission() throws {
    for manual in [false, true] {
      let blob = Data("{\"manual\":\(manual),\"anyNFC\":true,\"specificNFC\":true,\"anyQR\":true,\"specificQR\":true,\"schedule\":true,\"deepLink\":true}".utf8)
      let triggers = try JSONDecoder().decode(ProfileStartTriggers.self, from: blob)
      XCTAssertEqual(triggers.manual, manual)
      XCTAssertTrue(triggers.anyNFC && triggers.specificNFC && triggers.anyQR && triggers.specificQR && triggers.schedule && triggers.deepLink)
      let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(triggers)) as? [String: Any])
      XCTAssertEqual(encoded["shortcuts"] as? Bool, manual)
    }
  }

  func testMalformedShortcutsPermissionFailsClosed() {
    let blob = Data(#"{"manual":true,"anyNFC":false,"specificNFC":false,"anyQR":false,"specificQR":false,"schedule":false,"deepLink":false,"shortcuts":"true"}"#.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(ProfileStartTriggers.self, from: blob))
  }

  @MainActor
  func testExplicitPermissionSurvivesManualChangeCloneAndPrivateSync() throws {
    let container = try TestModelContainer.create()
    let profile = BlockedProfiles(name: "Explicit")
    profile.startTriggers = ProfileStartTriggers(manual: false, shortcuts: false)
    profile.startTriggers.manual = true
    container.mainContext.insert(profile)
    try container.mainContext.save()
    let cloned = try BlockedProfiles.cloneProfile(profile, in: container.mainContext, newName: "Clone", mode: .individual)
    XCTAssertFalse(cloned.startTriggers.shortcuts)
    let record = SyncedProfile(from: profile, originDeviceId: "test-device")
      .toCKRecord(in: CKRecordZone.ID(zoneName: "Test"))
    let decoded = try XCTUnwrap(SyncedProfile(from: record))
    let data = try XCTUnwrap(decoded.startTriggersData)
    let triggers = try JSONDecoder().decode(ProfileStartTriggers.self, from: data)
    XCTAssertTrue(triggers.manual)
    XCTAssertFalse(triggers.shortcuts)
    XCTAssertFalse(ProfileStartTriggers().shortcuts)
    for strategy in ["ManualBlockingStrategy", "NFCBlockingStrategy", "QRTimerBlockingStrategy"] {
      let (start, _) = TriggerMigration.migrateFromStrategy(strategy)
      XCTAssertEqual(start.shortcuts, start.manual)
    }
  }

}
