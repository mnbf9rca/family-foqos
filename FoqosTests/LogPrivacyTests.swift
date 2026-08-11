import CloudKit
import Foundation
import XCTest

@testable import FoqosShared

final class LogPrivacyTests: XCTestCase {
  func testGivenLocalizedError_WhenRedacted_ThenIncludesDomainCodeAndDescription() {
    let error = DescriptionProbe(message: "network unavailable")

    let result = redactedErrorForLog(error)

    XCTAssertTrue(result.contains("FoqosTests.DescriptionProbe"))
    XCTAssertTrue(result.contains("code="))
    XCTAssertTrue(result.contains("network unavailable"))
  }

  func testGivenDescriptionWithLineBreaks_WhenRedacted_ThenProducesOneLine() {
    let error = DescriptionProbe(message: "first\r\nsecond\nthird")

    let result = redactedErrorForLog(error)

    XCTAssertFalse(result.contains("\r"))
    XCTAssertFalse(result.contains("\n"))
    XCTAssertTrue(result.contains("first second third"))
  }

  func testGivenLongDescription_WhenRedacted_ThenCapsOutputAt2048Characters() {
    let error = DescriptionProbe(message: String(repeating: "x", count: 3_000))

    let result = redactedErrorForLog(error)

    XCTAssertEqual(result.count, 2_048)
  }

  func testGivenUnderlyingChainPastDepthLimit_WhenRedacted_ThenStopsAtDepthMarker() {
    let depthFour = NSError(domain: "depth-four", code: 4)
    let depthThree = NSError(
      domain: "depth-three", code: 3, userInfo: [NSUnderlyingErrorKey: depthFour])
    let depthTwo = NSError(
      domain: "depth-two", code: 2, userInfo: [NSUnderlyingErrorKey: depthThree])
    let depthOne = NSError(
      domain: "depth-one", code: 1, userInfo: [NSUnderlyingErrorKey: depthTwo])
    let root = NSError(domain: "root", code: 0, userInfo: [NSUnderlyingErrorKey: depthOne])

    let result = redactedErrorForLog(root)

    XCTAssertTrue(result.contains("depth limit"))
    XCTAssertFalse(result.contains("depth-four"))
  }

  func testGivenCyclicUnderlyingError_WhenRedacted_ThenStopsAtCycleMarker() {
    let error = CyclicProbe()

    let result = redactedErrorForLog(error)

    XCTAssertTrue(result.contains("cycle"))
    XCTAssertLessThanOrEqual(result.count, 2_048)
  }

  func testGivenPayloadFreeSwiftEnum_WhenRedacted_ThenIncludesTypeAndCase() {
    let result = redactedErrorForLog(PayloadFreeProbe.offline)

    XCTAssertTrue(result.contains("PayloadFreeProbe.offline"))
  }

  func testGivenAssociatedSecret_WhenRedacted_ThenIncludesCaseButDropsPayload() {
    let result = redactedErrorForLog(AssociatedProbe.rejected(secret: "DO-NOT-LOG"))

    XCTAssertTrue(result.contains("AssociatedProbe.rejected"))
    XCTAssertFalse(result.contains("DO-NOT-LOG"))
  }

  func testGivenAssociatedNestedError_WhenRedacted_ThenDropsSecretAndFormatsNestedError() {
    let nested = NSError(
      domain: "NestedDomain",
      code: 17,
      userInfo: [NSLocalizedDescriptionKey: "nested description"]
    )

    let result = redactedErrorForLog(
      AssociatedProbe.wrapped(secret: "DO-NOT-LOG", error: nested))

    XCTAssertTrue(result.contains("AssociatedProbe.wrapped"))
    XCTAssertTrue(result.contains("NestedDomain"))
    XCTAssertTrue(result.contains("nested description"))
    XCTAssertFalse(result.contains("DO-NOT-LOG"))
  }

  func testGivenUnallowlistedUserInfo_WhenRedacted_ThenDropsKeyAndValue() {
    let error = NSError(
      domain: "SafeDomain",
      code: 9,
      userInfo: [
        NSLocalizedDescriptionKey: "safe description",
        "authToken": "DO-NOT-LOG",
      ]
    )

    let result = redactedErrorForLog(error)

    XCTAssertTrue(result.contains("safe description"))
    XCTAssertFalse(result.contains("authToken"))
    XCTAssertFalse(result.contains("DO-NOT-LOG"))
  }

  func testGivenCloudKitPartialErrors_WhenRedacted_ThenKeepsOnlyOpaqueIdsAndNestedError() {
    let zoneID = CKRecordZone.ID(zoneName: "zone-1", ownerName: "owner-1")
    let recordID = CKRecord.ID(recordName: "record-1", zoneID: zoneID)
    let nested = NSError(
      domain: "NestedCloudKitDomain",
      code: 4,
      userInfo: [NSLocalizedDescriptionKey: "nested failure"]
    )
    let error = NSError(
      domain: CKErrorDomain,
      code: CKError.Code.partialFailure.rawValue,
      userInfo: [
        CKPartialErrorsByItemIDKey: [recordID: nested],
        "authToken": "DO-NOT-LOG",
      ]
    )

    let result = redactedErrorForLog(error)

    XCTAssertTrue(result.contains("record-1"))
    XCTAssertTrue(result.contains("zone-1"))
    XCTAssertTrue(result.contains("NestedCloudKitDomain"))
    XCTAssertFalse(result.contains("owner-1"))
    XCTAssertFalse(result.contains("authToken"))
    XCTAssertFalse(result.contains("DO-NOT-LOG"))
  }
}

private struct DescriptionProbe: LocalizedError, CustomNSError {
  static var errorDomain: String { "FoqosTests.DescriptionProbe" }

  let message: String

  var errorDescription: String? { message }
  var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: message] }
}

private enum PayloadFreeProbe: Error {
  case offline
}

private enum AssociatedProbe: Error {
  case rejected(secret: String)
  case wrapped(secret: String, error: Error)
}

private final class CyclicProbe: Error, CustomNSError {
  static var errorDomain: String { "LogPrivacyTests.CyclicProbe" }

  var errorUserInfo: [String: Any] { [NSUnderlyingErrorKey: self] }
}
