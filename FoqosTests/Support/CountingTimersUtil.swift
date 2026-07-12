import Foundation

@testable import FamilyFoqos

final class CountingTimersUtil: TimersUtilScheduling {
  private(set) var scheduledIdentifiers: [String] = []

  @discardableResult
  func scheduleNotification(
    title: String,
    message: String,
    seconds: TimeInterval,
    identifier: String?,
    threadIdentifier: String?,
    completion: @escaping @Sendable (NotificationResult) -> Void
  ) -> String {
    let notificationId = identifier ?? UUID().uuidString
    scheduledIdentifiers.append(notificationId)
    completion(.success)
    return notificationId
  }

  func scheduleCount(prefix: String) -> Int {
    scheduledIdentifiers.filter { $0.hasPrefix(prefix) }.count
  }

  func cancelAll() {}

  func cancelAllNotifications() {}

  func cancelAllBackgroundTasks() {}
}
