import Foundation
import SwiftData

/// Defines the contract sync applies remote session state through.
/// StrategyManager conforms to this; injected into `SyncApplyService` for testability.
@MainActor
protocol SessionController: AnyObject {
  var activeSession: BlockedProfileSession? { get }
  func startRemoteSession(context: ModelContext, profileId: UUID, sessionId: UUID, startTime: Date)
  func stopRemoteSession(context: ModelContext, profileId: UUID)
  func setRemoteSessionActive(_ isActive: Bool, profileId: UUID)
}
