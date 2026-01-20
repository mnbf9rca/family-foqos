import DeviceActivity
import FamilyControls
import ManagedSettings
import SwiftUI

class RequestAuthorizer: ObservableObject {
    @Published var isAuthorized = false
    @Published var authorizationError: String?

    private let appModeManager = AppModeManager.shared

    /// Request authorization for the current app mode
    func requestAuthorization() {
        requestAuthorization(for: appModeManager.currentMode)
    }

    /// Request authorization for a specific app mode
    /// - Parameter mode: The app mode to request authorization for
    func requestAuthorization(for mode: AppMode) {
        Task {
            do {
                switch mode {
                case .individual, .parent:
                    // Individual and parent modes use .individual authorization
                    // Parent still controls their own device, just creates policies for others
                    try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                    print("Individual authorization successful for mode: \(mode)")

                case .child:
                    // Child mode uses .child authorization
                    // This requires parent approval via Screen Time Family Sharing
                    try await AuthorizationCenter.shared.requestAuthorization(for: .child)
                    print("Child authorization successful")
                }

                await MainActor.run {
                    self.isAuthorized = true
                    self.authorizationError = nil
                }
            } catch {
                print("Error requesting authorization: \(error)")
                await MainActor.run {
                    self.isAuthorized = false
                    self.authorizationError = self.describeAuthorizationError(error, for: mode)
                }
            }
        }
    }

    func getAuthorizationStatus() -> AuthorizationStatus {
        return AuthorizationCenter.shared.authorizationStatus
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
                return "Child mode requires this device to be set up as a child account in Family Sharing. Please ask your parent to add this device to their Family Sharing group."
            }
            return "Unable to authorize child mode. Make sure Screen Time Family Sharing is enabled for this device."

        case .individual, .parent:
            return "Unable to authorize Screen Time access. Please enable Screen Time in Settings and try again."
        }
    }
}
