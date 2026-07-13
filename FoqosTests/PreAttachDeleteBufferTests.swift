import Foundation
import XCTest

@testable import FamilyFoqos

@MainActor
final class PreAttachDeleteBufferTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "PreAttachDeleteBufferTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func testGivenBufferedDeletes_WhenDrained_ThenReturnsAllAndClears() {
    PreAttachDeleteBuffer.add("A", defaults: defaults)
    PreAttachDeleteBuffer.add("B", defaults: defaults)
    PreAttachDeleteBuffer.add("A", defaults: defaults)

    let drained = Set(PreAttachDeleteBuffer.drainAll(defaults: defaults))

    XCTAssertEqual(drained, ["A", "B"])
    XCTAssertTrue(
      PreAttachDeleteBuffer.drainAll(defaults: defaults).isEmpty,
      "drain must clear durably")
  }

  func testGivenNoBuffer_WhenDrained_ThenEmpty() {
    XCTAssertTrue(PreAttachDeleteBuffer.drainAll(defaults: defaults).isEmpty)
  }

  func testGivenBufferedDeletes_WhenPendingReadWithoutAcknowledge_ThenBufferRemains() {
    PreAttachDeleteBuffer.add("A", defaults: defaults)
    PreAttachDeleteBuffer.add("B", defaults: defaults)

    XCTAssertEqual(Set(PreAttachDeleteBuffer.pending(defaults: defaults)), ["A", "B"])
    XCTAssertEqual(
      Set(PreAttachDeleteBuffer.pending(defaults: defaults)),
      ["A", "B"],
      "reading pending names must not clear the only durable copy before tombstone promotion")
  }

  func testGivenBufferedDeletes_WhenAcknowledgingOne_ThenOnlyThatNameClears() {
    PreAttachDeleteBuffer.add("A", defaults: defaults)
    PreAttachDeleteBuffer.add("B", defaults: defaults)

    PreAttachDeleteBuffer.acknowledge("A", defaults: defaults)

    XCTAssertEqual(Set(PreAttachDeleteBuffer.pending(defaults: defaults)), ["B"])
  }
}
