import Foundation

/// #331: honest status of a parent-to-child reset command on the family dashboard. Saving the
/// command to CloudKit only queues it; confirmation comes only when the child deletes the command
/// record after processing.
enum ParentResetCommandStatus: Equatable {
  case idle
  case awaitingChild
  case confirmed

  static let afterSuccessfulSave: ParentResetCommandStatus = .awaitingChild

  static func afterConfirmationProbe(commandStillPending: Bool) -> ParentResetCommandStatus {
    commandStillPending ? .awaitingChild : .confirmed
  }

  var displayText: String? {
    switch self {
    case .idle:
      return nil
    case .awaitingChild:
      return "Sent — waiting for child to confirm"
    case .confirmed:
      return "Confirmed by child"
    }
  }
}
