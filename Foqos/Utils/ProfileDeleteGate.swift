import Foundation

enum ProfileDeleteGate {
  enum DeleteBlockReason: Equatable {
    case active
    case remotelyActive
    case locked
  }

  static func blockedReason(
    hasLocalActiveSession: Bool,
    isRemotelyActive: Bool,
    isEditLocked: Bool
  ) -> DeleteBlockReason? {
    if hasLocalActiveSession { return .active }
    if isRemotelyActive { return .remotelyActive }
    if isEditLocked { return .locked }
    return nil
  }
}
