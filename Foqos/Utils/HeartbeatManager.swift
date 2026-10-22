import FamilyControls
import Foundation
import UIKit
@preconcurrency import UserNotifications

@MainActor
protocol HeartbeatNotificationScheduling {
  func requestAuthorization(
    options: UNAuthorizationOptions,
    completionHandler: @MainActor @Sendable @escaping (Bool, Error?) -> Void
  )
  func add(
    _ request: UNNotificationRequest,
    completionHandler: @MainActor @Sendable @escaping (Error?) -> Void
  )
  func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

@MainActor
final class UserNotificationCenterScheduler: HeartbeatNotificationScheduling {
  private let notificationCenter: UNUserNotificationCenter

  init(notificationCenter: UNUserNotificationCenter = .current()) {
    self.notificationCenter = notificationCenter
  }

  func requestAuthorization(
    options: UNAuthorizationOptions,
    completionHandler: @MainActor @Sendable @escaping (Bool, Error?) -> Void
  ) {
    notificationCenter.requestAuthorization(options: options) { granted, error in
      let callbackError = error as NSError?
      Task { @MainActor in
        completionHandler(granted, callbackError)
      }
    }
  }

  func add(
    _ request: UNNotificationRequest,
    completionHandler: @MainActor @Sendable @escaping (Error?) -> Void
  ) {
    notificationCenter.add(request) { error in
      let callbackError = error as NSError?
      Task { @MainActor in
        completionHandler(callbackError)
      }
    }
  }

  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
    notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
  }
}

/// Manages device heartbeat lifecycle for both child and parent modes.
@MainActor
class HeartbeatManager: ObservableObject {
  static let shared = HeartbeatManager()

  private static let userDefaultsKey = "family_foqos_monitored_devices"
  private static let notificationEnabledKey = "family_foqos_heartbeat_notifications_enabled"

  private let defaults: UserDefaults
  private let notificationScheduler: HeartbeatNotificationScheduling
  private let userRecordName: () -> String?
  private let authorizationStatus: () -> AuthorizationStatus
  private let saveHeartbeat: (DeviceHeartbeat) async throws -> Void
  private var lastSuccessfulForegroundHeartbeat: DeviceHeartbeat?
  private var foregroundHeartbeatTask: Task<Void, Never>?
  private var authRevokedNotificationDeviceIdsInFlight = Set<String>()

  @Published var monitoredDevices: [MonitoredDevice] = []

  @Published var heartbeatNotificationsEnabled: Bool {
    didSet {
      defaults.set(heartbeatNotificationsEnabled, forKey: Self.notificationEnabledKey)
      if heartbeatNotificationsEnabled {
        notificationScheduler.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        scheduleNotifications()
      } else {
        cancelAllNotifications()
      }
    }
  }

  init(
    defaults: UserDefaults = .standard,
    notificationScheduler: HeartbeatNotificationScheduling = UserNotificationCenterScheduler(),
    userRecordName: @escaping () -> String? = {
      CloudKitManager.shared.currentUserRecordID?.recordName
    },
    authorizationStatus: @escaping () -> AuthorizationStatus = {
      AuthorizationCenter.shared.authorizationStatus
    },
    saveHeartbeat: @escaping (DeviceHeartbeat) async throws -> Void = {
      try await CloudKitManager.shared.writeHeartbeat($0)
    }
  ) {
    self.defaults = defaults
    self.notificationScheduler = notificationScheduler
    self.userRecordName = userRecordName
    self.authorizationStatus = authorizationStatus
    self.saveHeartbeat = saveHeartbeat
    self.heartbeatNotificationsEnabled = defaults.bool(forKey: Self.notificationEnabledKey)
    self.monitoredDevices = Self.loadDevices(defaults: defaults)
  }

  // MARK: - Child Side

  /// Write heartbeat to CloudKit. Fire-and-forget — must not block profile activation.
  func writeHeartbeat() {
    guard let heartbeat = makeHeartbeat(now: Date()) else { return }
    Task { await sendHeartbeat(heartbeat) }
  }

  func writeHeartbeatOnForeground(
    now: () -> Date = Date.init, isReady: () -> Bool
  ) async {
    guard isReady() else { return }
    while let pending = foregroundHeartbeatTask {
      await pending.value
    }
    guard isReady() else { return }
    let now = now()
    guard let heartbeat = makeHeartbeat(now: now) else { return }

    if let previous = lastSuccessfulForegroundHeartbeat,
      previous.childUserRecordName == heartbeat.childUserRecordName,
      previous.authorizationStatus == heartbeat.authorizationStatus,
      now.timeIntervalSince(previous.lastHeartbeatAt) >= 0,
      now.timeIntervalSince(previous.lastHeartbeatAt) < 15 * 60
    {
      return
    }

    let task = Task {
      defer { foregroundHeartbeatTask = nil }
      if await sendHeartbeat(heartbeat) {
        lastSuccessfulForegroundHeartbeat = heartbeat
      }
    }
    foregroundHeartbeatTask = task
    await task.value
  }

