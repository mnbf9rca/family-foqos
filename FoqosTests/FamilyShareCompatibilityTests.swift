import CloudKit
import XCTest

@testable import FamilyFoqos

@MainActor
final class FamilyShareCompatibilityTests: XCTestCase {
  private func commandRecord(now: Date) -> CKRecord {
    FamilyCommand(
      commandType: .resetEmergencyCount, targetChildId: "child", createdBy: "parent",
      createdAt: now
    ).toCKRecord(in: CKRecordZone.ID(zoneName: "test"))
  }

  private func lockRecord(now: Date) -> CKRecord {
    let record = CKRecord(recordType: FamilyLockCode.recordType)
    record["id"] = "00000000-0000-0000-0000-000000000480"
    record["codeHash"] = "74fd496c232940c74b096a647f366f81c853dd7e8327821744fbeffd279b2693"
    record["codeSalt"] = "AQIDBAUGBwgJCgsMDQ4PEA=="
    record["createdAt"] = now
    record["updatedAt"] = now
    return record
  }

  func testCommandEnvelopeRejectsEmptyTargetAndSender() {
    let now = Date()
    for field in ["targetChildId", "createdBy"] {
      let record = commandRecord(now: now)
      record[field] = ""
      XCTAssertNil(FamilyCommand(from: record), field)
    }
  }

  func testCommandClassifierRecognizesLegacyOperationsAndLeavesFutureTypeUnexecutable() throws {
    let now = Date()
    for rawType in ["resetEmergencyCount", "resetLockCodeThrottle", "futureOperation"] {
      let record = commandRecord(now: now)
      record["commandType"] = rawType
      record["futureField"] = "ignored"
      switch FamilyCommand.decode(record) {
      case .supported(let command):
        XCTAssertNotEqual(rawType, "futureOperation")
        XCTAssertEqual(command.commandType.rawValue, rawType)
        XCTAssertEqual(command.id.uuidString, record["id"] as? String)
        XCTAssertEqual(command.targetChildId, "child")
        XCTAssertEqual(command.createdBy, "parent")
        XCTAssertEqual(command.createdAt, now)
      case .unsupported(let discriminator):
        XCTAssertEqual(rawType, "futureOperation")
        XCTAssertEqual(discriminator, "futureOperation")
        XCTAssertNil(FamilyCommand(from: record))
      case .malformed:
        XCTFail("Valid envelope was rejected")
      }
    }
  }

  func testCommandClassifierValidatesEntireEnvelopeBeforeAcceptingFutureType() {
    let now = Date()
    let invalidFields: [(String, CKRecordValue?)] = [
      ("id", nil), ("id", "bad-uuid" as NSString), ("id", NSNumber(value: 42)),
      ("commandType", nil), ("commandType", "" as NSString),
      ("commandType", NSNumber(value: 42)),
      ("targetChildId", nil), ("targetChildId", "" as NSString),
      ("targetChildId", NSNumber(value: 42)),
      ("createdBy", nil), ("createdBy", "" as NSString),
      ("createdBy", NSNumber(value: 42)),
      ("createdAt", nil), ("createdAt", "not-a-date" as NSString),
    ]
    for rawType in ["resetEmergencyCount", "futureOperation"] {
      for (field, value) in invalidFields {
        let record = commandRecord(now: now)
        record["commandType"] = rawType
        record[field] = value
        guard case .malformed = FamilyCommand.decode(record) else {
          XCTFail("Invalid \(field) accepted for \(rawType)")
          continue
        }
      }
    }
    let wrongType = CKRecord(recordType: "OtherRecord")
    let valid = commandRecord(now: now)
    for key in valid.allKeys() { wrongType[key] = valid[key] }
    guard case .malformed = FamilyCommand.decode(wrongType) else {
      return XCTFail("Wrong record type accepted")
    }
  }

  func testUnknownCommandsDoNotDisconnectOrEnterExecutableFetchResults() throws {
    let now = Date()
    let known = commandRecord(now: now)
    let unknown = commandRecord(now: now)
    unknown["commandType"] = "futureOperation"
    for records in [[unknown], [unknown, known], [known, unknown]] {
      let fetched = CloudKitNetworkService.resolvePendingCommandFetch(
        records: records.map { .success($0) }, hasFailures: false)
      XCTAssertTrue(fetched.isConnected)
      let expectedCount = records.count - 1
      XCTAssertEqual(fetched.commands.count, expectedCount)
      if let command = fetched.commands.first {
        XCTAssertEqual(command.id.uuidString, known["id"] as? String)
      }
      XCTAssertEqual(
        LockCodeManager.commandRefreshResult(
          didApplyCommand: !fetched.commands.isEmpty, isConnected: fetched.isConnected),
        expectedCount == 0 ? .noData : .newData)
    }
  }

