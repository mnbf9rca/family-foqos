import Combine
import DeviceActivity
import FamilyControls
import ManagedSettings
import SwiftUI

@MainActor
class RequestAuthorizer: ObservableObject {
  @Published private(set) var isAuthorized: Bool
  @Published private(set) var authorizationStatus: AuthorizationStatus
  @Published var authorizationError: String?

  private var cancellable: AnyCancellable?
  private let authorizationCenter: AuthorizationRequesting

  init(authorizationCenter: AuthorizationRequesting = AuthorizationCenter.shared) {
    self.authorizationCenter = authorizationCenter
    let status = AuthorizationCenter.shared.authorizationStatus
    let approved = status == .approved
    self.isAuthorized = approved
    self.authorizationStatus = status
    Log.info(
      "RequestAuthorizer init: authorizationStatus=\(status), isAuthorized=\(approved)",
      category: .authorization)

    cancellable = AuthorizationCenter.shared.$authorizationStatus
      .receive(on: DispatchQueue.main)
      .sink { [weak self] newStatus in
        guard let self else { return }
        let approved = newStatus == .approved
        if self.authorizationStatus != newStatus {
          Log.info(
            "AuthorizationCenter status changed: \(self.authorizationStatus) → \(newStatus)",
            category: .authorization)
        }
        self.authorizationStatus = newStatus
        self.isAuthorized = approved
      }
  }

  /// Request authorization for the current app mode
  @discardableResult
  func requestAuthorization() async -> Bool {
    await requestAuthorization(for: AppModeManager.shared.currentMode)
  }

  /// Request authorization for a specific app mode
  /// - Parameter mode: The app mode to request authorization for
  @discardableResult
  func requestAuthorization(for mode: AppMode) async -> Bool {
    let member: FamilyControlsMember = mode == .child ? .child : .individual

    do {
      try await authorizationCenter.requestAuthorization(for: member)
      Log.info("Authorization successful for mode: \(mode)", category: .authorization)
      self.isAuthorized = true
      self.authorizationError = nil
      return true
    } catch {
      Log.info("Error requesting authorization: \(error)", category: .authorization)
      self.isAuthorized = false
      self.authorizationError = self.describeAuthorizationError(error, for: mode)
      return false
    }
  }

  /// Check if the device is eligible for child mode
  /// Child mode requires the device to be set up as a child in Family Sharing
  func isChildModeEligible() -> Bool {
    // We can't directly check Family Sharing status, but we can attempt
    // child authorization and see if it fails
    // For now, return true and let the authorization flow handle eligibility
    return true
  }

  /// Provides a user-friendly description of authorization errors
  private func describeAuthorizationError(_ error: Error, for mode: AppMode) -> String {
    let nsError = error as NSError

    switch mode {
    case .child:
      // Child authorization has specific requirements
      if nsError.domain == "FamilyControls" {
        return "Child mode requires this device to be set up as a child account in Apple Family Sharing. To set this up: (1) The parent should go to Settings > Family, (2) Add this device's Apple ID as a child, (3) Enable Screen Time for this child in Family settings."
      }
      return "Unable to authorize child mode. This device must be configured as a child in Apple Family Sharing with Screen Time enabled. Please ask your parent to set this up in Settings > Family."

    case .individual, .parent:
      return "Unable to authorize Screen Time access. Please enable Screen Time in Settings and try again."
    }
  }
}
