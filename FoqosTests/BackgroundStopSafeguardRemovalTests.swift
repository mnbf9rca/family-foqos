import CloudKit
import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class BackgroundStopSafeguardRemovalTests: XCTestCase {
  func testOutgoingWireAndNewSnapshotsNeutralizeOnlyV2Flag() throws {
    let now = Date()
    let zone = CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
    for version in [1, 2, 3] {
      let profile = BlockedProfiles(name: "Stored", createdAt: now, updatedAt: now)
      profile.profileSchemaVersion = version
      profile.disableBackgroundStops = true
      profile.stopConditions = .init(manual: true, timer: true, timerDurationMinutes: 37)
      let snapshot = BlockedProfiles.getSnapshot(for: profile)
      XCTAssertEqual(snapshot.disableBackgroundStops, version < 2)
      XCTAssertEqual(snapshot.stopConditions, profile.stopConditions)
      var wire = SyncedProfile(from: profile, originDeviceId: "local")
      XCTAssertEqual(wire.disableBackgroundStops, version < 2)
      wire.disableBackgroundStops = true
      let record = wire.toCKRecord(in: zone)
      XCTAssertEqual(record[SyncedProfile.FieldKey.disableBackgroundStops.rawValue] as? Bool, version < 2)
      // A previously written record still contains true on the server.
      record[SyncedProfile.FieldKey.disableBackgroundStops.rawValue] = true
      let decoded = try XCTUnwrap(SyncedProfile(from: record))
      XCTAssertEqual(decoded.disableBackgroundStops, version < 2)
      XCTAssertEqual(decoded.stopConditions, profile.stopConditions)
      var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
      oldJSON["disableBackgroundStops"] = true
      if version == 1 { oldJSON.removeValue(forKey: "profileSchemaVersion") }
      let oldSnapshot = try JSONDecoder().decode(SharedData.ProfileSnapshot.self, from: JSONSerialization.data(withJSONObject: oldJSON))
      XCTAssertEqual(oldSnapshot.disableBackgroundStops, true)
      XCTAssertEqual(oldSnapshot.stopConditions, profile.stopConditions)
    }
  }

  func testOldFlagEqualityCannotHideRealStopOrUnrelatedChanges() throws {
    let now = Date()
    let source = BlockedProfiles(name: "Stored", createdAt: now, updatedAt: now)
    source.startTriggers = .init(manual: true)
    source.stopConditions = .init(manual: true, timer: true, schedule: true, nfc: .specific, timerDurationMinutes: 37)
    source.stopNFCTagIds = ["A0FF"]
    source.stopSchedule = .init(days: Weekday.allCases, hour: 17, minute: 0, updatedAt: now)
    for version in [1, 3] {
      source.profileSchemaVersion = version
      let base = SyncedProfile(from: source, originDeviceId: "local")
      var oldFlagOnly = base
      oldFlagOnly.disableBackgroundStops = !base.disableBackgroundStops
      XCTAssertEqual(SyncPayloadEquality.profilesPayloadEqual(base, oldFlagOnly), version >= 2)
      for conditions in [
        ProfileStopConditions(manual: false, timer: true, schedule: true, nfc: .specific, timerDurationMinutes: 37),
        ProfileStopConditions(manual: true, timer: true, schedule: false, nfc: .specific, timerDurationMinutes: 37),
        ProfileStopConditions(manual: true, timer: true, schedule: true, nfc: .any, timerDurationMinutes: 37),
        ProfileStopConditions(manual: true, timer: true, schedule: true, nfc: .specific, timerDurationMinutes: 45),
      ] {
        var changed = oldFlagOnly
        changed.stopConditionsData = try JSONEncoder().encode(conditions)
        XCTAssertFalse(SyncPayloadEquality.profilesPayloadEqual(base, changed))
      }
      var changed = oldFlagOnly
      changed.name = "Changed"
      XCTAssertFalse(SyncPayloadEquality.profilesPayloadEqual(base, changed))
      changed = oldFlagOnly
      changed.stopNFCTagIds = ["OTHER"]
      XCTAssertFalse(SyncPayloadEquality.profilesPayloadEqual(base, changed))
    }
  }

  func testEditorSaveAndCloneKeepStopsWithoutCopyingSafeguard() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let config = TriggerConfigurationModel()
    config.startTriggers = .init(manual: true)
    config.stopConditions = .init(manual: true, timer: true, timerDurationMinutes: 37)
    let source = try BlockedProfiles.createProfile(in: context, name: "Stored", triggerConfiguration: config)
    source.disableBackgroundStops = true
    try context.save()
    let saved = try BlockedProfiles.updateProfile(source, in: context, now: now, name: "Reopened", triggerConfiguration: config)
    XCTAssertEqual(saved.stopConditions, config.stopConditions)
    XCTAssertEqual(saved.startTriggers, config.startTriggers)
    // No data rewrite is needed: a retained column may remain true locally.
    XCTAssertTrue(saved.disableBackgroundStops)
    XCTAssertEqual(BlockedProfiles.getSnapshot(for: saved).disableBackgroundStops, false)
    let clone = try BlockedProfiles.cloneProfile(saved, in: context, newName: "Copy", mode: .individual)
    XCTAssertFalse(clone.disableBackgroundStops)
    XCTAssertEqual(clone.stopConditions, config.stopConditions)
    XCTAssertEqual(clone.startTriggers, config.startTriggers)
    XCTAssertEqual(BlockedProfiles.getSnapshot(for: clone).disableBackgroundStops, false)
  }
}
