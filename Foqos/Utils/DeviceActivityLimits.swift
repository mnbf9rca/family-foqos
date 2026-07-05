import Foundation

/// Hard limits imposed by Apple's DeviceActivity framework on the repeating
/// intervals we register via `DeviceActivityCenter.startMonitoring`.
///
/// DeviceActivity silently rejects (throws from `startMonitoring`, which this
/// codebase currently only logs) any monitored interval shorter than 15
/// minutes, and a 24-hour (1440-minute) now-relative timer collapses to a
/// zero-length interval because its end wraps to the same wall-clock minute as
/// its start. These constants are the single source of truth for the C1
/// interval-validation guards (#212, #228).
enum DeviceActivityLimits {
  /// DeviceActivity's minimum honorable monitored interval length, in minutes.
  static let minimumIntervalMinutes = 15

  /// Maximum now-relative timer duration, in minutes (23h59m). Exactly 1440
  /// (24h), or any larger multiple, makes `intervalStart == intervalEnd`.
  static let maximumTimerMinutes = 1439

  /// Human-readable form of `maximumTimerMinutes` for user-facing copy, derived
  /// from the constant so it can never drift out of sync (e.g. "23 hours 59
  /// minutes").
  static var maximumTimerDescription: String {
    let hours = maximumTimerMinutes / 60
    let minutes = maximumTimerMinutes % 60
    return "\(hours) hours \(minutes) minutes"
  }
}
