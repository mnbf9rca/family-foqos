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
    coordinator?.beginShareAcceptance()
  }

  func failShareAcceptance() {
    coordinator?.failShareAcceptance()
  }

  func completeShareAcceptanceAfterModeApplied() {
    coordinator?.completeShareAcceptanceAfterModeApplied()
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
