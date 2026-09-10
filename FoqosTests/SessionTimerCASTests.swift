import CloudKit
import FoqosShared
import XCTest

@testable import FamilyFoqos

final class SessionTimerCASTests: XCTestCase {
  private func record(profile: UUID, start: Date, owner: String, deadline: Date?) -> CKRecord {
    var session = ProfileSessionRecord(profileId: profile)
    session.applyUpdate(isActive: true, sequenceNumber: 1, deviceId: owner, startTime: start, timerEndTime: deadline)
    return session.toCKRecord(in: CKRecordZone.ID(zoneName: "Test"))
  }

  func testTimerStopConflictRefetchRejectsReplacementAndOtherOwner() async {
    let now = Date()
    let profile = UUID()
    let owner = SharedData.deviceSyncId.uuidString
    for (remoteStart, remoteOwner) in [(now.addingTimeInterval(5), owner), (now, "other-device")] {
      let server = TimerCASRecords(records: [
        record(profile: profile, start: now, owner: owner, deadline: now.addingTimeInterval(900)),
        record(profile: profile, start: remoteStart, owner: remoteOwner, deadline: now.addingTimeInterval(1800)),
      ])
      let service = SessionSyncService(fetchRecord: { _ in try await server.fetch() }, saveRecord: { try await server.save($0) })
      let result = await service.stopSession(profileId: profile, endTime: now, expectedStart: now.addingTimeInterval(0.25))
      guard case .alreadyStopped = result else {
        XCTFail("Obsolete timer stop must yield")
        continue
      }
      let saves = await server.saves
      XCTAssertEqual(saves.count, 1)
      XCTAssertNil(saves.first?["timerEndTime"])
    }
  }

  func testOrdinaryStopKeepsConflictBehaviorAndMatchingTimerRetainsExpectation() async {
    let now = Date()
    let profile = UUID()
    let owner = SharedData.deviceSyncId.uuidString
    let active = record(profile: profile, start: now, owner: owner, deadline: now.addingTimeInterval(900))
    let server = TimerCASRecords(records: [active, active])
    let service = SessionSyncService(fetchRecord: { _ in try await server.fetch() }, saveRecord: { try await server.save($0) })
    let result = await service.stopSession(profileId: profile, endTime: now, expectedStart: now.addingTimeInterval(0.4))
    guard case .conflict(let current) = result else { return XCTFail("Matching owner still conflicts") }
    XCTAssertEqual(current.validTimerEndTime, now.addingTimeInterval(900))
    let other = record(profile: profile, start: now, owner: "B", deadline: nil)
    let ordinaryServer = TimerCASRecords(records: [other], failSave: false)
    let ordinary = SessionSyncService(fetchRecord: { _ in try await ordinaryServer.fetch() }, saveRecord: { try await ordinaryServer.save($0) })
    let ordinaryResult = await ordinary.stopSession(profileId: profile, endTime: now)
    guard case .stopped = ordinaryResult else { return XCTFail("Ordinary authorized stops do not require timer ownership") }
  }

  func testStartConflictUsesAuthoritativeDeadlineAndNewWritesClearOldValue() async {
    let now = Date()
    let profile = UUID()
    var inactive = ProfileSessionRecord(profileId: profile)
    inactive.applyUpdate(isActive: false, sequenceNumber: 1, deviceId: "B", endTime: now)
    let old = inactive.toCKRecord(in: CKRecordZone.ID(zoneName: "Test"))
    old["timerEndTime"] = now.addingTimeInterval(5000)
    let winner = record(profile: profile, start: now.addingTimeInterval(-10), owner: "B", deadline: now.addingTimeInterval(1800))
    let server = TimerCASRecords(records: [old, winner])
    let service = SessionSyncService(fetchRecord: { _ in try await server.fetch() }, saveRecord: { try await server.save($0) })
    let result = await service.startSession(profileId: profile, startTime: now, timerEndTime: nil)
    guard case .alreadyActive(let active) = result else { return XCTFail("Server active record wins") }
    XCTAssertEqual(active.validTimerEndTime, now.addingTimeInterval(1800))
    let saves = await server.saves
    XCTAssertEqual(saves.count, 1)
    XCTAssertNil(saves.first?["timerEndTime"])
  }
}

private actor TimerCASRecords {
  var records: [CKRecord]
  var saves: [CKRecord] = []
  let failSave: Bool
  init(records: [CKRecord], failSave: Bool = true) {
    self.records = records
    self.failSave = failSave
  }
  func fetch() throws -> CKRecord {
    guard !records.isEmpty else { throw CKError(.unknownItem) }
    return records.removeFirst().copy() as! CKRecord
  }
  func save(_ record: CKRecord) throws -> CKRecord {
    saves.append(record.copy() as! CKRecord)
    if failSave { throw CKError(.serverRecordChanged) }
    return record
  }
}
