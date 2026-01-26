import FamilyControls
import SwiftData
import SwiftUI

/// Prompt shown when a synced profile needs local app selection on this device.
/// This appears when a profile is synced from another device but has no apps selected locally.
struct AppSelectionPrompt: View {
  @Environment(\.modelContext) private var context
  @EnvironmentObject var themeManager: ThemeManager

  let profile: BlockedProfiles

  @State private var showAppPicker = false
  @State private var localSelection: FamilyActivitySelection

  init(profile: BlockedProfiles) {
    self.profile = profile
    self._localSelection = State(initialValue: profile.selectedActivity)
  }

  var body: some View {
    VStack(spacing: 16) {
      // Icon and message
      VStack(spacing: 12) {
        Image(systemName: "apps.iphone")
          .font(.system(size: 48))
          .foregroundStyle(themeManager.themeColor)

        Text("Select Apps for This Device")
          .font(.headline)

        Text("This profile was synced from another device. Select which apps to block on this device.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal)
      }

      // Profile info
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Profile")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Text(profile.name)
            .font(.caption)
            .bold()
        }

        if hasAppsSelected {
          HStack {
            Text("Apps Selected")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Text(selectionSummary)
              .font(.caption)
              .foregroundStyle(.green)
          }
        }
      }
      .padding()
      .background(Color(.systemGray6))
      .cornerRadius(12)
      .padding(.horizontal)

      // Action buttons
      VStack(spacing: 12) {
        Button {
          showAppPicker = true
        } label: {
          HStack {
            Image(systemName: "plus.app")
            Text(hasAppsSelected ? "Change App Selection" : "Select Apps to Block")
          }
          .frame(maxWidth: .infinity)
          .padding()
          .background(themeManager.themeColor)
          .foregroundColor(.white)
          .cornerRadius(12)
        }

        if hasAppsSelected {
          Button {
            saveSelection()
          } label: {
            HStack {
              Image(systemName: "checkmark.circle")
              Text("Save Selection")
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.green)
            .foregroundColor(.white)
            .cornerRadius(12)
          }
        }
      }
      .padding(.horizontal)
    }
    .padding(.vertical)
    .sheet(isPresented: $showAppPicker) {
      AppPicker(
        selection: $localSelection,
        isPresented: $showAppPicker,
        allowMode: profile.enableAllowMode
      )
    }
  }

  private var hasAppsSelected: Bool {
    return !localSelection.applicationTokens.isEmpty
      || !localSelection.categoryTokens.isEmpty
      || !localSelection.webDomainTokens.isEmpty
  }

  private var selectionSummary: String {
    let appCount = localSelection.applicationTokens.count
    let catCount = localSelection.categoryTokens.count
    let webCount = localSelection.webDomainTokens.count

    var parts: [String] = []
    if appCount > 0 { parts.append("\(appCount) apps") }
    if catCount > 0 { parts.append("\(catCount) categories") }
    if webCount > 0 { parts.append("\(webCount) websites") }

    return parts.isEmpty ? "None" : parts.joined(separator: ", ")
  }

  private func saveSelection() {
    do {
      _ = try BlockedProfiles.updateProfile(
        profile,
        in: context,
        selection: localSelection,
        needsAppSelection: false
      )
      print("AppSelectionPrompt: Saved app selection for profile '\(profile.name)'")
    } catch {
      print("AppSelectionPrompt: Failed to save - \(error)")
    }
  }
}

/// A banner shown on the profile card when it needs app selection
struct AppSelectionRequiredBanner: View {
  @EnvironmentObject var themeManager: ThemeManager

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)

      Text("Select apps on this device")
        .font(.caption)
        .foregroundStyle(.primary)

      Spacer()

      Image(systemName: "chevron.right")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(10)
    .background(Color.orange.opacity(0.15))
    .cornerRadius(8)
  }
}

/// View modifier to show app selection prompt as a sheet
struct AppSelectionPromptModifier: ViewModifier {
  @Binding var isPresented: Bool
  let profile: BlockedProfiles

  func body(content: Content) -> some View {
    content
      .sheet(isPresented: $isPresented) {
        NavigationStack {
          AppSelectionPrompt(profile: profile)
            .navigationTitle("App Selection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
              ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                  isPresented = false
                }
              }
            }
        }
      }
  }
}

extension View {
  func appSelectionPrompt(isPresented: Binding<Bool>, profile: BlockedProfiles) -> some View {
    modifier(AppSelectionPromptModifier(isPresented: isPresented, profile: profile))
  }
}

#Preview {
  AppSelectionPrompt(
    profile: BlockedProfiles(
      name: "Work Focus",
      selectedActivity: FamilyActivitySelection()
    )
  )
  .environmentObject(ThemeManager.shared)
}
