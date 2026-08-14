import SwiftUI

struct AppScheduleRefreshState {
  private var didPerformInitialRefresh = false
  private var becameNonActiveAfterInitialRefresh = false

  mutating func shouldPerformInitialRefresh() -> Bool {
    guard !didPerformInitialRefresh else { return false }
    didPerformInitialRefresh = true
    return true
  }

  mutating func shouldRefresh(for scenePhase: ScenePhase) -> Bool {
    guard didPerformInitialRefresh else { return false }

    switch scenePhase {
    case .active:
      guard becameNonActiveAfterInitialRefresh else { return false }
      becameNonActiveAfterInitialRefresh = false
      return true
    case .background, .inactive:
      becameNonActiveAfterInitialRefresh = true
      return false
    @unknown default:
      return false
    }
  }
}
