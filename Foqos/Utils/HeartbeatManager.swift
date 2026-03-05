import FamilyControls
import Foundation
import UIKit

/// Manages device heartbeat lifecycle for both child and parent modes.
@MainActor
class HeartbeatManager: ObservableObject {
  static let shared = HeartbeatManager()

  private static let userDefaultsKey = "family_foqos_monitored_devices"
  private static let notificationEnabledKey = "family_foqos_heartbeat_notifications_enabled"

  @Published var monitoredDevices: [MonitoredDevice] = []

  @Published var heartbeatNotificationsEnabled: Bool {
    didSet {
      UserDefaults.standard.set(heartbeatNotificationsEnabled, forKey: Self.notificationEnabledKey)
      if heartbeatNotificationsEnabled {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
          _, _ in
        }
      }
    }
  }

  private init() {
    self.heartbeatNotificationsEnabled = UserDefaults.standard.bool(
      forKey: Self.notificationEnabledKey)
    self.monitoredDevices = Self.loadDevices()
  }

  // MARK: - Child Side

  /// Write heartbeat to CloudKit. Fire-and-forget — must not block profile activation.
  func writeHeartbeat() {
    let authStatus = AuthorizationCenter.shared.authorizationStatus
    let statusString: String
    switch authStatus {
    case .approved: statusString = "approved"
    case .denied: statusString = "denied"
    case .notDetermined: statusString = "notDetermined"
    @unknown default: statusString = "unknown"
    }

    guard let userRecordName = CloudKitManager.shared.currentUserRecordID?.recordName else {
      Log.warning("No user record ID available for heartbeat", category: .cloudKit)
      return
    }

    let heartbeat = DeviceHeartbeat(
      childUserRecordName: userRecordName,
      deviceIdentifier: UIDevice.current.identifierForVendor?.uuidString ?? "unknown",
      deviceName: UIDevice.current.name,
      lastHeartbeatAt: Date(),
      authorizationStatus: statusString
    )

    Task {
      do {
        try await CloudKitManager.shared.writeHeartbeat(heartbeat)
      } catch {
        Log.warning("Heartbeat write failed (non-blocking): \(error)", category: .cloudKit)
      }
    }
  }

  // MARK: - Parent Side

  /// Fetch heartbeats from CloudKit and update local monitored devices.
  func refreshHeartbeats() async {
    let heartbeats = await CloudKitManager.shared.fetchHeartbeats()

    for heartbeat in heartbeats {
      updateOrCreateDevice(from: heartbeat)
    }
    saveDevices()

    if heartbeatNotificationsEnabled {
      scheduleNotifications()
    }
  }

  /// Remove a device from monitoring and delete its CloudKit record.
  func removeDevice(_ device: MonitoredDevice) async {
    cancelNotification(for: device)
    monitoredDevices.removeAll { $0.deviceIdentifier == device.deviceIdentifier }
    saveDevices()

    do {
      try await CloudKitManager.shared.deleteHeartbeat(
        childUserRecordName: device.childUserRecordName,
        deviceIdentifier: device.deviceIdentifier
      )
    } catch {
      Log.warning("Failed to delete heartbeat record: \(error)", category: .cloudKit)
    }
  }

  /// Toggle suppression for a device.
  func toggleSuppression(for deviceIdentifier: String) {
    guard let index = monitoredDevices.firstIndex(where: { $0.deviceIdentifier == deviceIdentifier })
    else { return }

    monitoredDevices[index].isSuppressed.toggle()
    saveDevices()

    if monitoredDevices[index].isSuppressed {
      cancelNotification(for: monitoredDevices[index])
    } else if heartbeatNotificationsEnabled {
      scheduleNotification(for: monitoredDevices[index])
    }
  }

  // MARK: - Notification Management

  func scheduleNotifications() {
    for device in monitoredDevices where !device.isSuppressed {
      scheduleNotification(for: device)
    }
  }

  func cancelAllNotifications() {
    let ids = monitoredDevices.compactMap { $0.notificationIdentifier }
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
  }

  private func scheduleNotification(for device: MonitoredDevice) {
    cancelNotification(for: device)

    let notificationId = "heartbeat-\(device.deviceIdentifier)"
    let content = UNMutableNotificationContent()
    content.sound = .default

    let triggerDate: Date

    if device.isAuthRevoked {
      // Auth revoked — fire near-immediately
      content.title = "Screen Time Permissions Lost"
      content.body =
        "\(device.deviceName) has lost Screen Time permissions. Tap to review."
      triggerDate = Date().addingTimeInterval(1)
    } else {
      // Normal staleness countdown
      content.title = "Device Check-In"
      content.body =
        "We haven't heard from \(device.deviceName) in a while. Tap to check their status."
      triggerDate = device.lastSeenAt.addingTimeInterval(MonitoredDevice.stalenessThreshold)
    }

    // Don't schedule if trigger is in the past (device already stale — banner handles it)
    guard triggerDate > Date() else { return }

    let interval = triggerDate.timeIntervalSinceNow
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(interval, 1), repeats: false)
    let request = UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger)

    UNUserNotificationCenter.current().add(request) { error in
      if let error {
        Log.warning("Failed to schedule heartbeat notification: \(error)", category: .cloudKit)
      }
    }

    // Update device with notification ID
    if let index = monitoredDevices.firstIndex(where: {
      $0.deviceIdentifier == device.deviceIdentifier
    }) {
      monitoredDevices[index].notificationIdentifier = notificationId
      saveDevices()
    }
  }

  private func cancelNotification(for device: MonitoredDevice) {
    if let id = device.notificationIdentifier {
      UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
  }

  // MARK: - Private Helpers

  private func updateOrCreateDevice(from heartbeat: DeviceHeartbeat) {
    if let index = monitoredDevices.firstIndex(where: {
      $0.deviceIdentifier == heartbeat.deviceIdentifier
    }) {
      monitoredDevices[index].lastSeenAt = heartbeat.lastHeartbeatAt
      monitoredDevices[index].deviceName = heartbeat.deviceName
      monitoredDevices[index].authorizationStatus = heartbeat.authorizationStatus
    } else {
      let device = MonitoredDevice(
        deviceIdentifier: heartbeat.deviceIdentifier,
        deviceName: heartbeat.deviceName,
        childUserRecordName: heartbeat.childUserRecordName,
        lastSeenAt: heartbeat.lastHeartbeatAt,
        isSuppressed: false,
        notificationIdentifier: nil,
        authorizationStatus: heartbeat.authorizationStatus
      )
      monitoredDevices.append(device)
    }
  }

  private func saveDevices() {
    if let data = try? JSONEncoder().encode(monitoredDevices) {
      UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }
  }

  private static func loadDevices() -> [MonitoredDevice] {
    guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
      let devices = try? JSONDecoder().decode([MonitoredDevice].self, from: data)
    else {
      return []
    }
    return devices
  }
}
