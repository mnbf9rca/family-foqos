import CloudKit
import FoqosShared
import Foundation
import SwiftData

@testable import FamilyFoqos

@MainActor
class MockSessionController: SessionController {
  var activeSession: BlockedProfileSession? = nil
  var setRemoteSessionActiveCalls: [(Bool, UUID)] = []

  var startRemoteSessionCalled = false
  var receivedTimerEndTime: Date?
  var receivedStartTime: Date?
  var startRemoteSessionProfileId: UUID?
  func startRemoteSession(
    context: ModelContext,
    profileId: UUID,
    sessionId: UUID?,
    startTime: Date,
    timerEndTime: Date?,
    originDevice: String?, origin: SessionOrigin?, sequenceNumber: Int?, serverModificationDate: Date?
  ) {
    startRemoteSessionCalled = true
    receivedTimerEndTime = timerEndTime
    receivedStartTime = startTime
    startRemoteSessionProfileId = profileId
  }

  var stopRemoteSessionCalled = false
  var stopRemoteSessionProfileId: UUID?
  func stopRemoteSession(context: ModelContext, profileId: UUID, expectedSessionId: String?, sequenceNumber: Int?) {
    stopRemoteSessionCalled = true
    stopRemoteSessionProfileId = profileId
  }

  func setRemoteSessionActive(_ isActive: Bool, profileId: UUID) {
    setRemoteSessionActiveCalls.append((isActive, profileId))
  }
}

/// Supplies read-only CloudKit metadata without introducing a client-authored record field.
final class SessionServerDatedRecord: CKRecord, @unchecked Sendable {  // SAFETY: immutable serverDate; records stay confined to the injected CAS actor.
  let serverDate: Date
  override var modificationDate: Date? { serverDate }
  init(copying record: CKRecord, modifiedAt: Date) {
    self.serverDate = modifiedAt
    // Decode the existing system fields: the Xcode 27 subclass initializer overlay is
    // unavailable in the iOS 26.5 runtime.
    let archive = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archive)
    archive.finishEncoding()
    let decoder = try! NSKeyedUnarchiver(forReadingFrom: archive.encodedData)
    super.init(coder: decoder)!
    decoder.finishDecoding()
    for key in record.allKeys() { self[key] = record[key] }
  }
  required init?(coder: NSCoder) { fatalError("Test fixture does not decode archives") }
}
