import CloudKit
import CryptoKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SavedTagTests: XCTestCase {
  func testFindOrCreateDeduplicatesWithoutRenaming() throws {
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let first = try SavedTag.findOrCreate(id: "hardware-id", kind: "nfc", name: "Kitchen", in: context)
    try context.save()
    let second = try SavedTag.findOrCreate(id: "hardware-id", kind: "nfc", name: "Spare", in: context)
    XCTAssertEqual(first.id, "hardware-id")
    XCTAssertEqual(first.kind, "nfc")
    XCTAssertTrue(first === second)
    XCTAssertEqual(second.name, "Kitchen")
    XCTAssertEqual(try SavedTag.fetchAll(in: context).count, 1)
    XCTAssertTrue(first.recordName.hasPrefix("SavedTag_"))
    XCTAssertFalse(first.recordName.contains(first.id))
    XCTAssertTrue(try SavedTag.find(byRecordName: first.recordName, in: context) === first)
    XCTAssertFalse(SyncDiagnostics.recordNames([CKRecord.ID(recordName: first.recordName)]).contains(first.id))
  }

  func testAssignmentsCountEachProfileOnceAcrossRoles() throws {
    let container = try TestModelContainer.create()
    let profiles = (1...4).map { BlockedProfiles(name: "Profile \($0)") }
    for profile in profiles { container.mainContext.insert(profile) }
    try container.mainContext.save()
    for profile in profiles.prefix(3) {
      profile.startNFCTagIds = ["shared"]
      profile.stopNFCTagIds = ["shared"]
    }
    profiles[3].startQRCodeIds = ["other"]
    let assignments = SavedTag.assignments(profiles: profiles)
    XCTAssertEqual(Set(assignments["shared"] ?? []), Set(["Profile 1", "Profile 2", "Profile 3"]))
    XCTAssertEqual(assignments["shared"]?.count, 3)
    XCTAssertEqual(assignments["other"], ["Profile 4"])
    XCTAssertNil(assignments["unused"])
  }

  func testMigrationPersistsAllListsAndClearsLegacyFields() throws {
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Homework")
    profile.profileSchemaVersion = 2
    profile.startNFCTagId = "start-nfc"
    profile.startQRCodeId = "start-qr"
    profile.stopNFCTagId = "stop-nfc"
    profile.stopQRCodeId = "stop-qr"
    profile.physicalUnblockNFCTagId = "legacy-nfc"
    profile.physicalUnblockQRCodeId = "legacy-qr"
    context.insert(profile)
    try context.save()
    let created = try profile.migrateIfEligible(hasActiveSession: true)
    XCTAssertEqual(Set(created), Set(["start-nfc", "start-qr", "stop-nfc", "stop-qr"]))
    XCTAssertEqual(profile.profileSchemaVersion, 3)
    XCTAssertEqual(profile.startNFCTagIds, ["start-nfc"])
    XCTAssertEqual(profile.startQRCodeIds, ["start-qr"])
    XCTAssertEqual(profile.stopNFCTagIds, ["stop-nfc"])
    XCTAssertEqual(profile.stopQRCodeIds, ["stop-qr"])
    XCTAssertNil(profile.startNFCTagId)
    XCTAssertNil(profile.startQRCodeId)
    XCTAssertNil(profile.stopNFCTagId)
    XCTAssertNil(profile.stopQRCodeId)
    XCTAssertNil(profile.physicalUnblockNFCTagId)
    XCTAssertNil(profile.physicalUnblockQRCodeId)
    let tags = try SavedTag.fetchAll(in: context)
    XCTAssertEqual(Set(tags.map(\.name)), Set(["Homework start tag", "Homework start code", "Homework stop tag", "Homework stop code"]))
    XCTAssertEqual(tags.filter { $0.kind == "nfc" }.count, 2)
    let reloaded = try XCTUnwrap(BlockedProfiles.findProfile(byID: profile.id, in: ModelContext(container)))
    XCTAssertEqual(reloaded.profileSchemaVersion, 3)
    XCTAssertEqual(reloaded.stopNFCTagIds, ["stop-nfc"])
    XCTAssertTrue(try profile.migrateIfEligible(hasActiveSession: false).isEmpty)
    let second = BlockedProfiles(name: "Bedtime")
    second.profileSchemaVersion = 2
    second.stopNFCTagId = "stop-nfc"
    context.insert(second)
    try context.save()
    XCTAssertTrue(try second.migrateIfEligible(hasActiveSession: false).isEmpty)
    XCTAssertEqual(second.stopNFCTagIds, ["stop-nfc"])
    XCTAssertEqual(try SavedTag.fetchAll(in: context).count, 4)
  }

  func testDetachedV2MigrationRetriesLater() throws {
    let profile = BlockedProfiles(name: "Detached")
    profile.profileSchemaVersion = 2
    profile.stopNFCTagId = "tag"
    XCTAssertTrue(try profile.migrateIfEligible(hasActiveSession: false).isEmpty)
    XCTAssertEqual(profile.profileSchemaVersion, 2)
    XCTAssertEqual(profile.stopNFCTagId, "tag")
  }
  func testV1MigrationDefersOnlyActiveSessionAndHashesLegacyQR() throws {
    let container = try TestModelContainer.create()
    let context = container.mainContext
    for kind in ["nfc", "qr"] {
      let profile = BlockedProfiles(name: "Legacy")
      profile.profileSchemaVersion = 1
      if kind == "nfc" { profile.physicalUnblockNFCTagId = "tag" } else { profile.physicalUnblockQRCodeId = "abc" }
      context.insert(profile)
      try context.save()
      XCTAssertTrue(try profile.migrateIfEligible(hasActiveSession: true).isEmpty)
      XCTAssertEqual(profile.profileSchemaVersion, 1)
      let expected = kind == "nfc" ? "tag" : "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
      XCTAssertEqual(try profile.migrateIfEligible(hasActiveSession: false), [expected])
      XCTAssertEqual(profile.profileSchemaVersion, 3)
      if kind == "nfc" {
        XCTAssertTrue(profile.stopConditions.specificNFC)
        XCTAssertEqual(profile.stopNFCTagIds, [expected])
      } else {
        XCTAssertTrue(profile.stopConditions.specificQR)
        XCTAssertEqual(profile.stopQRCodeIds, [expected])
      }
    }
  }

  func testMigrationFailureRollsBackProfileAndTagsAndEnqueuesNothing() throws {
    let now = Date()
    let schema = AppModelStore.schema
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("tags.store")
    let id = UUID()
    do {
      let writable = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
      let context = ModelContext(writable)
      let profile = BlockedProfiles(id: id, name: "Legacy", createdAt: now, updatedAt: now)
      profile.profileSchemaVersion = 2
      profile.stopNFCTagId = "tag"
      context.insert(profile)
      try context.save()
    }
    let manager = ProfileSyncManager.shared
    let previousController = manager.engineController
    let wasEnabled = manager.isEnabled
    let spy = MockSyncEngineControlling()
    manager.engineController = spy
    manager.isEnabled = true
    defer {
      manager.engineController = previousController
      manager.isEnabled = wasEnabled
    }
    do {
      let readOnly = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none)])
      let context = readOnly.mainContext
      let profile = try XCTUnwrap(BlockedProfiles.findProfile(byID: id, in: context))
      for _ in 0..<2 {
        XCTAssertThrowsError(try ProfileMigrationUtil.migrate(profile, hasActiveSession: false))
        XCTAssertEqual(profile.profileSchemaVersion, 2)
        XCTAssertEqual(profile.stopNFCTagId, "tag")
        XCTAssertTrue(profile.stopNFCTagIds.isEmpty)
        XCTAssertTrue(try SavedTag.fetchAll(in: context).isEmpty)
      }
      XCTAssertTrue(spy.enqueuedProfileSaves.isEmpty)
      XCTAssertTrue(spy.enqueuedTagSaves.isEmpty)
    }
    let writable = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
    let profile = try XCTUnwrap(BlockedProfiles.findProfile(byID: id, in: writable.mainContext))
    XCTAssertTrue(try ProfileMigrationUtil.migrate(profile, hasActiveSession: false))
    XCTAssertEqual(profile.profileSchemaVersion, 3)
    XCTAssertEqual(spy.enqueuedProfileSaves, [id])
    XCTAssertEqual(spy.enqueuedTagSaves, ["tag"])
    XCTAssertFalse(try ProfileMigrationUtil.migrate(profile, hasActiveSession: false))
    XCTAssertEqual(spy.enqueuedProfileSaves.count, 1)
    XCTAssertEqual(spy.enqueuedTagSaves.count, 1)
  }

  func testFailedV1MigrationRestoresRawDataAndPreservesReusedTagAndDetachedProfiles() throws {
    let now = Date()
    let schema = AppModelStore.schema
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("legacy.store")
    let id = UUID()
    let originalStart = ProfileStartTriggers(manual: true)
    let originalStop = ProfileStopConditions(timer: true)
    let originalSchedule = ProfileScheduleTime(days: [.tuesday], hour: 11, minute: 15, updatedAt: now)
    do {
      let writable = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
      let context = writable.mainContext
      let profile = BlockedProfiles(id: id, name: "Legacy", createdAt: now, updatedAt: now)
      profile.profileSchemaVersion = 1
      profile.startNFCTagId = "reused"
      profile.physicalUnblockNFCTagId = "new-stop"
      profile.startTriggers = originalStart
      profile.stopConditions = originalStop
      profile.startSchedule = originalSchedule
      profile.stopSchedule = originalSchedule
      profile.schedule = BlockedProfileSchedule(days: [.monday], startHour: 9, startMinute: 0, endHour: 17, endMinute: 0, updatedAt: now)
      context.insert(profile)
      context.insert(SavedTag(id: "reused", kind: "nfc", name: "Keep this name", createdAt: now, updatedAt: now))
      try context.save()
    }
    let readOnly = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none)])
    let context = readOnly.mainContext
    let profile = try XCTUnwrap(BlockedProfiles.findProfile(byID: id, in: context))
    let reused = try XCTUnwrap(SavedTag.find(byID: "reused", in: context))
    XCTAssertThrowsError(try profile.migrateIfEligible(hasActiveSession: false))
    XCTAssertEqual(profile.profileSchemaVersion, 1)
    XCTAssertEqual(profile.startNFCTagId, "reused")
    XCTAssertEqual(profile.physicalUnblockNFCTagId, "new-stop")
    XCTAssertEqual(profile.startTriggers, originalStart)
    XCTAssertEqual(profile.stopConditions, originalStop)
    XCTAssertEqual(profile.startSchedule, originalSchedule)
    XCTAssertEqual(profile.stopSchedule, originalSchedule)
    XCTAssertTrue(profile.startNFCTagIds.isEmpty)
    XCTAssertTrue(profile.stopNFCTagIds.isEmpty)
    XCTAssertEqual(try SavedTag.fetchAll(in: context).map(\.id), ["reused"])
    XCTAssertTrue(try SavedTag.find(byID: "reused", in: context) === reused)
    XCTAssertEqual(reused.name, "Keep this name")

    let inserted = BlockedProfiles(name: "Incoming", createdAt: now, updatedAt: now)
    inserted.profileSchemaVersion = 2
    inserted.stopNFCTagId = "incoming-tag"
    let insertedID = inserted.id
    context.insert(inserted)
    XCTAssertThrowsError(try inserted.migrateIfEligible(hasActiveSession: false))
    XCTAssertNil(try SavedTag.find(byID: "incoming-tag", in: context))
    XCTAssertNil(try BlockedProfiles.findProfile(byID: insertedID, in: ModelContext(readOnly)))
    if inserted.isPersistentModelValid {
      XCTAssertEqual(inserted.profileSchemaVersion, 2)
      XCTAssertEqual(inserted.stopNFCTagId, "incoming-tag")
    } else {
      XCTAssertNil(context.registeredModel(for: inserted.persistentModelID) as BlockedProfiles?)
    }
  }

  func testProfileUpdateMigratesLegacyReferencesAndCannotReintroduceThemAtV3() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Legacy", createdAt: now, updatedAt: now)
    profile.profileSchemaVersion = 2
    profile.stopNFCTagId = "tag"
    context.insert(profile)
    try context.save()
    _ = try BlockedProfiles.updateProfile(profile, in: context, now: now, name: "Renamed")
    XCTAssertEqual(profile.profileSchemaVersion, 3)
    XCTAssertEqual(profile.stopNFCTagIds, ["tag"])
    XCTAssertNotNil(try SavedTag.find(byID: "tag", in: context))
    _ = try BlockedProfiles.updateProfile(
      profile, in: context, now: now,
      physicalUnblockNFCTagId: "stale-nfc", physicalUnblockQRCodeId: "stale-qr")
    XCTAssertNil(profile.physicalUnblockNFCTagId)
    XCTAssertNil(profile.physicalUnblockQRCodeId)
  }

  func testRecordNamesKeepHashingExactStoredIdentifiers() {
    for id in ["04ABCD1234", " HTTPS://EXAMPLE.COM/ ", "f7bab0e3b417cf24e9a77e97a53fc4cea1084e20398a2e7258281e80239ca6f1"] {
      let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
      XCTAssertEqual(SavedTag.recordName(for: id), "SavedTag_" + digest)
    }
  }

}
