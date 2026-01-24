import FamilyControls
import Foundation

/// Centralized service for verifying Apple Family Sharing authorization.
/// Used to ensure children accepting CloudKit shares are actually set up as
/// children in Apple Family Sharing (not just adults pretending to be children).
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

    Task { @MainActor in
      self.currentAuthorizationType = type
      self.lastVerificationDate = now
    }
  }

  // MARK: - Authorization Verification

  /// Get current authorization status without requesting
  func getCurrentAuthorizationStatus() -> AuthorizationStatus {
    return AuthorizationCenter.shared.authorizationStatus
  }

  /// Verify that the device has valid .child authorization.
  /// Returns true if the device is set up as a child in Apple Family Sharing.
  func verifyChildAuthorization() async -> Bool {
    let status = AuthorizationCenter.shared.authorizationStatus

    // Check if we already have approved status
    if status == .approved {
      // We need to try requesting child auth to verify it's actually child auth
      // not just individual auth
      return await requestChildAuthorizationIfNeeded()
    }

    return false
  }

  /// Attempt to request .child authorization.
  /// Returns true if successful (device is set up as child in Apple Family Sharing).
  /// Returns false if authorization fails (device is not a child device).
  func requestChildAuthorizationIfNeeded() async -> Bool {
    do {
      try await AuthorizationCenter.shared.requestAuthorization(for: .child)
      persistAuthorizationType(.child)
      print("AuthorizationVerifier: Child authorization successful")
      return true
    } catch {
      print("AuthorizationVerifier: Child authorization failed - \(error)")
      // Don't clear authorization type here - the device might still have individual auth
      return false
    }
  }

  /// Request .individual authorization.
  /// Returns true if successful.
  func requestIndividualAuthorization() async -> Bool {
    do {
      try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
      persistAuthorizationType(.individual)
      print("AuthorizationVerifier: Individual authorization successful")
      return true
    } catch {
      print("AuthorizationVerifier: Individual authorization failed - \(error)")
      return false
    }
  }

  /// Clear the persisted authorization state (called when leaving family share)
  func clearAuthorizationState() {
    userDefaults.removeObject(forKey: Keys.authorizationType)
    userDefaults.removeObject(forKey: Keys.authorizationVerifiedAt)

    Task { @MainActor in
      self.currentAuthorizationType = .none
      self.lastVerificationDate = nil
    }
  }

  // MARK: - Verification with Detailed Results

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

  /// Verify child authorization with detailed result
  func verifyChildAuthorizationWithResult() async -> VerificationResult {
    do {
      try await AuthorizationCenter.shared.requestAuthorization(for: .child)
      persistAuthorizationType(.child)
      return .authorized
    } catch let error as NSError {
      print("AuthorizationVerifier: Child authorization failed - domain: \(error.domain), code: \(error.code)")

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
}
