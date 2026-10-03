import FoqosShared
import Foundation
import SwiftData

/// Defines the contract sync applies remote session state through.
/// StrategyManager conforms to this; injected into `SyncApplyService` for testability.
@MainActor
protocol SessionController: AnyObject {
  var activeSession: BlockedProfileSession? { get }
  func startRemoteSession(context: ModelContext, profileId: UUID, sessionId: UUID?, startTime: Date, timerEndTime: Date?, originDevice: String?, origin: SessionOrigin?, sequenceNumber: Int?)
  func stopRemoteSession(context: ModelContext, profileId: UUID, expectedSessionId: String?, sequenceNumber: Int?)
  func setRemoteSessionActive(_ isActive: Bool, profileId: UUID)
}

extension SessionController {
  func stopRemoteSession(context: ModelContext, profileId: UUID) {
    stopRemoteSession(context: context, profileId: profileId, expectedSessionId: nil, sequenceNumber: nil)
  }
}
