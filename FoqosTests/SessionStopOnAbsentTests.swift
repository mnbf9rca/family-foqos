import Foundation
import XCTest

@testable import FamilyFoqos

final class SessionStopOnAbsentTests: XCTestCase {

  private func makeMock() -> MockSessionSyncService {
    let mock = MockSessionSyncService()
    return mock
  }

  func testGivenAbsentRecord_WhenStop_ThenCreatesStoppedRecordCreateIfAbsent() async {
    let now = Date()
    let mock = makeMock()
    await mock.setStopOnAbsentCreatesRecord(true)
    let profileId = UUID()

    let result = await mock.stopSession(
      profileId: profileId, endTime: now, deviceId: "device-A")

    switch result {
    case .stopped(let seq):
      XCTAssertEqual(seq, 1)
    default:
      XCTFail("Expected .stopped, got \(result)")
    }
    let fetched = await mock.stopOnAbsentDebugRecord(for: profileId)
    XCTAssertNotNil(fetched)
    XCTAssertEqual(fetched?.isActive, false)
    XCTAssertEqual(fetched?.sequenceNumber, 1)
  }

  func testGivenConcurrentFreshStartWins_WhenStopOnAbsent_ThenStopYieldsAlreadyStopped() async {
    let now = Date()
    let mock = makeMock()
    await mock.setStopOnAbsentCreatesRecord(true)
    await mock.setFreshStartWinsRace(true)
    let profileId = UUID()

    let result = await mock.stopSession(
      profileId: profileId, endTime: now, deviceId: "device-A")

    switch result {
    case .alreadyStopped:
      break
    default:
      XCTFail("Expected .alreadyStopped (stop yields), got \(result)")
    }
    let fetched = await mock.stopOnAbsentDebugRecord(for: profileId)
    XCTAssertEqual(fetched?.isActive, true, "Concurrent fresh active start must survive")
  }

  func testGivenStopOnAbsentCreatedStoppedRecord_ThenRecordIsInactiveSignalForMirrors() async {
    let now = Date()
    let mock = makeMock()
    await mock.setStopOnAbsentCreatesRecord(true)
    let profileId = UUID()

    _ = await mock.stopSession(profileId: profileId, endTime: now, deviceId: "device-A")

    let fetch = await mock.fetchSession(profileId: profileId)
    switch fetch {
    case .found(let record):
      XCTAssertFalse(record.isActive, "Mirror-visible stopped record must be inactive (N13)")
    default:
      XCTFail("Expected .found stopped record, got \(fetch)")
    }
  }

  func testGivenZoneRecreated_WhenFirstStopWrite_ThenCreatesFreshStoppedRecordNotStaleCacheError()
    async
  {
    let now = Date()
    let mock = MockSessionSyncService()
    await mock.setStopOnAbsentCreatesRecord(true)
    let profileId = UUID()

    // An active session existed before the reset.
    _ = await mock.startSession(profileId: profileId, startTime: now, deviceId: "device-A")

    // Zone recreation: the server zone is fresh/empty; the stale cached tag is gone.
    await mock.simulateZoneRecreated()

    let result = await mock.stopSession(
      profileId: profileId, endTime: now.addingTimeInterval(60), deviceId: "device-A")

    switch result {
    case .stopped(let seq):
      XCTAssertEqual(seq, 1, "First post-recreation write must be a fresh create (seq 1)")
    default:
      XCTFail("Expected create-if-absent .stopped, got \(result)")
    }
    let fetched = await mock.stopOnAbsentDebugRecord(for: profileId)
    XCTAssertEqual(fetched?.isActive, false)
  }
}