  func testFailedRowsAndZonesPreserveSupportedCommandsButFailRefresh() {
    let now = Date()
    let known = commandRecord(now: now)
    let malformed = commandRecord(now: now)
    malformed["commandType"] = "futureOperation"
    malformed["createdBy"] = nil
    let cases: [([Result<CKRecord, Error>], Bool)] = [
      ([.success(known), .success(malformed)], false),
      ([.failure(CKError(.networkFailure)), .success(known)], false),
      ([.success(known)], true),
    ]
    for (records, zoneFailed) in cases {
      let fetched = CloudKitNetworkService.resolvePendingCommandFetch(
        records: records, hasFailures: zoneFailed)
      XCTAssertEqual(fetched.commands.count, 1)
      XCTAssertEqual(fetched.commands.first?.id.uuidString, known["id"] as? String)
      XCTAssertFalse(fetched.isConnected)
      XCTAssertEqual(
        LockCodeManager.commandRefreshResult(didApplyCommand: true, isConnected: fetched.isConnected),
        .failed)
    }
  }

  func testLegacyLockScopeAcceptsOnlyAbsentOrExplicitValidScope() throws {
    let now = Date()
    let cases: [(CKRecordValue?, CKRecordValue?, LockCodeScope?)] = [
      (nil, nil, .allChildren),
      ("all" as NSString, nil, .allChildren),
      ("all" as NSString, NSNumber(value: 42), .allChildren),
      ("specific" as NSString, "child" as NSString, .specificChild(childId: "child")),
      (NSNumber(value: 42), nil, nil),
      ("" as NSString, nil, nil),
      ("futureScope" as NSString, "child" as NSString, nil),
      ("specific" as NSString, nil, nil),
      ("specific" as NSString, NSNumber(value: 42), nil),
      ("specific" as NSString, "" as NSString, nil),
    ]
    for (scopeType, childID, expected) in cases {
      let record = lockRecord(now: now)
      record["scopeType"] = scopeType
      record["scopeChildId"] = childID
      record["futureField"] = "ignored"
      XCTAssertEqual(FamilyLockCode(from: record)?.scope, expected)
    }
  }

  func testLegacyHashFixtureVerifiesPINAfterCloudKitAndCacheRoundTrip() throws {
    let now = Date()
    let code = try XCTUnwrap(FamilyLockCode(from: lockRecord(now: now)))
    XCTAssertTrue(code.verifyCode("1234"))
    XCTAssertFalse(code.verifyCode("9999"))
    let restored = try JSONDecoder().decode(
      FamilyLockCode.self, from: JSONEncoder().encode(code))
    XCTAssertEqual(restored, code)
    XCTAssertTrue(restored.verifyCode("1234"))
    XCTAssertFalse(restored.verifyCode("9999"))
  }

  func testParentLockFetchRejectsPartialListsAndWrapsRowErrors() throws {
    let now = Date()
    let valid = lockRecord(now: now)
    let malformed = lockRecord(now: now)
    malformed["scopeType"] = "futureScope"
    let failures: [Result<CKRecord, Error>] = [
      .success(malformed), .failure(CKError(.networkFailure)), .failure(CKError(.unknownItem)),
    ]
    for failure in failures {
      XCTAssertThrowsError(
        try CloudKitNetworkService.decodeLockCodeRecords([.success(valid), failure])
      ) { error in
        guard case CloudKitError.fetchFailed = error else {
          return XCTFail("Row failure must remain a fetch failure, including unknownItem")
        }
      }
    }
    XCTAssertTrue(try CloudKitNetworkService.decodeLockCodeRecords([]).isEmpty)
    let earlier = lockRecord(now: now.addingTimeInterval(-1))
    let codes = try CloudKitNetworkService.decodeLockCodeRecords([.success(valid), .success(earlier)])
    XCTAssertEqual(codes.map(\.createdAt), [now.addingTimeInterval(-1), now])
  }

  func testRejectedScopePreservesWholeChildCache() throws {
    let now = Date()
    let persisted = [try XCTUnwrap(FamilyLockCode(from: lockRecord(now: now)))]
    let malformed = lockRecord(now: now)
    malformed["scopeType"] = "specific"
    let decoded = FamilyLockCode(from: malformed)
    XCTAssertNil(decoded)
    let fetched = CloudKitNetworkService.resolveSharedLockCodeFetch(
      codes: [], hasRecordFailures: decoded == nil)
    let resolved = LockCodeManager.resolveLockCodes(
      fetched: fetched.codes, isConnected: fetched.isConnected, persisted: persisted)
    XCTAssertFalse(fetched.isConnected)
    XCTAssertEqual(resolved.cache, persisted)
    XCTAssertEqual(resolved.persist, persisted)
  }
}
