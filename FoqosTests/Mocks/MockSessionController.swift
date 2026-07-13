import Foundation
import SwiftData

@testable import FamilyFoqos

@MainActor
class MockSessionController: SessionController {
  var activeSession: BlockedProfileSession? = nil
  var setRemoteSessionActiveCalls: [(Bool, UUID)] = []

  var startRemoteSessionCalled = false
  var startRemoteSessionProfileId: UUID?
  func startRemoteSession(
    context: ModelContext,
    profileId: UUID,
    sessionId: UUID,
    startTime: Date
  ) {
    startRemoteSessionCalled = true
    startRemoteSessionProfileId = profileId
  }

  var stopRemoteSessionCalled = false
  var stopRemoteSessionProfileId: UUID?
  func stopRemoteSession(context: ModelContext, profileId: UUID) {
    stopRemoteSessionCalled = true
    stopRemoteSessionProfileId = profileId
  }

  func setRemoteSessionActive(_ isActive: Bool, profileId: UUID) {
    setRemoteSessionActiveCalls.append((isActive, profileId))
  }
}
