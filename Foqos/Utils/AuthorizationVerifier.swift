import FamilyControls
import Foundation

/// Centralized service for verifying Apple Family Sharing authorization.
/// Used to ensure children accepting CloudKit shares are actually set up as
/// children in Apple Family Sharing (not just adults pretending to be children).
///
/// This class provides a single entry point for authorization verification and
/// handles all authorization loss scenarios consistently.
@MainActor
class AuthorizationVerifier: ObservableObject {
  static let shared = AuthorizationVerifier()

  /// Keys for persisting authorization state
  private enum Keys {
    static let authorizationType = "family_foqos_authorization_type"
    static let authorizationVerifiedAt = "family_foqos_authorization_verified_at"
  }

  /// Authorization type granted to this device
  enum AuthorizationType: String {
    case individual
    case child
    case none
  }

  /// Result of a child authorization verification attempt
  enum VerificationResult {
    case authorized
    case notChildDevice
    case notAuthorized
    case networkError(Error)
    case unknownError(Error)

    var isAuthorized: Bool {
      if case .authorized = self {
        return true
      }
      return false
    }

    var errorMessage: String? {
      switch self {
      case .authorized:
        return nil
      case .notChildDevice:
        return
          "This device must be set up as a child in Apple Family Sharing to accept this invitation. Please ask a parent to add this Apple ID as a child in Settings > Family, then enable Screen Time for this child."
      case .notAuthorized:
        return
          "Screen Time authorization is required. Please enable Screen Time in Settings and try again."
      case .networkError:
        return
          "Unable to verify authorization. Please check your internet connection and try again."
      case .unknownError(let error):
        return "Authorization failed: \(error.localizedDescription)"
      }
    }
  }

  @Published private(set) var lastVerificationDate: Date?
  @Published private(set) var currentAuthorizationType: AuthorizationType = .none

  private let userDefaults = UserDefaults.standard

  private init() {
    loadPersistedState()
  }

  // MARK: - Persistence

  private func loadPersistedState() {
    if let typeString = userDefaults.string(forKey: Keys.authorizationType),
      let authType = AuthorizationType(rawValue: typeString)
    {
      currentAuthorizationType = authType
    }
    lastVerificationDate = userDefaults.object(forKey: Keys.authorizationVerifiedAt) as? Date
  }

  private func persistAuthorizationType(_ type: AuthorizationType) {
    userDefaults.set(type.rawValue, forKey: Keys.authorizationType)
    let now = Date()
    userDefaults.set(now, forKey: Keys.authorizationVerifiedAt)
    currentAuthorizationType = type
    lastVerificationDate = now
  }

  // MARK: - Primary Verification API

  /// Verify child authorization and return detailed result.
  /// This is the primary method for checking authorization status.
  func verifyChildAuthorization() async -> VerificationResult {
    do {
      try await AuthorizationCenter.shared.requestAuthorization(for: .child)
      persistAuthorizationType(.child)
      Log.info("Child authorization successful", category: .authorization)
      return .authorized
    } catch let error as NSError {
      Log.info("AuthorizationVerifier: Child authorization failed - domain: \(error.domain), code: \(error.code)", category: .authorization)

      // FamilyControls errors indicating this isn't a child device
      if error.domain == "FamilyControls" || error.domain == "com.apple.FamilyControls" {
        return .notChildDevice
      }

      // Check for network-related errors
      if error.domain == NSURLErrorDomain {
        return .networkError(error)
      }

      // Generic authorization failure
      return .unknownError(error)
    }
  }

  /// Request .individual authorization.
  /// Returns true if successful.
  func requestIndividualAuthorization() async -> Bool {
    do {
      try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
      persistAuthorizationType(.individual)
      Log.info("Individual authorization successful", category: .authorization)
      return true
    } catch {
      Log.info("Individual authorization failed - \(error)", category: .authorization)
      return false
    }
  }

  /// Clear the persisted authorization state (called when leaving family share)
  func clearAuthorizationState() {
    userDefaults.removeObject(forKey: Keys.authorizationType)
    userDefaults.removeObject(forKey: Keys.authorizationVerifiedAt)
    currentAuthorizationType = .none
    lastVerificationDate = nil
  }

  // MARK: - Centralized Authorization Loss Handling

  /// Handle authorization loss for a child device.
  /// This is the single entry point for all authorization loss scenarios.
  /// Clears shared state, switches to individual mode, and returns a user message.
  func handleAuthorizationLoss() async -> String {
    let cloudKitManager = CloudKitManager.shared
    let appModeManager = AppModeManager.shared

    Log.info("Handling authorization loss", category: .authorization)

    // Clear CloudKit shared state first
    cloudKitManager.clearSharedState()

    // Clear local authorization state
    clearAuthorizationState()

    // Switch to individual mode
    appModeManager.selectMode(.individual)

    return
      "Your child account authorization was revoked (the device may have been removed from Apple Family Sharing). You've been switched to individual mode. To reconnect, ask a parent to re-add this device and send a new invitation."
  }

  /// Verify child authorization if in child mode and connected to family.
  /// Returns nil if authorized or not applicable, returns error message if authorization lost.
  func verifyIfNeeded() async -> String? {
    let appModeManager = AppModeManager.shared
    let cloudKitManager = CloudKitManager.shared

    // Only verify if in child mode and connected to a family
    guard appModeManager.currentMode == .child,
      cloudKitManager.isConnectedToFamily
    else {
      return nil
    }

    let result = await verifyChildAuthorization()

    if !result.isAuthorized {
      return await handleAuthorizationLoss()
    }

    return nil
  }
}
