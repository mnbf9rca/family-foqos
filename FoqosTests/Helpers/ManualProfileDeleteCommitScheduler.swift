import Foundation

@MainActor
final class ManualProfileDeleteCommitScheduler {
  private(set) var scheduledOperations: [@MainActor () -> Void] = []

  func schedule(_ operation: @escaping @MainActor () -> Void) {
    scheduledOperations.append(operation)
  }

  func runNext() {
    let operation = scheduledOperations.removeFirst()
    operation()
  }
}
