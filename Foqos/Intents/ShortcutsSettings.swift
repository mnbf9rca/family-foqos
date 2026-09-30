import AppIntents
import Foundation

enum ShortcutsSettings {
  static let requireDeviceUnlockKey = "family_foqos_shortcuts_require_device_unlock"

  static func requiresDeviceUnlock(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: requireDeviceUnlockKey) as? Bool ?? true
  }

  static var authenticationPolicy: IntentAuthenticationPolicy {
    requiresDeviceUnlock() ? .requiresLocalDeviceAuthentication : .alwaysAllowed
  }
}
