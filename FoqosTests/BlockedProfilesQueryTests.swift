import AppIntents
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class BlockedProfilesQueryTests: XCTestCase {
  func testLookupUsesCurrentNamesAndReturnsAllDuplicatesWithoutDefault() async throws {
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let first = BlockedProfiles(name: "Focus")
    let second = BlockedProfiles(name: "Focus")
    let third = BlockedProfiles(name: "Study")
    for profile in [first, second, third] { context.insert(profile) }
    try context.save()
    let query = BlockedProfilesQuery(modelContainer: container)
    let matches = try await query.entities(matching: "focus")
    XCTAssertEqual(Set(matches.map(\.id)), [first.id, second.id])
    first.name = "Reading"
    try context.save()
    let renamed = try await query.entities(for: [first.id])
    XCTAssertEqual(renamed.first?.name, "Reading")
    let remaining = try await query.entities(matching: "Focus")
    XCTAssertEqual(remaining.map(\.id), [second.id])
    let unique = try await query.entities(matching: "Study")
    XCTAssertEqual(unique.map(\.id), [third.id])
    let defaultEntity = await query.defaultResult()
    XCTAssertNil(defaultEntity)
    let deletedId = first.id
    context.delete(first)
    try context.save()
    do {
      _ = try await query.entities(for: [deletedId])
      XCTFail("Deleted UUID must fail")
    } catch { XCTAssertTrue(error is IntentError) }
    do {
      _ = try await query.entities(matching: "Missing")
      XCTFail("No match must fail")
    } catch { XCTAssertTrue(error is IntentError) }
  }
}
