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
    case authorizationConflict
    case authorizationCanceled
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
          "We couldn't verify Screen Time authorization on this device. Please try again."
      case .notAuthorized:
        return
          "Screen Time authorization is required. Please enable Screen Time in Settings and try again."
      case .authorizationConflict:
        return
          "We couldn't check Screen Time authorization because Family Controls is currently in use. Please try again."
      case .authorizationCanceled:
        return
          "Screen Time authorization wasn't completed. Please try again."
      case .networkError:
        return
          "Unable to verify authorization. Please check your internet connection and try again."
      case .unknownError(let error):
        return "Authorization failed: \(error.localizedDescription)"
      }
    }
  }

  enum VerificationDisposition: Equatable {
    case authorized
    case indeterminate
  }

  static func verificationDisposition(
    for result: VerificationResult
  ) -> VerificationDisposition {
    switch result {
    case .authorized:
      return .authorized
    case .notChildDevice, .notAuthorized, .authorizationConflict, .authorizationCanceled,
      .networkError, .unknownError:
      return .indeterminate
    }
  }

  static func detectedFamilyRole(for result: VerificationResult) -> FamilyRole? {
    switch result {
    case .authorized:
      return .child
    case .notChildDevice:
      return .parent
    case .notAuthorized, .authorizationConflict, .authorizationCanceled, .networkError,
      .unknownError:
      return nil
    }
  }

  static func verificationResult(for error: NSError) -> VerificationResult {
    guard error.domain == FamilyControlsError.errorDomain,
      let familyControlsError = FamilyControlsError(rawValue: error.code)
    else {
      return error.domain == NSURLErrorDomain ? .networkError(error) : .unknownError(error)
    }

    switch familyControlsError {
    case .invalidAccountType:
      return .notChildDevice
    case .authorizationConflict:
      return .authorizationConflict
    case .authorizationCanceled:
      return .authorizationCanceled
    case .networkError:
      return .networkError(error)
    case .unauthorized:
      return .notAuthorized
    case .restricted, .unavailable, .invalidArgument, .authenticationMethodUnavailable:
      return .unknownError(error)
    @unknown default:
      return .unknownError(error)
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
      return Self.verificationResult(for: error)
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
      Log.info("Individual authorization failed - \(redactedErrorForLog(error))", category: .authorization)
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

  /// Handle a CloudKit-confirmed family revocation for a child device.
  /// Family Controls errors must never reach this destructive path.
  /// Clears shared state and switches to individual mode.
  func handleConfirmedCloudKitRevocation() {
    let cloudKitManager = CloudKitManager.shared
    let appModeManager = AppModeManager.shared

    Log.info("Handling confirmed CloudKit family revocation", category: .authorization)

    LockCodeManager.shared.handleConfirmedCloudKitRevocation()

    // Clear CloudKit shared state first
    cloudKitManager.clearSharedState()

    // Clear local authorization state
    clearAuthorizationState()

    // Switch to individual mode
    appModeManager.selectMode(.individual)

  }

  /// Verify child authorization if in child mode and connected to family.
  /// Family Controls failures are recoverable here and never imply family revocation.
  func verifyIfNeeded() async -> String? {
    await verifyIfNeeded {
      await self.verifyChildAuthorization()
    }
  }

  func verifyIfNeeded(
    verify: () async -> VerificationResult
  ) async -> String? {
    let appModeManager = AppModeManager.shared
    let cloudKitManager = CloudKitManager.shared

    // Only verify if in child mode and connected to a family
    guard appModeManager.currentMode == .child,
      cloudKitManager.isConnectedToFamily
    else {
      return nil
    }

    let result = await verify()
    switch Self.verificationDisposition(for: result) {
    case .authorized:
      return nil
    case .indeterminate:
      Log.warning(
        "Child authorization verification was indeterminate; preserving family state",
        category: .authorization)
      return nil
    }
  }
}
