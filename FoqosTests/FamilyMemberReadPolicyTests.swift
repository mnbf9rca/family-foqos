import Foundation
import XCTest

@testable import FamilyFoqos

final class FamilyMemberReadPolicyTests: XCTestCase {
  func testGivenFamilyMemberRead_WhenInspectingImplementation_ThenItDoesNotCreatePolicyZone()
    throws
  {
    let source = try familyMemberSource()
    let body = try functionBody(named: "fetchFamilyMembers", in: source)

    XCTAssertFalse(body.isEmpty, "Family-member read extraction must not be empty")
    XCTAssertTrue(
      body.contains("privateDatabase.records("),
      "Family-member read extraction must include the CloudKit query"
    )
    XCTAssertFalse(
      body.contains("createPolicyZoneIfNeeded"),
      "Family-member reads must never create participant-owned private CloudKit state"
    )
  }

  func testGivenFamilyMemberWrite_WhenInspectingImplementation_ThenItCreatesPolicyZone()
    throws
  {
    let source = try familyMemberSource()
    let body = try functionBody(named: "saveFamilyMember", in: source)

    XCTAssertFalse(body.isEmpty, "Family-member write extraction must not be empty")
    XCTAssertTrue(
      body.contains("policyZoneID"),
      "Family-member write extraction must include the policy-zone write path"
    )
    XCTAssertTrue(
      body.contains("createPolicyZoneIfNeeded"),
      "Family-member writes must retain policy-zone setup"
    )
  }

  func testGivenEveryAppMode_WhenCheckingFamilyPolicyCreation_ThenOnlyChildIsDenied() {
    let fixtures: [(mode: AppMode, isAllowed: Bool)] = [
      (.individual, true),
      (.parent, true),
      (.child, false),
    ]

    for fixture in fixtures {
      XCTAssertEqual(
        AppModeManager.allowsFamilyPolicyCreation(mode: fixture.mode),
        fixture.isAllowed,
        "Unexpected family-policy creation rule for \(fixture.mode)"
      )
    }
  }

  private func functionBody(named name: String, in source: String) throws -> Substring {
    guard let signature = source.range(of: "func \(name)(") else {
      throw TestError.missingFunction(name)
    }
    guard let openingBrace = source[signature.lowerBound...].firstIndex(of: "{") else {
      throw TestError.missingFunctionBody(name)
    }

    var depth = 0
    var index = openingBrace
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

    throw TestError.missingFunctionBody(name)
  }

  private func familyMemberSource() throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL =
      repositoryRoot
      .appendingPathComponent("Foqos/CloudKit/CloudKitNetworkService+FamilyMembers.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }

  private enum TestError: Error {
    case missingFunction(String)
    case missingFunctionBody(String)
  }
}
