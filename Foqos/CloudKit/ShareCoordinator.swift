import CloudKit
import SwiftUI
import UIKit

/// Coordinates CloudKit sharing UI for parent-child policy sharing
class ShareCoordinator: NSObject, ObservableObject {
    @Published var isShowingShareSheet = false
    @Published var shareError: String?
    @Published var isPreparingShare = false

    private var currentShare: CKShare?
    private let cloudKitManager = CloudKitManager.shared

    // MARK: - Zone-Level Sharing (Enroll Child)

    /// Prepare and present sharing UI for enrolling a child (family share)
    func enrollChild() {
        isPreparingShare = true

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
        return CKContainer(identifier: "iCloud.com.cynexia.family-foqus")
    }

    // MARK: - Deprecated Per-Policy Sharing

    /// Prepare and present sharing UI for a policy
    @available(*, deprecated, message: "Use enrollChild() for zone-level sharing instead")
    func sharePolicy(_ policy: FamilyPolicy) {
        Task {
            do {
                let share = try await cloudKitManager.createShare(for: policy)
                currentShare = share

                await MainActor.run {
                    self.isShowingShareSheet = true
                }
            } catch {
                await MainActor.run {
                    self.shareError = error.localizedDescription
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
        return "Family Foqos Policies"
    }

    func itemThumbnailData(for csc: UICloudSharingController) -> Data? {
        // Return app icon or policy icon as thumbnail
        return nil
    }

    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        print("Share saved successfully")
        isShowingShareSheet = false
    }

    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        print("Sharing stopped")
        isShowingShareSheet = false
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

// MARK: - Zone Share Sheet Modifier (for enrolling children)

struct EnrollChildModifier: ViewModifier {
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
    func enrollChildSheet(coordinator: ShareCoordinator) -> some View {
        modifier(EnrollChildModifier(coordinator: coordinator))
    }
}

// MARK: - Deprecated Per-Policy Share Sheet

struct SharePolicyModifier: ViewModifier {
    @ObservedObject var coordinator: ShareCoordinator
    let policy: FamilyPolicy

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
    @available(*, deprecated, message: "Use enrollChildSheet(coordinator:) instead")
    func sharePolicySheet(coordinator: ShareCoordinator, policy: FamilyPolicy) -> some View {
        modifier(SharePolicyModifier(coordinator: coordinator, policy: policy))
    }
}

// MARK: - Enroll Child Button Component

struct EnrollChildButton: View {
    @StateObject private var coordinator = ShareCoordinator()

    var body: some View {
        Button {
            coordinator.enrollChild()
        } label: {
            if coordinator.isPreparingShare {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
            } else {
                Label("Add Child", systemImage: "person.badge.plus")
            }
        }
        .disabled(coordinator.isPreparingShare)
        .enrollChildSheet(coordinator: coordinator)
    }
}

// MARK: - Deprecated Share Button Component

@available(*, deprecated, message: "Use zone-level sharing via EnrollChildButton instead")
struct SharePolicyButton: View {
    let policy: FamilyPolicy
    @StateObject private var coordinator = ShareCoordinator()

    var body: some View {
        Button {
            coordinator.sharePolicy(policy)
        } label: {
            Label("Share with Child", systemImage: "square.and.arrow.up")
        }
        .sharePolicySheet(coordinator: coordinator, policy: policy)
    }
}
