import CoreFoundation
import Foundation
import SQLite3

enum StartupRecoveryStoreFinding: Equatable {
  case storeAbsent
  case tableMissing
  case profileCount(Int)
  case readFailed
}

struct StartupRecoveryLocalSnapshot: Equatable {
  let onboardingValuePresent: Bool
  let appGroupStatePresent: Bool
  let store: StartupRecoveryStoreFinding
}

enum StartupRecoveryLocalClassification: Equatable {
  case existing
  case fresh
  case indeterminate
}

enum StartupRecoveryLocalState {
  static let currentOnboardingKey = "family_foqos_has_completed_onboarding"
  static let legacyOnboardingKey = "hasCompletedOnboarding"

  static var standardDomain: String {
    Bundle.main.bundleIdentifier ?? ""
  }

  static var appGroupDomain: String {
    Log.appGroupIdentifier
  }

  static func classify(
    _ snapshot: StartupRecoveryLocalSnapshot
  ) -> StartupRecoveryLocalClassification {
    if snapshot.onboardingValuePresent {
      return .existing
    }

    switch snapshot.store {
    case .storeAbsent, .tableMissing, .profileCount(0):
      return .fresh
    case .profileCount:
      return .existing
    case .readFailed:
      return .indeterminate
    }
  }

  static func capture() -> StartupRecoveryLocalSnapshot {
    capture(
      storeURL: AppModelStore.storeURL,
      preferenceValue: { key, domain in
        CFPreferencesCopyAppValue(key as CFString, domain as CFString)
      },
      appGroupValues: { domain in
        CFPreferencesCopyMultiple(
          nil,
          domain as CFString,
          kCFPreferencesCurrentUser,
          kCFPreferencesAnyHost) as? [String: Any]
      },
      fileExists: { FileManager.default.fileExists(atPath: $0) },
      readStore: readStore)
  }

  static func capture(
    storeURL: URL,
    preferenceValue: (_ key: String, _ domain: String) -> Any?,
    appGroupValues: (_ domain: String) -> [String: Any]?,
    fileExists: (_ path: String) -> Bool,
    readStore: (_ storeURL: URL) -> StartupRecoveryStoreFinding
  ) -> StartupRecoveryLocalSnapshot {
    let onboardingValuePresent =
      preferenceValue(currentOnboardingKey, standardDomain) != nil
      || preferenceValue(legacyOnboardingKey, standardDomain) != nil
    let appGroupStatePresent = !(appGroupValues(appGroupDomain) ?? [:]).isEmpty
    let store = fileExists(storeURL.path) ? readStore(storeURL) : .storeAbsent

    return StartupRecoveryLocalSnapshot(
      onboardingValuePresent: onboardingValuePresent,
      appGroupStatePresent: appGroupStatePresent,
      store: store)
  }

  static func readStore(at storeURL: URL) -> StartupRecoveryStoreFinding {
    let uri = storeURL.absoluteString + "?mode=ro"
    var database: OpaquePointer?
    let openCode = sqlite3_open_v2(
      uri,
      &database,
      SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
      nil)
    guard openCode == SQLITE_OK, let database else {
      if let database {
        sqlite3_close(database)
      }
      return .readFailed
    }
    defer { sqlite3_close(database) }

    guard sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else {
      return .readFailed
    }
    guard profileTableExists(in: database) else {
      return .tableMissing
    }

    var statement: OpaquePointer?
    let prepareCode = sqlite3_prepare_v2(
      database,
      "SELECT COUNT(*) FROM ZBLOCKEDPROFILES",
      -1,
      &statement,
      nil)
    guard prepareCode == SQLITE_OK, let statement else {
      if let statement {
        sqlite3_finalize(statement)
      }
      return .readFailed
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let count = Int(exactly: sqlite3_column_int64(statement, 0))
    else {
      return .readFailed
    }
    return .profileCount(count)
  }

  private static func profileTableExists(in database: OpaquePointer) -> Bool {
    var statement: OpaquePointer?
    let prepareCode = sqlite3_prepare_v2(
      database,
      "SELECT 1 FROM sqlite_master WHERE type='table' AND name='ZBLOCKEDPROFILES' LIMIT 1",
      -1,
      &statement,
      nil)
    guard prepareCode == SQLITE_OK, let statement else {
      if let statement {
        sqlite3_finalize(statement)
      }
      return false
    }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_ROW
  }
}