  private func makeHeartbeat(now: Date) -> DeviceHeartbeat? {
    guard !ScreenshotDemoMode.isActive else { return nil }
    let authStatus = authorizationStatus()
    let statusString: String
    switch authStatus {
    case .approved, .approvedWithDataAccess: statusString = "approved"
    case .denied: statusString = "denied"
    case .notDetermined: statusString = "notDetermined"
    @unknown default: statusString = "unknown"
    }

    guard let userRecordName = userRecordName() else {
      Log.warning("No user record ID available for heartbeat", category: .cloudKit)
      return nil
    }

    return DeviceHeartbeat(
      childUserRecordName: userRecordName,
      deviceIdentifier: UIDevice.current.identifierForVendor?.uuidString ?? "unknown",
      deviceName: UIDevice.current.name,
      lastHeartbeatAt: now,
      authorizationStatus: statusString
    )
  }

  private func sendHeartbeat(_ heartbeat: DeviceHeartbeat) async -> Bool {
    do {
      try await saveHeartbeat(heartbeat)
      return true
    } catch {
      Log.warning("Heartbeat write failed (non-blocking): \(redactedErrorForLog(error))", category: .cloudKit)
      return false
    }
  }

  // MARK: - Parent Side

  /// Fetch heartbeats from CloudKit and update local monitored devices.
  func refreshHeartbeats() async {
    guard !ScreenshotDemoMode.isActive else { return }
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
    monitoredDevices.removeAll { $0.id == device.id }
    saveDevices()

    do {
      try await CloudKitManager.shared.deleteHeartbeat(
        childUserRecordName: device.childUserRecordName,
        deviceIdentifier: device.deviceIdentifier
      )
    } catch {
      Log.warning("Failed to delete heartbeat record: \(redactedErrorForLog(error))", category: .cloudKit)
    }
  }

  /// Toggle suppression for a device.
  func toggleSuppression(for deviceId: String) {
    guard let index = monitoredDevices.firstIndex(where: { $0.id == deviceId })
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
    notificationScheduler.removePendingNotificationRequests(withIdentifiers: ids)
  }

  private func scheduleNotification(for device: MonitoredDevice) {
    let notificationId = "heartbeat-\(device.id)"
    let content = UNMutableNotificationContent()
    content.sound = .default

    let triggerDate: Date
    let now = Date()
    var markAuthRevokedNotified = false

    if device.isAuthRevoked {
      guard device.shouldScheduleAuthRevokedAlert() else { return }
      guard !authRevokedNotificationDeviceIdsInFlight.contains(device.id) else { return }
      authRevokedNotificationDeviceIdsInFlight.insert(device.id)
      cancelNotification(for: device)

      content.title = "Screen Time Permissions Lost"
      content.body =
        "\(device.deviceName) has lost Screen Time permissions. Tap to review."
      triggerDate = now.addingTimeInterval(1)
      markAuthRevokedNotified = true
    } else {
      cancelNotification(for: device)

      // Normal staleness countdown
      content.title = "Device Check-In"
      content.body =
        "We haven't heard from \(device.deviceName) in a while. Tap to check their status."
      triggerDate = device.lastSeenAt.addingTimeInterval(MonitoredDevice.stalenessThreshold)
    }

    // Don't schedule if trigger is in the past (device already stale — banner handles it)
    guard triggerDate > now else {
      if markAuthRevokedNotified {
        authRevokedNotificationDeviceIdsInFlight.remove(device.id)
      }
      return
    }

    let interval = triggerDate.timeIntervalSinceNow
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(interval, 1), repeats: false)
    let request = UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger)

    notificationScheduler.add(request) { [weak self] error in
      guard let self else { return }
      if markAuthRevokedNotified {
        self.authRevokedNotificationDeviceIdsInFlight.remove(device.id)
      }
      if let error {
        Log.warning("Failed to schedule heartbeat notification: \(redactedErrorForLog(error))", category: .cloudKit)
        return
      }

      if let index = self.monitoredDevices.firstIndex(where: { $0.id == device.id }) {
        self.monitoredDevices[index].notificationIdentifier = notificationId
        if markAuthRevokedNotified {
          self.monitoredDevices[index].authRevokedNotifiedAt = now
        }
        self.saveDevices()
      }
    }
  }

  private func cancelNotification(for device: MonitoredDevice) {
    if let id = device.notificationIdentifier {
      notificationScheduler.removePendingNotificationRequests(withIdentifiers: [id])
    }
  }

  // MARK: - Private Helpers

  private func updateOrCreateDevice(from heartbeat: DeviceHeartbeat) {
    if let index = monitoredDevices.firstIndex(where: {
      $0.childUserRecordName == heartbeat.childUserRecordName
        && $0.deviceIdentifier == heartbeat.deviceIdentifier
    }) {
      monitoredDevices[index].lastSeenAt = heartbeat.lastHeartbeatAt
      monitoredDevices[index].deviceName = heartbeat.deviceName
      monitoredDevices[index].authRevokedNotifiedAt = MonitoredDevice.carriedAuthRevokedNotifiedAt(
        previous: monitoredDevices[index].authRevokedNotifiedAt,
        newStatus: heartbeat.authorizationStatus)
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
      defaults.set(data, forKey: Self.userDefaultsKey)
    }
  }

  private static func loadDevices(defaults: UserDefaults) -> [MonitoredDevice] {
    guard let data = defaults.data(forKey: userDefaultsKey),
      let devices = try? JSONDecoder().decode([MonitoredDevice].self, from: data)
    else {
      return []
    }
    return devices
  }
}
