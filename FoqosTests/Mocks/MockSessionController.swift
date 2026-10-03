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
    originDevice: String?, origin: SessionOrigin?, sequenceNumber: Int?
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
