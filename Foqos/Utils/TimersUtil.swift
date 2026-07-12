import BackgroundTasks
import Foundation
@preconcurrency import UserNotifications

// MARK: - Notification Constants

extension Notification.Name {
  fileprivate static let backgroundTaskExecuted = Notification.Name(
    "BackgroundTaskExecuted"
  )
}

/// Represents the result of a notification request
enum NotificationResult: Sendable {
  case success
  case failure(String?)

  var succeeded: Bool {
    if case .success = self {
      return true
    }
    return false
  }
}

protocol TimersUtilScheduling: AnyObject {
  @discardableResult
  func scheduleNotification(
    title: String,
    message: String,
    seconds: TimeInterval,
    identifier: String?,
    threadIdentifier: String?,
    completion: @escaping @Sendable (NotificationResult) -> Void
  ) -> String

  func cancelAll()
  func cancelAllNotifications()
  func cancelAllBackgroundTasks()
}

extension TimersUtilScheduling {
  @discardableResult
  func scheduleNotification(
    title: String,
    message: String,
    seconds: TimeInterval,
    identifier: String? = nil,
    threadIdentifier: String? = nil,
    completion: @escaping @Sendable (NotificationResult) -> Void = { _ in }
  ) -> String {
    scheduleNotification(
      title: title,
      message: message,
      seconds: seconds,
      identifier: identifier,
      threadIdentifier: threadIdentifier,
      completion: completion)
  }
}

final class TimersUtil: TimersUtilScheduling, @unchecked Sendable {  // SAFETY: Mutable state (backgroundTasks) uses thread-safe UserDefaults
  /// Constants for background task identifiers
  static let backgroundProcessingTaskIdentifier =
    "com.cynexia.family-foqos.backgroundprocessing"
  static let backgroundTaskUserDefaultsKey = "family_foqos_background_tasks"
  static let ownedReminderIdentifiersUserDefaultsKey = "family_foqos_owned_reminder_identifiers"

  /// Pre-activation reminder notification identifier prefix
  static let preActivationReminderPrefix = "pre-activation-reminder-"

  /// Stable identifiers for session and break reminders, which are owned by session lifecycle.
  static let sessionReminderPrefix = "session-reminder-"
  static let breakReminderPrefix = "break-reminder-"

  static func sessionReminderIdentifier(for profileId: UUID) -> String {
    return "\(sessionReminderPrefix)\(profileId.uuidString)"
  }

  static func breakReminderIdentifier(for profileId: UUID) -> String {
    return "\(breakReminderPrefix)\(profileId.uuidString)"
  }

  static func isSessionOrBreakReminder(_ identifier: String) -> Bool {
    return identifier.hasPrefix(sessionReminderPrefix) || identifier.hasPrefix(breakReminderPrefix)
  }

  private let ownedReminderIdentifiersLock = NSLock()
  private var ownedReminderScheduleGenerations: [String: UInt] = [:]

  // Internal for focused tests; ownership must survive utility recreation.
  var ownedReminderIdentifiersForTesting: Set<String> {
    ownedReminderIdentifiersLock.lock()
    defer { ownedReminderIdentifiersLock.unlock() }
    return ownedReminderIdentifiers
  }

  // Internal for focused tests; cancellation must invalidate in-flight owned schedules.
  func ownedReminderScheduleGenerationForTesting(_ identifier: String) -> UInt? {
    ownedReminderIdentifiersLock.lock()
    defer { ownedReminderIdentifiersLock.unlock() }
    return ownedReminderScheduleGenerations[identifier]
  }

  // Internal for focused tests; mirrors the authorization and add callback validity check.
  func isOwnedReminderScheduleCurrentForTesting(_ identifier: String, generation: UInt) -> Bool {
    ownedReminderIdentifiersLock.lock()
    defer { ownedReminderIdentifiersLock.unlock() }
    return isOwnedReminderScheduleCurrent(identifier, generation: generation)
  }

