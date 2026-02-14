import Foundation
import UserNotifications

/// Handles notification presentation in the foreground.
/// When a pre-activation reminder is about to display, removes any previously
/// delivered reminders for the same profile so only the latest is visible.
class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {  // SAFETY: No mutable state; delegate methods are stateless
  static let shared = NotificationDelegate()

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let identifier = notification.request.identifier

    // If this is a pre-activation reminder, remove other delivered reminders for the same profile
    if let profileId = TimersUtil.profileIdFromReminderIdentifier(identifier) {
      let allIds = TimersUtil.allPreActivationReminderIdentifiers(for: profileId)
      let otherIds = allIds.filter { $0 != identifier }
      center.removeDeliveredNotifications(withIdentifiers: otherIds)
    }

    completionHandler([.banner, .sound])
  }
}
