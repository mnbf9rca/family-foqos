import CloudKit
import SwiftUI
import UIKit

/// Coordinates CloudKit sharing UI for parent-child policy sharing
class ShareCoordinator: NSObject, ObservableObject {
    @Published var isShowingShareSheet = false
    @Published var isShowingLeaveShareSheet = false
    @Published var shareError: String?
    @Published var isPreparingShare = false
    @Published var didLeaveShare = false

    private var currentShare: CKShare?
    private let cloudKitManager = CloudKitManager.shared

    // The role being enrolled (for creating the FamilyMember record after share acceptance)
    @Published var pendingRole: FamilyRole = .child

    // Callback when child successfully leaves share
    var onDidLeaveShare: (() -> Void)?

    // MARK: - Zone-Level Sharing (Enroll Family Member)

    /// Prepare and present sharing UI for enrolling a family member
    func enrollFamilyMember(role: FamilyRole) {
        isPreparingShare = true
        pendingRole = role

        Task {
            do {
                let share = try await cloudKitManager.getOrCreateFamilyShare()
                currentShare = share

                await MainActor.run {
                    self.isPreparingShare = false
                    self.isShowingShareSheet = true
                }
            } catch {
                await MainActor.run {
                    self.isPreparingShare = false
                    self.shareError = error.localizedDescription
                }
            }
        }
    }

    /// Get the current share for presenting in UICloudSharingController
    func getCurrentShare() -> CKShare? {
        return currentShare
    }

    /// Get the CloudKit container
    func getContainer() -> CKContainer {
        return CKContainer(identifier: "iCloud.com.cynexia.family-foqos")
    }

    // MARK: - Leave Share (Child)

    /// Prepare and present UI for child to leave the family share
    func prepareToLeaveShare() {
        isPreparingShare = true

        Task {
            do {
                // Fetch the share from the shared database
                let share = try await cloudKitManager.fetchShareFromSharedDatabase()
                currentShare = share

                await MainActor.run {
                    self.isPreparingShare = false
                    self.isShowingLeaveShareSheet = true
                }
            } catch {
                await MainActor.run {
                    self.isPreparingShare = false
                    self.shareError = "Could not find family share: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Share Acceptance (Child)

    /// Accept a share from a URL scheme or universal link
    func acceptShare(from metadata: CKShare.Metadata) {
        Task {
            do {
                try await cloudKitManager.acceptShare(metadata: metadata)
            } catch {
                await MainActor.run {
                    self.shareError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - UICloudSharingControllerDelegate

extension ShareCoordinator: UICloudSharingControllerDelegate {
    func cloudSharingController(
        _ csc: UICloudSharingController,
        failedToSaveShareWithError error: Error
    ) {
        shareError = "Failed to save share: \(error.localizedDescription)"
        print("CloudKit share save failed: \(error)")
    }

    func itemTitle(for csc: UICloudSharingController) -> String? {
        return "Family Foqos"
    }

    func itemThumbnailData(for csc: UICloudSharingController) -> Data? {
        return nil
    }

    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        print("ShareCoordinator: Share saved successfully")
        isShowingShareSheet = false
    }

    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        print("ShareCoordinator: User stopped sharing / left share")
        isShowingShareSheet = false
        isShowingLeaveShareSheet = false

        // Clear local state when child leaves
        Task {
            await cloudKitManager.clearSharedState()
            await MainActor.run {
                self.didLeaveShare = true
                self.onDidLeaveShare?()
            }
        }
    }
}

// MARK: - SwiftUI View Wrapper

/// SwiftUI wrapper for UICloudSharingController (zone-level sharing)
struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    @ObservedObject var coordinator: ShareCoordinator

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.delegate = coordinator
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {
        // No updates needed
    }
}

// MARK: - Zone Share Sheet Modifier (for enrolling family members)

struct EnrollFamilyMemberModifier: ViewModifier {
    @ObservedObject var coordinator: ShareCoordinator

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $coordinator.isShowingShareSheet) {
                if let share = coordinator.getCurrentShare() {
                    CloudSharingView(
                        share: share,
                        container: coordinator.getContainer(),
                        coordinator: coordinator
                    )
                }
            }
            .alert("Sharing Error", isPresented: .constant(coordinator.shareError != nil)) {
                Button("OK") {
                    coordinator.shareError = nil
                }
            } message: {
                Text(coordinator.shareError ?? "")
            }
    }
}

extension View {
    func enrollFamilyMemberSheet(coordinator: ShareCoordinator) -> some View {
        modifier(EnrollFamilyMemberModifier(coordinator: coordinator))
    }
}

// MARK: - Leave Share Sheet Modifier (for child leaving family)

struct LeaveShareModifier: ViewModifier {
    @ObservedObject var coordinator: ShareCoordinator

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $coordinator.isShowingLeaveShareSheet) {
                if let share = coordinator.getCurrentShare() {
                    CloudSharingView(
                        share: share,
                        container: coordinator.getContainer(),
                        coordinator: coordinator
                    )
                }
            }
            .alert("Error", isPresented: .constant(coordinator.shareError != nil)) {
                Button("OK") {
                    coordinator.shareError = nil
                }
            } message: {
                Text(coordinator.shareError ?? "")
            }
    }
}

extension View {
    func leaveShareSheet(coordinator: ShareCoordinator) -> some View {
        modifier(LeaveShareModifier(coordinator: coordinator))
    }
}

// MARK: - Enroll Family Member Button Component

struct EnrollFamilyMemberButton: View {
    let role: FamilyRole
    @StateObject private var coordinator = ShareCoordinator()

    var body: some View {
        Button {
            coordinator.enrollFamilyMember(role: role)
        } label: {
            if coordinator.isPreparingShare {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
            } else {
                Label("Add \(role.displayName)", systemImage: "person.badge.plus")
            }
        }
        .disabled(coordinator.isPreparingShare)
        .enrollFamilyMemberSheet(coordinator: coordinator)
    }
}
