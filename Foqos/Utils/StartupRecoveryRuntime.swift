import Combine

@MainActor
final class StartupRecoveryRuntime: ObservableObject {
  static let shared = StartupRecoveryRuntime()

  @Published private(set) var isHeld = true
  private(set) weak var coordinator: StartupRecoveryCoordinator?

  func register(coordinator: StartupRecoveryCoordinator) {
    self.coordinator = coordinator
  }

  func release() {
    guard isHeld else { return }
    isHeld = false
  }

  func beginShareAcceptance() {
    guard let coordinator = coordinatorForArbitration() else { return }
    coordinator.beginShareAcceptance()
  }

  func failShareAcceptance() {
    guard let coordinator = coordinatorForArbitration() else { return }
    coordinator.failShareAcceptance()
  }

  func completeShareAcceptanceAfterModeApplied() {
    guard let coordinator = coordinatorForArbitration() else { return }
    coordinator.completeShareAcceptanceAfterModeApplied()
  }

  private func coordinatorForArbitration() -> StartupRecoveryCoordinator? {
    guard let coordinator else {
      assertionFailure("Startup recovery coordinator is not registered")
      Log.error(
        "Startup recovery arbitration unavailable because the coordinator is not registered",
        category: .app)
      return nil
    }
    return coordinator
  }
}

enum StartupRecoveryPushRouter {
  @MainActor
  static func route(
    isHeld: Bool,
    onHeld: () -> Void,
    onReleased: () async -> Void
  ) async {
    guard !isHeld else {
      onHeld()
      return
    }
    await onReleased()
  }
}