  private var ownedReminderIdentifiers: Set<String> {
    get {
      Set(
        UserDefaults.standard.stringArray(forKey: Self.ownedReminderIdentifiersUserDefaultsKey)
          ?? [])
    }
    set {
      UserDefaults.standard.set(
        Array(newValue), forKey: Self.ownedReminderIdentifiersUserDefaultsKey)
    }
  }

  private func beginOwnedReminderSchedule(_ identifier: String) -> UInt {
    ownedReminderIdentifiersLock.lock()
    defer { ownedReminderIdentifiersLock.unlock() }

    var identifiers = ownedReminderIdentifiers
    identifiers.insert(identifier)
    ownedReminderIdentifiers = identifiers

    let generation = (ownedReminderScheduleGenerations[identifier] ?? 0) &+ 1
    ownedReminderScheduleGenerations[identifier] = generation
    return generation
  }

  private func isOwnedReminderScheduleCurrent(_ identifier: String, generation: UInt) -> Bool {
    ownedReminderIdentifiers.contains(identifier)
      && ownedReminderScheduleGenerations[identifier] == generation
  }

  /// Thread identifier for grouping pre-activation reminders per profile
  static func preActivationReminderThreadIdentifier(for profileId: UUID) -> String {
    return "\(preActivationReminderPrefix)\(profileId.uuidString)"
  }

  /// Extract profile UUID from a pre-activation reminder notification identifier.
  /// Returns nil if the identifier doesn't match the expected format.
  static func profileIdFromReminderIdentifier(_ identifier: String) -> UUID? {
    guard identifier.hasPrefix(preActivationReminderPrefix) else { return nil }
    let remainder = String(identifier.dropFirst(preActivationReminderPrefix.count))
    // Format: "UUID-minutes" — UUID is 36 chars, then "-", then digits
    guard remainder.count > 36 else { return nil }
    let uuidString = String(remainder.prefix(36))
    return UUID(uuidString: uuidString)
  }

  static func preActivationReminderIdentifier(for profileId: UUID, minutes: Int) -> String {
    return "\(preActivationReminderPrefix)\(profileId.uuidString)-\(minutes)"
  }

  /// Supported pre-activation reminder options (minutes before scheduled start)
  static let supportedReminderOptions: [UInt8] = [1, 3, 5]

  /// Superset range covering all reminder minute values ever shipped, used to clean up
  /// stale notifications when the supported options change between releases.
  static let allReminderCleanupRange = ScheduleTimerActivity.allReminderCleanupRange

  static func allPreActivationReminderIdentifiers(for profileId: UUID) -> [String] {
    // Always cancel identifiers for full cleanup range (not just current options) to clean up stale reminders
    allReminderCleanupRange.map { preActivationReminderIdentifier(for: profileId, minutes: $0) }
  }

  static func cancelAllPreActivationReminders(for profileId: UUID) {
    let identifiers = allPreActivationReminderIdentifiers(for: profileId)
    UNUserNotificationCenter.current().removePendingNotificationRequests(
      withIdentifiers: identifiers
    )
    UNUserNotificationCenter.current().removeDeliveredNotifications(
      withIdentifiers: identifiers
    )

    // Also remove stored background task metadata for these notifications
    let identifierSet = Set(identifiers)
    var storedTasks =
      UserDefaults.standard.dictionary(
        forKey: Self.backgroundTaskUserDefaultsKey
      ) as? [String: [String: Any]] ?? [:]
    let originalCount = storedTasks.count
    storedTasks = storedTasks.filter { (_, value) in
      guard let notificationId = value["notificationId"] as? String else { return true }
      return !identifierSet.contains(notificationId)
    }
    if storedTasks.count != originalCount {
      UserDefaults.standard.set(storedTasks, forKey: Self.backgroundTaskUserDefaultsKey)
    }
  }

  private var backgroundTasks: [String: [String: Any]] {
    get {
      UserDefaults.standard.dictionary(
        forKey: Self.backgroundTaskUserDefaultsKey
      )
        as? [String: [String: Any]] ?? [:]
    }
    set {
      UserDefaults.standard.set(
        newValue,
        forKey: Self.backgroundTaskUserDefaultsKey
      )
    }
  }

