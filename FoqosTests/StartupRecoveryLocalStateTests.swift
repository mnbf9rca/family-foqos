import SQLite3
import XCTest

@testable import FamilyFoqos

final class StartupRecoveryLocalStateTests: XCTestCase {
  func testGivenEveryFreshStoreShape_WhenClassifying_ThenRecoveryCheckIsRequired() {
    for store in [
      StartupRecoveryStoreFinding.storeAbsent,
      .tableMissing,
      .profileCount(0),
    ] {
      XCTAssertEqual(
        StartupRecoveryLocalState.classify(
          StartupRecoveryLocalSnapshot(
            onboardingValuePresent: false,
            appGroupStatePresent: false,
            store: store)),
        .fresh)
    }
  }

  func testGivenPersistedOnboardingOrProfiles_WhenClassifying_ThenNormalStartupIsPreserved() {
    let snapshots = [
      StartupRecoveryLocalSnapshot(
        onboardingValuePresent: true,
        appGroupStatePresent: false,
        store: .storeAbsent),
      StartupRecoveryLocalSnapshot(
        onboardingValuePresent: false,
        appGroupStatePresent: false,
        store: .profileCount(1)),
    ]

    for snapshot in snapshots {
      XCTAssertEqual(StartupRecoveryLocalState.classify(snapshot), .existing)
    }
  }

  func testGivenOnlyAppGroupState_WhenOnboardingAndProfilesAreEmpty_ThenRecoveryCheckIsRequired() {
    XCTAssertEqual(
      StartupRecoveryLocalState.classify(
        StartupRecoveryLocalSnapshot(
          onboardingValuePresent: false,
          appGroupStatePresent: true,
          store: .profileCount(0))),
      .fresh)
  }

  func testGivenUnreadableStore_WhenClassifying_ThenFreshStateIsNotAssumed() {
    XCTAssertEqual(
      StartupRecoveryLocalState.classify(
        StartupRecoveryLocalSnapshot(
          onboardingValuePresent: false,
          appGroupStatePresent: false,
          store: .readFailed)),
      .indeterminate)
  }

  func testGivenCurrentOnboardingKey_WhenCapturing_ThenOnboardingSentinelIsPresent() {
    let snapshot = capture { key in
      key == StartupRecoveryLocalState.currentOnboardingKey ? true : nil
    }

    XCTAssertTrue(snapshot.onboardingValuePresent)
  }

  func testGivenLegacyOnboardingKey_WhenCapturingBeforeMigration_ThenOnboardingSentinelIsPresent() {
    let snapshot = capture { key in
      key == StartupRecoveryLocalState.legacyOnboardingKey ? true : nil
    }

    XCTAssertTrue(snapshot.onboardingValuePresent)
  }

  func testGivenAnyAppGroupValue_WhenCapturing_ThenAppGroupSentinelIsPresent() {
    let snapshot = StartupRecoveryLocalState.capture(
      storeURL: URL(fileURLWithPath: "/missing/default.store"),
      preferenceValue: { _, _ in nil },
      appGroupValues: { _ in ["family_foqos_device_sync_enabled": false] },
      fileExists: { _ in false },
      readStore: { _ in
        XCTFail("Missing store must not be opened")
        return .readFailed
      })

    XCTAssertTrue(snapshot.appGroupStatePresent)
  }

  func testGivenMissingStore_WhenCapturing_ThenSQLiteIsNeverOpened() {
    var readCount = 0

    let snapshot = StartupRecoveryLocalState.capture(
      storeURL: URL(fileURLWithPath: "/missing/default.store"),
      preferenceValue: { _, _ in nil },
      appGroupValues: { _ in [:] },
      fileExists: { _ in false },
      readStore: { _ in
        readCount += 1
        return .readFailed
      })

    XCTAssertEqual(snapshot.store, .storeAbsent)
    XCTAssertEqual(readCount, 0)
  }

  func testGivenTemporaryModelConfiguration_WhenConstructed_ThenStoreIsNotCreated() {
    let storeURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("StartupRecoveryLocalStateTests-\(UUID().uuidString).store")

    _ = AppModelStore.makeConfiguration(url: storeURL)

    XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
  }

  func testGivenSQLiteWithoutProfileTable_WhenReading_ThenTableMissingIsDistinct() throws {
    let storeURL = try makeSQLiteStore(sql: "CREATE TABLE OTHER (VALUE INTEGER)")
    defer { try? FileManager.default.removeItem(at: storeURL) }

    XCTAssertEqual(StartupRecoveryLocalState.readStore(at: storeURL), .tableMissing)
  }

  func testGivenSQLiteProfileRows_WhenReading_ThenLiteralCountIsReturned() throws {
    let storeURL = try makeSQLiteStore(
      sql: "CREATE TABLE ZBLOCKEDPROFILES (Z_PK INTEGER); INSERT INTO ZBLOCKEDPROFILES VALUES (1); INSERT INTO ZBLOCKEDPROFILES VALUES (2)")
    defer { try? FileManager.default.removeItem(at: storeURL) }

    XCTAssertEqual(StartupRecoveryLocalState.readStore(at: storeURL), .profileCount(2))
  }

  private func capture(
    preferenceForKey: @escaping (String) -> Any?
  ) -> StartupRecoveryLocalSnapshot {
    StartupRecoveryLocalState.capture(
      storeURL: URL(fileURLWithPath: "/missing/default.store"),
      preferenceValue: { key, _ in preferenceForKey(key) },
      appGroupValues: { _ in [:] },
      fileExists: { _ in false },
      readStore: { _ in
        XCTFail("Missing store must not be opened")
        return .readFailed
      })
  }

  private func makeSQLiteStore(sql: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("StartupRecoveryLocalStateTests-\(UUID().uuidString).sqlite")
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
    guard let database else {
      throw NSError(domain: "StartupRecoveryLocalStateTests", code: 1)
    }
    defer { sqlite3_close(database) }
    XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    return url
  }
}
