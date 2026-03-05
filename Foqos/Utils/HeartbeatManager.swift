import FamilyControls
import Foundation
import UIKit

/// Manages device heartbeat lifecycle for both child and parent modes.
@MainActor
class HeartbeatManager: ObservableObject {
  static let shared = HeartbeatManager()

  private let userDefaultsKey = "family_foqos_monitored_devices"
  private let notificationEnabledKey = "family_foqos_heartbeat_notifications_enabled"

  @Published var monitoredDevices: [MonitoredDevice] = []

  @Published var heartbeatNotificationsEnabled: Bool {
    didSet {
      UserDefaults.standard.set(heartbeatNotificationsEnabled, forKey: notificationEnabledKey)
    }
  }

  private init() {
    self.heartbeatNotificationsEnabled = UserDefaults.standard.bool(
      forKey: notificationEnabledKey)
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
    do {
      let heartbeats = try await CloudKitManager.shared.fetchHeartbeats()

      for heartbeat in heartbeats {
        updateOrCreateDevice(from: heartbeat)
      }
      saveDevices()

      if heartbeatNotificationsEnabled {
        scheduleNotifications()
      }
    } catch {
      Log.warning("Failed to refresh heartbeats: \(error)", category: .cloudKit)
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
    content.title = "Device Check-In"
    content.body =
      "We haven't heard from \(device.deviceName) in a while. Tap to check their status."

    let triggerDate = device.lastSeenAt.addingTimeInterval(MonitoredDevice.stalenessThreshold)

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
    } else {
      let device = MonitoredDevice(
        deviceIdentifier: heartbeat.deviceIdentifier,
        deviceName: heartbeat.deviceName,
        childUserRecordName: heartbeat.childUserRecordName,
        lastSeenAt: heartbeat.lastHeartbeatAt,
        isSuppressed: false,
        notificationIdentifier: nil
      )
      monitoredDevices.append(device)
    }
  }

  private func saveDevices() {
    if let data = try? JSONEncoder().encode(monitoredDevices) {
      UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
  }

  private static func loadDevices() -> [MonitoredDevice] {
    guard let data = UserDefaults.standard.data(forKey: "family_foqos_monitored_devices"),
      let devices = try? JSONDecoder().decode([MonitoredDevice].self, from: data)
    else {
      return []
    }
    return devices
  }
}
