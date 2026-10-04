import StoreKit
import SwiftUI

@MainActor
final class RatingManager {
  static let shared = RatingManager()

  private let defaults: UserDefaults
  private let calendar: Calendar
  private let currentVersion: String
  private let requestReview: @MainActor () -> Bool
  private let daysKey = "family_foqos_successful_session_days"
  private let versionKey = "family_foqos_last_version_prompted_for_review"

  init(
    defaults: UserDefaults = .standard,
    calendar: Calendar = .current,
    currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
    requestReview: @escaping @MainActor () -> Bool = RatingManager.requestReviewInActiveScene
  ) {
    self.defaults = defaults
    self.calendar = calendar
    self.currentVersion = currentVersion
    self.requestReview = requestReview
  }

  /// Only newly confirmed normal completions contribute; old tap counts and historical
  /// sessions cannot distinguish successful stops from failures or Emergency Unblock.
  func recordSuccessfulSessionEnd(now: Date) {
    let components = calendar.dateComponents([.era, .year, .month, .day], from: now)
    let day = "\(components.era ?? 0)-\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    var days = Set(defaults.stringArray(forKey: daysKey) ?? [])
    if days.count < 3 {
      days.insert(day)
      defaults.set(Array(days), forKey: daysKey)
    }
    // Three distinct completion days imply at least three completed sessions.
    guard days.count >= 3, !currentVersion.isEmpty,
      defaults.string(forKey: versionKey) != currentVersion,
      requestReview()
    else { return }
    defaults.set(currentVersion, forKey: versionKey)
  }

  private static func requestReviewInActiveScene() -> Bool {
    guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
      return false
    }
    AppStore.requestReview(in: scene)
    return true
  }
}
