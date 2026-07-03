import CloudKit
import XCTest

@testable import FamilyFoqos

/// The only unit-testable slice of the integration-only production adapter: the pure
/// zone-deletion-reason translation. Its presence in this test target also forces the
/// whole CKSyncEngineDriver (delegate conformance + event translation) to compile,
/// which is the phase's build-level guarantee for the adapter.
final class CKSyncEngineDriverTranslationTests: XCTestCase {
  func testGivenZoneDeletionReasons_WhenTranslated_ThenMapToDomainReasons() {
    XCTAssertEqual(CKSyncEngineDriver.translateReason(.deleted), .deleted)
    XCTAssertEqual(CKSyncEngineDriver.translateReason(.purged), .purged)
    XCTAssertEqual(CKSyncEngineDriver.translateReason(.encryptedDataReset), .encryptedDataReset)
  }
}
