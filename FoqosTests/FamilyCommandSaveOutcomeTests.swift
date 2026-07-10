import CloudKit
import XCTest

@testable import FamilyFoqos

@MainActor
final class FamilyCommandSaveOutcomeTests: XCTestCase {

  func testGivenServerRecordChanged_WhenClassifying_ThenAlreadyPending() {
    let error = CKError(.serverRecordChanged)
    XCTAssertEqual(CloudKitNetworkService.classifyCommandSave(error: error), .alreadyPending)
  }

  func testGivenOtherCKError_WhenClassifying_ThenFailed() {
    let error = CKError(.networkUnavailable)
    XCTAssertEqual(CloudKitNetworkService.classifyCommandSave(error: error), .failed)
  }

  func testGivenNonCKError_WhenClassifying_ThenFailed() {
    struct Boom: Error {}
    XCTAssertEqual(CloudKitNetworkService.classifyCommandSave(error: Boom()), .failed)
  }
}
