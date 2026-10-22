import Foundation

/// Saving queues a request; disappearance alone cannot prove execution on a child device.
enum ParentResetCommandStatus: Equatable {
  case idle
  case awaitingChild(FamilyCommand)
  case noLongerPending(FamilyCommandType)

  var pendingCommand: FamilyCommand? {
    if case .awaitingChild(let command) = self { return command }
    return nil
  }

  @MainActor
  func refreshed(using probe: @MainActor (FamilyCommand) async throws -> Bool) async -> Self {
    guard let command = pendingCommand else { return self }
    do {
      return try await probe(command) ? self : .noLongerPending(command.commandType)
    } catch {
      if !(error is CancellationError) {
        Log.error("Failed to check reset command: \(redactedErrorForLog(error))", category: .cloudKit)
      }
      return self
    }
  }

  @MainActor
  static func poll(
    pendingCommands: () -> [FamilyCommand],
    probe: @MainActor (FamilyCommand) async throws -> Bool,
    apply: (FamilyCommand, Self) -> Void,
    sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) async {
    var attempt = 0
    while !Task.isCancelled && !pendingCommands().isEmpty {
      for command in pendingCommands() {
        let next = await Self.awaitingChild(command).refreshed(using: probe)
        guard !Task.isCancelled else { return }
        // A resend can replace this operation while its earlier probe is in flight.
        if pendingCommands().contains(where: { $0.commandType == command.commandType && $0.id == command.id }) {
          apply(command, next)
        }
      }
      guard !pendingCommands().isEmpty else { return }
      do {
        try await sleep(.seconds(attempt < 5 ? 3 : 30))
      } catch {
        return
      }
      attempt += 1
    }
  }

  var displayText: String? {
    switch self {
    case .idle:
      return nil
    case .awaitingChild(let command):
      return "\(Self.operationName(for: command.commandType)) sent. Waiting for the child's phone to pick it up."
    case .noLongerPending(let type):
      return "\(Self.operationName(for: type)) delivered."
    }
  }

  static func sendFailureMessage(for type: FamilyCommandType) -> String {
    switch type {
    case .resetEmergencyCount:
      "Couldn't send the emergency unblock reset. Check your connection and try again."
    case .resetLockCodeThrottle:
      "Couldn't send the PIN attempts reset. Check your connection and try again."
    }
  }

  private static func operationName(for type: FamilyCommandType) -> String {
    switch type {
    case .resetEmergencyCount: "Emergency unblock reset"
    case .resetLockCodeThrottle: "PIN attempts reset"
    }
  }
}
