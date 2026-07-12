import Foundation

/// Parent-side record tracking a child's device heartbeat status.
/// Stored in UserDefaults — each parent manages their own list.
struct MonitoredDevice: Codable, Identifiable {
  var id: String { "\(childUserRecordName)|\(deviceIdentifier)" }
  var deviceIdentifier: String
  var deviceName: String
  var childUserRecordName: String
  var lastSeenAt: Date
  var isSuppressed: Bool
  var notificationIdentifier: String?
  var authorizationStatus: String?
  /// Timestamp when the parent was alerted about this device's current authorization revocation.
  var authRevokedNotifiedAt: Date?

  static let stalenessThreshold: TimeInterval = 24 * 3600  // 24 hours

  var isAuthRevoked: Bool {
    authorizationStatus == "denied"
  }

  func shouldScheduleAuthRevokedAlert() -> Bool {
    isAuthRevoked && authRevokedNotifiedAt == nil
  }

  nonisolated static func carriedAuthRevokedNotifiedAt(
    previous: Date?,
    newStatus: String?
  ) -> Date? {
    newStatus == "denied" ? previous : nil
  }

  func isStale(now: Date = Date()) -> Bool {
    now.timeIntervalSince(lastSeenAt) >= Self.stalenessThreshold
  }

  func shouldAlert(now: Date = Date()) -> Bool {
    !isSuppressed && (isAuthRevoked || isStale(now: now))
  }
}
