import CloudKit
import XCTest

@testable import FamilyFoqos

final class ProfileSyncAccountResolverTests: XCTestCase {
  func testAvailabilityMapping() {
    let recordID = CKRecord.ID(recordName: "user-A")

    XCTAssertEqual(
      AccountAvailability(from: .available, recordID: recordID, error: nil),
      .available(recordID))
    XCTAssertEqual(
      AccountAvailability(from: .noAccount, recordID: nil, error: nil),
      .noAccount)
    XCTAssertEqual(
      AccountAvailability(from: .couldNotDetermine, recordID: nil, error: nil),
      .ambiguous)
    XCTAssertEqual(
      AccountAvailability(from: .temporarilyUnavailable, recordID: nil, error: nil),
      .ambiguous)
    XCTAssertEqual(
      AccountAvailability(from: .restricted, recordID: nil, error: nil),
      .ambiguous)
    XCTAssertEqual(
      AccountAvailability(from: .available, recordID: recordID, error: CKError(.networkUnavailable)),
      .ambiguous)
  }
}
