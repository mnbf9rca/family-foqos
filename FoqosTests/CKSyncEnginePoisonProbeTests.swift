import CloudKit
import XCTest

@testable import FamilyFoqos

/// #286 DIAGNOSTIC PROBE — NOT a permanent test. Constructs a real `CKSyncEngine`
/// (no iCloud account required on the simulator) and calls `sendChanges()` against
/// candidate pending-queue *shapes* to determine which shape trips the CloudKit-internal
/// `_assertionFailure` seen in the device crash reports. The crash stack shows the assert
/// fires synchronously at the top of `sendChanges()`, BEFORE the batch delegate and before
/// any network return — i.e. a client-side precondition on the pending-queue shape. If any
/// shape traps here (aborting the test process), that shape is the poison and the failure
/// is an implementation issue, not a protocol one. Run each `testShape*` INDIVIDUALLY via
/// `-only-testing` so a trap isolates the offending shape.
///
/// Each test uses `try?` around `sendChanges()`: a thrown CKError (e.g. no account) is a
/// clean pass (this shape does NOT trip a client-side assert). A hard process abort is the
/// reproduction signal.
/// Standalone delegate — kept off the XCTestCase (a `CKSyncEngineDelegate` conformance is
/// `Sendable`, which an XCTestCase subclass cannot be).
private final class ProbeDelegate: NSObject, CKSyncEngineDelegate {
  func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {}

  func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    // The crash asserts synchronously at sendChanges() entry, BEFORE this delegate is
    // called — so returning nil is sufficient to reach the poison shape.
    nil
  }
}

@MainActor
final class CKSyncEnginePoisonProbeTests: XCTestCase {

  private let delegate = ProbeDelegate()

  // MARK: Helpers

  private func makeEngine() -> CKSyncEngine {
    let container = CKContainer(identifier: "iCloud.com.cynexia.family-foqos")
    var config = CKSyncEngine.Configuration(
      database: container.privateCloudDatabase, stateSerialization: nil, delegate: delegate)
    config.automaticallySync = false
    return CKSyncEngine(config)
  }

  private var zoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: "DeviceSync", ownerName: CKCurrentUserDefaultName)
  }

  private func recordID(_ name: String = UUID().uuidString) -> CKRecord.ID {
    CKRecord.ID(recordName: name, zoneID: zoneID)
  }

  // MARK: Shapes

  /// Baseline: a normal first-boot seed (zone save + a record save). Expected LEGAL.
  func testShapeA_saveZonePlusSaveRecord_baseline() async {
    let engine = makeEngine()
    engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID())])
    NSLog("[#286 PROBE] ShapeA about to sendChanges: db=\(engine.state.pendingDatabaseChanges) rec=\(engine.state.pendingRecordZoneChanges)")
    try? await engine.sendChanges()
    NSLog("[#286 PROBE] ShapeA survived sendChanges")
  }

  /// Mechanism (a): a pending record save COEXISTS with a pending zone delete for the same
  /// zone at one sendChanges.
  func testShapeB_saveRecordPlusDeleteZone_coexist() async {
    let engine = makeEngine()
    engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID())])
    engine.state.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
    NSLog("[#286 PROBE] ShapeB about to sendChanges: db=\(engine.state.pendingDatabaseChanges) rec=\(engine.state.pendingRecordZoneChanges)")
    try? await engine.sendChanges()
    NSLog("[#286 PROBE] ShapeB survived sendChanges")
  }

  /// Mechanism (a'): a pending zone delete AND a pending zone save for the same zone.
  func testShapeC_deleteZonePlusSaveZone_coexist() async {
    let engine = makeEngine()
    engine.state.add(pendingDatabaseChanges: [
      .deleteZone(zoneID), .saveZone(CKRecordZone(zoneID: zoneID)),
    ])
    NSLog("[#286 PROBE] ShapeC about to sendChanges: db=\(engine.state.pendingDatabaseChanges) rec=\(engine.state.pendingRecordZoneChanges)")
    try? await engine.sendChanges()
    NSLog("[#286 PROBE] ShapeC survived sendChanges")
  }

  /// The exact reset SEEDING batch shape: saveZone + the fixed-name command save +
  /// a data record save, all in one sendChanges.
  func testShapeD_resetSeedingBatch() async {
    let engine = makeEngine()
    engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    engine.state.add(pendingRecordZoneChanges: [
      .saveRecord(recordID(ResetController.commandRecordName)),
      .saveRecord(recordID()),
    ])
    NSLog("[#286 PROBE] ShapeD about to sendChanges: db=\(engine.state.pendingDatabaseChanges) rec=\(engine.state.pendingRecordZoneChanges)")
    try? await engine.sendChanges()
    NSLog("[#286 PROBE] ShapeD survived sendChanges")
  }

  /// Mechanism (a''): delete + recreate + seed all coexisting (deleteZone + saveZone +
  /// saveRecord), the union a naive resume could present in one send.
  func testShapeE_deleteZonePlusSaveZonePlusSaveRecord() async {
    let engine = makeEngine()
    engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID())])
    engine.state.add(pendingDatabaseChanges: [
      .deleteZone(zoneID), .saveZone(CKRecordZone(zoneID: zoneID)),
    ])
    NSLog("[#286 PROBE] ShapeE about to sendChanges: db=\(engine.state.pendingDatabaseChanges) rec=\(engine.state.pendingRecordZoneChanges)")
    try? await engine.sendChanges()
    NSLog("[#286 PROBE] ShapeE survived sendChanges")
  }
}
