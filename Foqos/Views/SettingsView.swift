import FamilyControls
import SwiftData
import SwiftUI

let AMZN_STORE_LINK = "https://amzn.to/4fbMuTM"

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var context
  @EnvironmentObject var themeManager: ThemeManager
  @EnvironmentObject var requestAuthorizer: RequestAuthorizer
  @EnvironmentObject var strategyManager: StrategyManager

  @ObservedObject private var appModeManager = AppModeManager.shared

  @State private var showResetBlockingStateAlert = false
  @State private var showParentDashboard = false
  @State private var showChildDashboard = false

  private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
      ?? "1.0"
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Theme") {
          HStack {
            Image(systemName: "paintpalette.fill")
              .foregroundStyle(themeManager.themeColor)
              .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
              Text("Appearance")
                .font(.headline)
              Text("Customize the look of your app")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 8)

          Picker("Theme Color", selection: $themeManager.selectedColorName) {
            ForEach(ThemeManager.availableColors, id: \.name) { colorOption in
              HStack {
                Circle()
                  .fill(colorOption.color)
                  .frame(width: 20, height: 20)
                Text(colorOption.name)
              }
              .tag(colorOption.name)
            }
          }
          .onChange(of: themeManager.selectedColorName) { _, _ in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
          }
        }

        // Family Controls Section
        Section {
          // Current mode display
          HStack {
            Image(systemName: appModeManager.currentMode.iconName)
              .foregroundStyle(themeManager.themeColor)
              .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
              Text("Current Mode")
                .font(.headline)
              Text(appModeManager.currentMode.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
          }
          .padding(.vertical, 4)

          // Parent Dashboard access (for individual or parent mode)
          if appModeManager.currentMode != .child {
            Button {
              showParentDashboard = true
            } label: {
              HStack {
                Image(systemName: "person.2.fill")
                  .foregroundColor(themeManager.themeColor)
                Text("Family Controls Dashboard")
                  .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                  .foregroundColor(.secondary)
                  .font(.caption)
              }
            }
          }

          // Child Dashboard access (for child mode)
          if appModeManager.currentMode == .child {
            Button {
              showChildDashboard = true
            } label: {
              HStack {
                Image(systemName: "lock.shield.fill")
                  .foregroundColor(themeManager.themeColor)
                Text("Parental Controls")
                  .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                  .foregroundColor(.secondary)
                  .font(.caption)
              }
            }
          }

        } header: {
          Text("Family Controls")
        } footer: {
          if appModeManager.currentMode == .individual {
            Text("Access Family Controls to manage screen time for your children, or switch to Parent Mode to make it your primary view.")
          } else if appModeManager.currentMode == .parent {
            Text("You can still use personal profiles in Parent Mode via the Family Controls Dashboard.")
          } else {
            Text("Your screen time is managed by your parent.")
          }
        }

        Section("About") {
          HStack {
            Text("Version")
              .foregroundStyle(.primary)
            Spacer()
            Text("v\(appVersion)")
              .foregroundStyle(.secondary)
          }

          HStack {
            Text("Screen Time Access")
              .foregroundStyle(.primary)
            Spacer()
            HStack(spacing: 8) {
              Circle()
                .fill(requestAuthorizer.getAuthorizationStatus() == .approved ? .green : .red)
                .frame(width: 8, height: 8)
              Text(requestAuthorizer.getAuthorizationStatus() == .approved ? "Authorized" : "Not Authorized")
                .foregroundStyle(.secondary)
                .font(.subheadline)
            }
          }

          HStack {
            Text("Made in")
              .foregroundStyle(.primary)
            Spacer()
            Text("Calgary AB 🇨🇦\nand London 🇬🇧")
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.trailing)
          }
        }

        Section("Buy NFC Tags") {
          Link(destination: URL(string: AMZN_STORE_LINK)!) {
            HStack {
              Text("Amazon (original author affiliate link)")
                .foregroundColor(.primary)
              Spacer()
              Image(systemName: "arrow.up.right.square")
                .foregroundColor(.secondary)
            }
          }
        }

        Section("Help from the original author") {
          Link(destination: URL(string: "https://www.foqos.app/blocking-native-apps.html")!) {
            HStack {
              Text("Blocking Native Apps")
                .foregroundColor(.primary)
              Spacer()
              Image(systemName: "arrow.up.right.square")
                .foregroundColor(.secondary)
            }
          }
        }

        if !strategyManager.isBlocking {
          Section("Troubleshooting") {
            Button {
              showResetBlockingStateAlert = true
            } label: {
              Text("Reset Blocking State")
                .foregroundColor(themeManager.themeColor)
            }
          }
        }
      }
      .navigationTitle("Settings")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(action: { dismiss() }) {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("Close")
        }
      }
      .alert("Reset Blocking State", isPresented: $showResetBlockingStateAlert) {
        Button("Cancel", role: .cancel) { }
        Button("Reset", role: .destructive) {
          strategyManager.resetBlockingState(context: context)
        }
      } message: {
        Text("This will clear all app restrictions and remove any ghost schedules. Only use this if you're locked out and no profile is active.")
      }
      .sheet(isPresented: $showParentDashboard) {
        ParentDashboardView()
      }
      .sheet(isPresented: $showChildDashboard) {
        NavigationStack {
          ChildDashboardView()
            .toolbar {
              ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                  showChildDashboard = false
                }
              }
            }
        }
      }
    }
  }
}

#Preview {
  SettingsView()
    .environmentObject(ThemeManager.shared)
    .environmentObject(RequestAuthorizer())
    .environmentObject(StrategyManager.shared)
}