  /// Register background tasks with the system - call this in app launch
  static func registerBackgroundTasks() {
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: backgroundProcessingTaskIdentifier,
      using: nil
    ) { task in
      guard let processingTask = task as? BGProcessingTask else {
        task.setTaskCompleted(success: false)
        return
      }
      Self.handleBackgroundProcessingTask(processingTask)
    }
  }

  private static func handleBackgroundProcessingTask(_ task: BGProcessingTask) {
    let timerUtil = TimersUtil()

    // Get all pending tasks from UserDefaults
    let tasks = timerUtil.backgroundTasks
    var completedTaskIds: [String] = []
    var hasExecutedTasks = false

    for (taskId, taskInfo) in tasks {
      if let executionTime = taskInfo["executionTime"] as? Date,
        executionTime <= Date()
      {
        // Task is due for execution
        if let notificationId = taskInfo["notificationId"] as? String {
          // This was a notification task, we can cancel it as the system will handle it
          timerUtil.cancelNotification(identifier: notificationId)
        }

        // Execute any custom code via notification callback
        NotificationCenter.default.post(
          name: .backgroundTaskExecuted,
          object: nil,
          userInfo: ["taskId": taskId]
        )

        completedTaskIds.append(taskId)
        hasExecutedTasks = true
      }
    }

    // Remove completed tasks
    var updatedTasks = tasks
    for taskId in completedTaskIds {
      updatedTasks.removeValue(forKey: taskId)
    }
    timerUtil.backgroundTasks = updatedTasks

    // Schedule next background task if needed
    if !updatedTasks.isEmpty {
      timerUtil.scheduleBackgroundProcessing()
    }

    task.setTaskCompleted(success: hasExecutedTasks)
  }

  /// Schedule a background processing task
  func scheduleBackgroundProcessing() {
    let request = BGProcessingTaskRequest(
      identifier: Self.backgroundProcessingTaskIdentifier
    )
    request.requiresNetworkConnectivity = false
    request.requiresExternalPower = false

    // Find the earliest task execution time
    var earliestDate: Date?
    for (_, taskInfo) in backgroundTasks {
      if let executionTime = taskInfo["executionTime"] as? Date {
        if earliestDate == nil || executionTime < earliestDate! {
          earliestDate = executionTime
        }
      }
    }

    // Set the earliest start date if there's a pending task
    if let earliestDate = earliestDate {
      request.earliestBeginDate = earliestDate

      do {
        try BGTaskScheduler.shared.submit(request)
      } catch {
        Log.info("Could not schedule background task: \(error)", category: .timer)
      }
    }
  }

  /// Cancel a specific background task
  func cancelBackgroundTask(taskId: String) {
    var tasks = backgroundTasks
    tasks.removeValue(forKey: taskId)
    backgroundTasks = tasks
  }

  /// Cancel all background tasks
  func cancelAllBackgroundTasks() {
    backgroundTasks = [:]
    BGTaskScheduler.shared.cancel(
      taskRequestWithIdentifier: Self.backgroundProcessingTaskIdentifier
    )
  }

  @discardableResult
  func scheduleNotification(
    title: String,
    message: String,
    seconds: TimeInterval,
    identifier: String? = nil,
    threadIdentifier: String? = nil,
    completion: @escaping @Sendable (NotificationResult) -> Void = { _ in }
  ) -> String {
    let notificationId = identifier ?? UUID().uuidString
    let ownedReminderScheduleGeneration =
      Self.isSessionOrBreakReminder(notificationId)
      ? beginOwnedReminderSchedule(notificationId)
      : nil

    // Request authorization before scheduling
    requestNotificationAuthorization { [weak self] result in
      switch result {
      case .failure(let errorMessage):
        completion(.failure(errorMessage))
        return
      case .success:
        // Proceed with scheduling the notification
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default
        if let threadIdentifier {
          content.threadIdentifier = threadIdentifier
        }

        let trigger = UNTimeIntervalNotificationTrigger(
          timeInterval: seconds,
          repeats: false
        )
        let request = UNNotificationRequest(
          identifier: notificationId,
          content: content,
          trigger: trigger
        )

        let center = UNUserNotificationCenter.current()
        if let ownedReminderScheduleGeneration {
          self?.ownedReminderIdentifiersLock.lock()
          guard
            self?.isOwnedReminderScheduleCurrent(
              notificationId, generation: ownedReminderScheduleGeneration) == true
          else {
            self?.ownedReminderIdentifiersLock.unlock()
            return
          }
          center.add(request) { [weak self] error in
            if let error = error {
              Log.info(
                "Error scheduling notification: \(error.localizedDescription)", category: .timer)
              completion(.failure(error.localizedDescription))
            } else {
              guard
                self?.isOwnedReminderScheduleCurrentForCallback(
                  notificationId, generation: ownedReminderScheduleGeneration) == true
              else {
                return
              }
              self?.scheduleBackgroundTask(
                taskId: UUID().uuidString,
                executionTime: Date().addingTimeInterval(seconds),
                notificationId: notificationId
              )
              completion(.success)
            }
          }
          self?.ownedReminderIdentifiersLock.unlock()
          return
        }

        center.add(request) { [weak self] error in
          if let error = error {
            Log.info(
              "Error scheduling notification: \(error.localizedDescription)", category: .timer)
            completion(.failure(error.localizedDescription))
          } else {
            // Also schedule as background task for resilience when app is killed
            let taskId = UUID().uuidString
            self?.scheduleBackgroundTask(
              taskId: taskId,
              executionTime: Date().addingTimeInterval(seconds),
              notificationId: notificationId
            )
            completion(.success)
          }
        }
      }
    }

    return notificationId
  }

  func cancelNotification(identifier: String) {
    UNUserNotificationCenter.current().removePendingNotificationRequests(
      withIdentifiers: [identifier]
    )
    UNUserNotificationCenter.current().removeDeliveredNotifications(
      withIdentifiers: [identifier]
    )
  }

  func cancelAllNotifications() {
    ownedReminderIdentifiersLock.lock()
    let identifiers = Array(ownedReminderIdentifiers)
    ownedReminderIdentifiers = []
    for identifier in identifiers {
      ownedReminderScheduleGenerations[identifier] =
        (ownedReminderScheduleGenerations[identifier] ?? 0) &+ 1
    }
    ownedReminderIdentifiersLock.unlock()

    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
    center.removeDeliveredNotifications(withIdentifiers: identifiers)

    // Delivered pre-activation cleanup remains async and does not affect pending ownership.
    center.getDeliveredNotifications { notifications in
      let preActivationIds = notifications.map(\.request.identifier).filter {
        $0.hasPrefix(Self.preActivationReminderPrefix)
      }
      if !preActivationIds.isEmpty {
        center.removeDeliveredNotifications(withIdentifiers: preActivationIds)
      }
    }
  }

  private func isOwnedReminderScheduleCurrentForCallback(
    _ identifier: String,
    generation: UInt
  ) -> Bool {
    ownedReminderIdentifiersLock.lock()
    defer { ownedReminderIdentifiersLock.unlock() }
    return isOwnedReminderScheduleCurrent(identifier, generation: generation)
  }

  func cancelAll() {
    cancelAllNotifications()
    cancelAllBackgroundTasks()
  }

  /// Schedule a background task
  private func scheduleBackgroundTask(
    taskId: String,
    executionTime: Date,
    notificationId: String? = nil
  ) {
    // Store task information in UserDefaults
    var tasks = backgroundTasks
    var taskInfo: [String: Any] = ["executionTime": executionTime]
    if let notificationId = notificationId {
      taskInfo["notificationId"] = notificationId
    }
    tasks[taskId] = taskInfo
    backgroundTasks = tasks

    // Schedule the background processing task
    scheduleBackgroundProcessing()
  }

  /// Request authorization to send notifications
  private func requestNotificationAuthorization(
    completion: @escaping @Sendable (NotificationResult) -> Void = { _ in }
  ) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
      if let error = error {
        Log.info(
          "Error requesting notification authorization: \(error.localizedDescription)",
          category: .timer)
        completion(.failure(error.localizedDescription))
        return
      }

      if granted {
        completion(.success)
      } else {
        completion(.failure(nil))
      }
    }
  }
}
