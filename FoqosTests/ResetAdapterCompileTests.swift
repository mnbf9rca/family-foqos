import CloudKit
import Foundation
import XCTest

@testable import FamilyFoqos

@MainActor
final class ResetAdapterCompileTests: XCTestCase {
  func testAdaptersConformToResetSeams() {
    let zoneID = CKRecordZone.ID(
      zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
    let database =
      CKContainer(identifier: CloudKitConstants.containerIdentifier).privateCloudDatabase
    let fetcher: RecordFetching = DatabaseRecordFetcher(database: database)
    let surfacer: ResetConflictSurfacing = ConflictManagerResetSurfacer()
    let outbox: ResetOutbox = DriverResetOutbox(driver: MockSyncEngineDriver(), zoneID: zoneID)
    XCTAssertNotNil(fetcher)
    XCTAssertNotNil(surfacer)
    XCTAssertNotNil(outbox)
    XCTAssertEqual(ResetController.commandRecordName, "sync-reset-command")
  }
}
