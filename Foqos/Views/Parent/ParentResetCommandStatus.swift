import Foundation

/// Saving queues a request; disappearance alone cannot prove execution on a child device.
enum ParentResetCommandStatus: Equatable {
  case idle
  case awaitingChild
  case noLongerPending

  static let afterSuccessfulSave: ParentResetCommandStatus = .awaitingChild

  static func afterConfirmationProbe(commandStillPending: Bool) -> ParentResetCommandStatus {
    commandStillPending ? .awaitingChild : .noLongerPending
  }

  var displayText: String? {
    switch self {
    case .idle:
      return nil
    case .awaitingChild:
      return "Sent — not yet confirmed. Open Foqos on the child's device; both devices may need an app update."
    case .noLongerPending:
      return "Request no longer pending."
    }
  }
}
