import XCTest

@testable import FamilyFoqos

final class StartupRecoveryOrderingTests: XCTestCase {
  func testOnlyNormalStateReleasesHomeAndSyncAttachment() {
    let heldStates: [StartupRecoveryState] = [
      .checking,
      .retryMembership(canContinueSetup: false),
      .retryMembership(canContinueSetup: true),
      .retryProfiles(role: .parent),
      .checkingProfiles(role: .child),
      .offer(role: .parent, profileCount: 2),
    ]

    for state in heldStates {
      XCTAssertFalse(StartupRecoveryStartupPolicy.isReleased(state))
    }
    XCTAssertTrue(StartupRecoveryStartupPolicy.isReleased(.normal(recheckArmed: false)))
    XCTAssertTrue(StartupRecoveryStartupPolicy.isReleased(.normal(recheckArmed: true)))
    XCTAssertTrue(StartupRecoveryStartupPolicy.isReleased(.roleRestored(role: .parent)))
  }

  func testAppSourceKeepsSnapshotBeforeStateObjectsAndCoordinatorBeforeMigration() throws {
    let source = try appSource()

    assertOrder(
      [
        "private let startupRecoverySnapshot",
        "@StateObject private var requestAuthorizer",
        "_startupRecoveryCoordinator = StateObject",
        "UserDefaultsMigration.migrateIfNeeded()",
      ],
      in: source)
  }

  func testForegroundSourceRechecksRecoveryBeforeAuthorizationVerification() throws {
    let source = try appSource()
    let foreground = try functionBody(named: "handleActiveScene", in: source)

    assertOrder(
      ["startupRecoveryCoordinator.recheckIfNeeded()", "verifyChildAuthorizationIfNeeded()"],
      in: String(foreground))
  }

  func testRoleRecoverySourcePersistsRoleAndOnboardingBeforeChildLockRefresh() throws {
    let source = try appSource()
    let restore = try functionBody(named: "restoreRecoveredFamilyRole", in: source)

    assertOrder(
      [
        "AppModeManager.shared.selectMode",
        "family_foqos_has_completed_onboarding",
        "family_foqos_show_intro_screen",
        "family_foqos_show_mode_selection",
      ],
      in: String(restore))
    XCTAssertFalse(restore.contains("refreshSharedLockCodesForVerification"))
  }

  private func assertOrder(
    _ needles: [String],
    in source: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    var cursor = source.startIndex
    for needle in needles {
      guard let range = source.range(of: needle, range: cursor..<source.endIndex) else {
        XCTFail("Missing or out-of-order source marker: \(needle)", file: file, line: line)
        return
      }
      cursor = range.upperBound
    }
  }

  private func functionBody(named name: String, in source: String) throws -> Substring {
    guard let signature = source.range(of: "func \(name)(") else {
      throw SourceError.missingFunction(name)
    }
    guard let openingBrace = source[signature.lowerBound...].firstIndex(of: "{") else {
      throw SourceError.malformedFunction(name)
    }

    var depth = 1
    var index = source.index(after: openingBrace)
    while index < source.endIndex {
      switch source[index] {
      case "{":
        depth += 1
      case "}":
        depth -= 1
        if depth == 0 {
          return source[source.index(after: openingBrace)..<index]
        }
      default:
        break
      }
      index = source.index(after: index)
    }
    throw SourceError.malformedFunction(name)
  }

  private func appSource() throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = repositoryRoot.appendingPathComponent("Foqos/FoqosApp.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }

  private enum SourceError: Error {
    case missingFunction(String)
    case malformedFunction(String)
  }
}
