// FoqosTests/BlockedProfilesMigrationTests.swift
import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class BlockedProfilesMigrationTests: XCTestCase {

  func testGivenV1Profile_WhenMigrating_ThenSetsSchemaVersionToV2() {
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = "ManualBlockingStrategy"

    profile.migrateToV2IfNeeded()

    XCTAssertEqual(profile.profileSchemaVersion, 2)
  }

  func testGivenV1NFCProfile_WhenMigrating_ThenSetsNFCTriggers() {
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = "NFCBlockingStrategy"

    profile.migrateToV2IfNeeded()

    XCTAssertTrue(profile.startTriggers.anyNFC)
    XCTAssertTrue(profile.stopConditions.sameNFC)
  }

  func testGivenV1PhysicalUnlockProfile_WhenMigrating_ThenSetsSpecificNFCStop() {
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = "NFCManualBlockingStrategy"
    profile.physicalUnblockNFCTagId = "tag-123"

    profile.migrateToV2IfNeeded()

    XCTAssertTrue(profile.stopConditions.specificNFC)
    XCTAssertFalse(profile.stopConditions.anyNFC)
    XCTAssertEqual(profile.stopNFCTagId, "tag-123")
  }

  func testGivenV1ScheduledProfile_WhenMigrating_ThenSetsStartAndStopSchedules() {
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = "ManualBlockingStrategy"
    profile.schedule = BlockedProfileSchedule(
      days: [.monday],
      startHour: 9,
      startMinute: 0,
      endHour: 17,
      endMinute: 0,
      updatedAt: Date()
    )

    profile.migrateToV2IfNeeded()

    XCTAssertEqual(profile.startSchedule?.hour, 9)
    XCTAssertEqual(profile.stopSchedule?.hour, 17)
  }

  func testGivenV2Profile_WhenMigrating_ThenDoesNothing() {
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = 2
    var triggers = profile.startTriggers
    triggers.manual = true
    profile.startTriggers = triggers

    profile.migrateToV2IfNeeded()

    // Should remain unchanged
    XCTAssertEqual(profile.profileSchemaVersion, 2)
    XCTAssertTrue(profile.startTriggers.manual)
  }

  func testGivenV1Profile_WhenCheckingNeedsMigration_ThenReturnsTrue() {
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = 1
    XCTAssertTrue(profile.needsMigration)
  }

  func testGivenV3Profile_WhenCheckingNeedsMigration_ThenReturnsFalse() {
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = 3
    XCTAssertFalse(profile.needsMigration)
  }

  func testGivenActiveSession_WhenMigrating_ThenSkipsProfile() throws {
    let profile = BlockedProfiles(name: "Active")
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = "ManualBlockingStrategy"

    let migrated = try profile.migrateIfEligible(hasActiveSession: true)

    XCTAssertTrue(migrated.isEmpty)
    XCTAssertEqual(profile.profileSchemaVersion, 1)  // Still V1
  }

  func testGivenV1ScheduledProfile_WhenMigrating_ThenSetsTriggerFlags() {
    let profile = BlockedProfiles(name: "Scheduled")
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = "ManualBlockingStrategy"
    profile.schedule = BlockedProfileSchedule(
      days: [.monday, .friday],
      startHour: 9, startMinute: 0,
      endHour: 17, endMinute: 0,
      updatedAt: Date()
    )

    profile.migrateToV2IfNeeded()

    XCTAssertTrue(profile.startTriggers.schedule, "Start triggers should have schedule enabled")
    XCTAssertTrue(profile.stopConditions.schedule, "Stop conditions should have schedule enabled")
    XCTAssertEqual(profile.startSchedule?.hour, 9)
    XCTAssertEqual(profile.stopSchedule?.hour, 17)
  }

  func testGivenCurrentSchemaVersion_WhenCheckingIsNewer_ThenReturnsFalse() {
    let profile = BlockedProfiles(name: "Current")
    profile.profileSchemaVersion = 2
    XCTAssertFalse(profile.isNewerSchemaVersion)
  }

  func testGivenOlderSchemaVersion_WhenCheckingIsNewer_ThenReturnsFalse() {
    let profile = BlockedProfiles(name: "Old")
    profile.profileSchemaVersion = 1
    XCTAssertFalse(profile.isNewerSchemaVersion)
  }

  func testGivenFutureSchemaVersion_WhenCheckingIsNewer_ThenReturnsTrue() {
    let profile = BlockedProfiles(name: "Future")
    profile.profileSchemaVersion = 4
    XCTAssertTrue(profile.isNewerSchemaVersion)
  }

  func testGivenSchemaVersionConstant_WhenCheckingIsNewer_ThenUsesCurrentSchemaVersion() {
    // Verify the threshold is based on currentSchemaVersion, not a hardcoded value
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = BlockedProfiles.currentSchemaVersion
    XCTAssertFalse(profile.isNewerSchemaVersion, "Current version should not be 'newer'")

    profile.profileSchemaVersion = BlockedProfiles.currentSchemaVersion + 1
    XCTAssertTrue(profile.isNewerSchemaVersion, "Version above current should be 'newer'")
  }

  func testGivenNoActiveSession_WhenMigrating_ThenMigratesSuccessfully() throws {
    let container = try TestModelContainer.create()
    let profile = BlockedProfiles(name: "Inactive")
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = "ManualBlockingStrategy"

    container.mainContext.insert(profile)
    try container.mainContext.save()
    _ = try profile.migrateIfEligible(hasActiveSession: false)
    XCTAssertEqual(profile.profileSchemaVersion, 3)
  }
  func testConversionMatrixPreservesEntrances() throws {
    let now = Date()
    let rows: [(String?, ProfileStartTriggers, ProfileStopConditions, Bool)] = [
      ("ManualBlockingStrategy", .init(manual: true, deepLink: true, shortcuts: true), .init(manual: true), false),
      ("NFCBlockingStrategy", .init(anyNFC: true), .init(nfc: .same), false),
      ("NFCManualBlockingStrategy", .init(manual: true, deepLink: true, shortcuts: true), .init(nfc: .any), false),
      ("NFCTimerBlockingStrategy", .init(manual: true, deepLink: true, shortcuts: true), .init(timer: true, nfc: .any, timerDurationMinutes: 37), false),
      ("QRCodeBlockingStrategy", .init(anyQR: true), .init(qr: .same), false),
      ("QRManualBlockingStrategy", .init(manual: true, deepLink: true, shortcuts: true), .init(qr: .any), false),
      ("QRTimerBlockingStrategy", .init(manual: true, deepLink: true, shortcuts: true), .init(timer: true, qr: .any, timerDurationMinutes: 37), false),
      ("ShortcutTimerBlockingStrategy", .init(manual: true, deepLink: true, shortcuts: true), .init(timer: true, timerDurationMinutes: 37), false),
      ("Unknown", .init(anyNFC: true), .init(nfc: .same), false),
      (nil, .init(deepLink: true, shortcuts: true), .init(requiresEditingAfterConversion: true), true),
    ]
    let container = try TestModelContainer.create()
    for (id, starts, stops, invalid) in rows {
      let profile = BlockedProfiles(name: "Converted", createdAt: now, updatedAt: now, strategyData: try JSONEncoder().encode(StrategyTimerData(durationInMinutes: 37)))
      profile.blockingStrategyId = id
      profile.profileSchemaVersion = 1
      container.mainContext.insert(profile)
      _ = try profile.migrateIfEligible(hasActiveSession: false)
      XCTAssertEqual(profile.profileSchemaVersion, 3)
      XCTAssertEqual(profile.startTriggers, starts, "\(id ?? "nil")")
      XCTAssertEqual(profile.stopConditions, stops, "\(id ?? "nil")")
      XCTAssertEqual(profile.hasInvalidConditionSettings, invalid, "\(id ?? "nil")")
      XCTAssertNotNil(try BlockedProfiles.findProfile(byID: profile.id, in: container.mainContext))
    }
  }

  func testV1TimerTransfersOnlyStrictValidDurations() throws {
    let now = Date()
    let fixtures: [(Data?, Int?)] =
      [
        (nil, nil), (Data("bad".utf8), nil), (Data("{}".utf8), nil),
        (Data("{\"durationInMinutes\":\"37\"}".utf8), nil),
        (Data("{\"durationInMinutes\":37.5}".utf8), nil),
      ]
      + [0, -1, 14, 15, 37, 1439, 1440].map {
        (Data("{\"durationInMinutes\":\($0)}".utf8), (15...1439).contains($0) ? $0 : nil)
      }
    for id in ["NFCTimerBlockingStrategy", "QRTimerBlockingStrategy", "ShortcutTimerBlockingStrategy"] {
      for (data, expected) in fixtures {
        let profile = BlockedProfiles(name: "Timer", createdAt: now, updatedAt: now, blockingStrategyId: id, strategyData: data)
        profile.profileSchemaVersion = 1
        profile.migrateToV2IfNeeded()
        XCTAssertTrue(profile.stopConditions.timer)
        XCTAssertEqual(profile.stopConditions.timerDurationMinutes, expected)
        XCTAssertFalse(profile.stopConditions.allowChangingTimerBeforeStart)
        XCTAssertEqual(profile.hasInvalidConditionSettings, id == "ShortcutTimerBlockingStrategy" && expected == nil)
        let roundTrip = try JSONDecoder().decode(ProfileStopConditions.self, from: JSONEncoder().encode(profile.stopConditions))
        XCTAssertEqual(roundTrip.timerDurationMinutes, expected)
        XCTAssertEqual(BlockedProfiles.getSnapshot(for: profile).stopConditions?.timerDurationMinutes, expected)
        if expected == nil { XCTAssertTrue(profile.conditionValidationErrors(forSave: true).contains("Choose a timer from 15 minutes to 23 hours 59 minutes.")) }
      }
    }
  }

  func testPhysicalAndScheduleModifiers() throws {
    let now = Date()
    let validSchedule = BlockedProfileSchedule(days: [.monday], startHour: 9, startMinute: 0, endHour: 17, endMinute: 0, updatedAt: now)
    for id: String? in ["NFCBlockingStrategy", "QRCodeBlockingStrategy", "Unknown", "ShortcutTimerBlockingStrategy", nil] {
      for modality in ["nfc", "qr", "both"] {
        let profile = BlockedProfiles(name: "Modified", createdAt: now, updatedAt: now, schedule: validSchedule)
        profile.blockingStrategyId = id
        profile.profileSchemaVersion = 1
        profile.physicalUnblockNFCTagId = modality == "qr" ? nil : "A0FF"
        profile.physicalUnblockQRCodeId = modality == "nfc" ? nil : "content"
        profile.migrateToV2IfNeeded()
        XCTAssertTrue(profile.startTriggers.schedule)
        XCTAssertTrue(profile.stopConditions.schedule)
        XCTAssertEqual(profile.startSchedule?.hour, 9)
        XCTAssertEqual(profile.stopSchedule?.hour, 17)
        if modality != "qr" {
          XCTAssertEqual(profile.stopConditions.nfc, .specific)
          XCTAssertEqual(profile.stopNFCTagId, "A0FF")
          XCTAssertNil(profile.stopQRCodeId)
        } else {
          XCTAssertEqual(profile.stopConditions.qr, .specific)
          XCTAssertEqual(profile.stopQRCodeId, QRCodeHasher.hash("content"))
        }
        XCTAssertEqual(profile.stopConditions.requiresEditingAfterConversion, id == nil)
        XCTAssertEqual(profile.hasInvalidConditionSettings, id == nil)
      }
    }
    for schedule in [
      BlockedProfileSchedule(days: [], startHour: 9, startMinute: 0, endHour: 17, endMinute: 0, updatedAt: now),
      BlockedProfileSchedule(days: [.monday], startHour: 25, startMinute: 0, endHour: 17, endMinute: 60, updatedAt: now),
    ] {
      let profile = BlockedProfiles(name: "Schedule", createdAt: now, updatedAt: now, schedule: schedule)
      profile.profileSchemaVersion = 1
      profile.migrateToV2IfNeeded()
      XCTAssertEqual(profile.startTriggers.schedule, schedule.isActive)
      XCTAssertEqual(profile.stopConditions.schedule, schedule.isActive)
      XCTAssertEqual(profile.hasInvalidConditionSettings, schedule.isActive)
    }
    let badKey = BlockedProfiles(name: "Bad key", createdAt: now, updatedAt: now, physicalUnblockNFCTagId: " ")
    badKey.profileSchemaVersion = 1
    badKey.migrateToV2IfNeeded()
    XCTAssertEqual(badKey.stopConditions.nfc, .specific)
    XCTAssertTrue(badKey.hasInvalidConditionSettings)
  }

}
