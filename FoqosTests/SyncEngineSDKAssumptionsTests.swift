import CloudKit
import XCTest

@testable import FamilyFoqos

/// Decision spike (#267 Phase A): confirms the CKSyncEngine pending-change and
/// send-scope types are test-constructible, locking the seam to the real SDK types
/// (no domain-enum fallback). If any assertion here fails to COMPILE on a future SDK,
/// adopt the domain-enum fallback from the contract's Phase A implementation note and
/// thread it through SyncEngineDriver instead.
final class SyncEngineSDKAssumptionsTests: XCTestCase {
  private func zoneID() -> CKRecordZone.ID {
    CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
  }

  func testGivenSDK_WhenConstructingPendingRecordChanges_ThenTypesAreConstructible() {
    let recordID = CKRecord.ID(recordName: "p1", zoneID: zoneID())
    let save: CKSyncEngine.PendingRecordZoneChange = .saveRecord(recordID)
    let delete: CKSyncEngine.PendingRecordZoneChange = .deleteRecord(recordID)
    XCTAssertNotEqual(save, delete)
    XCTAssertEqual(save, .saveRecord(recordID))
  }

  func testGivenSDK_WhenConstructingPendingDatabaseChanges_ThenTypesAreConstructible() {
    let zone = CKRecordZone(zoneName: CloudKitConstants.syncZoneName)
    let saveZone: CKSyncEngine.PendingDatabaseChange = .saveZone(zone)
    let deleteZone: CKSyncEngine.PendingDatabaseChange = .deleteZone(zoneID())
    XCTAssertNotEqual(saveZone, deleteZone)
  }

  func testGivenSDK_WhenConstructingSendChangesScope_ThenScopeTypeResolvesAndFilters() {
    let recordID = CKRecord.ID(recordName: "p1", zoneID: zoneID())
    let scope: CKSyncEngine.SendChangesOptions.Scope = .zoneIDs([zoneID()])
    XCTAssertTrue(scope.contains(CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID)))
    XCTAssertEqual(scope, .zoneIDs([zoneID()]))
  }
}
