import SwiftUI

enum StartupRecoveryCopy {
  static let title = "We found your family"
  static let introduction =
    "This device no longer has its previous local data, but this iCloud account is still part of a Family Foqos family. Your family role has been restored."
  static let noProfiles =
    "We couldn't find any profiles saved with Device Sync. Profiles that existed only on this device can't be recovered."

  static func profilePrompt(count: Int) -> String {
    if count == 1 {
      return "We found 1 synced profile. Restore it to this device?"
    }
    return "We found \(count) synced profiles. Restore them to this device?"
  }
}

enum StartupRecoveryStartupPolicy {
  static func isReleased(_ state: StartupRecoveryState) -> Bool {
    switch state {
    case .normal, .roleRestored:
      return true
    default:
      return false
    }
  }
}

struct StartupRecoveryView: View {
  @ObservedObject var coordinator: StartupRecoveryCoordinator

  var body: some View {
    VStack(spacing: 24) {
      Spacer()
      content
        .frame(maxWidth: 440)
      Spacer()
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
  }

  @ViewBuilder
  private var content: some View {
    switch coordinator.state {
    case .checking:
      checkingView(message: "Checking iCloud for your family…")
    case .checkingProfiles:
      checkingView(message: "Checking Device Sync for profiles…")
    case .retryMembership(let canContinueSetup):
      retryView(
        message: "We couldn't check your family in iCloud. Check your connection and try again.",
        canContinueSetup: canContinueSetup)
    case .retryProfiles:
      retryView(
        message:
          "Your family role was restored, but we couldn't check Device Sync for profiles. Check your connection and try again.",
        canContinueSetup: false)
    case .offer(_, let profileCount):
      offerView(profileCount: profileCount)
    case .normal, .roleRestored:
      EmptyView()
    }
  }

  private func checkingView(message: String) -> some View {
    VStack(spacing: 20) {
      ProgressView()
        .controlSize(.large)
      Text(message)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
    }
  }

  private func retryView(message: String, canContinueSetup: Bool) -> some View {
    VStack(spacing: 20) {
      Image(systemName: "icloud.slash")
        .font(.system(size: 42))
        .foregroundStyle(.secondary)
      Text("We couldn't finish checking")
        .font(.title2.bold())
        .multilineTextAlignment(.center)
      Text(message)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
      Button("Retry") {
        Task { await coordinator.retry() }
      }
      .buttonStyle(.borderedProminent)
      if canContinueSetup {
        Button("Continue Setup") {
          coordinator.continueSetup()
        }
        .buttonStyle(.bordered)
      }
    }
  }

  private func offerView(profileCount: Int) -> some View {
    VStack(spacing: 20) {
      Image(systemName: "person.2.fill")
        .font(.system(size: 42))
        .foregroundStyle(.tint)
      Text(StartupRecoveryCopy.title)
        .font(.title.bold())
        .multilineTextAlignment(.center)
      Text(StartupRecoveryCopy.introduction)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
      Text(
        profileCount > 0
          ? StartupRecoveryCopy.profilePrompt(count: profileCount)
          : StartupRecoveryCopy.noProfiles
      )
      .multilineTextAlignment(.center)

      if profileCount > 0 {
        Button("Restore") {
          Task { await coordinator.restoreProfiles() }
        }
        .buttonStyle(.borderedProminent)
        Button("Not Now") {
          Task { await coordinator.declineProfiles() }
        }
        .buttonStyle(.bordered)
      } else {
        Button("Continue") {
          Task { await coordinator.continueWithoutProfiles() }
        }
        .buttonStyle(.borderedProminent)
      }
    }
  }
}
