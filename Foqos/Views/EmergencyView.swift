import SwiftUI

struct EmergencyView: View {
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss

  @EnvironmentObject var strategyManager: StrategyManager
  @EnvironmentObject var emergencyManager: EmergencyUnblockManager
  @ObservedObject private var appModeManager = AppModeManager.shared
  @ObservedObject private var lockCodeManager = LockCodeManager.shared

  private var emergencyUnblocksRemaining: Int { emergencyManager.getRemainingEmergencyUnblocks() }
  private var hasRemaining: Bool { emergencyManager.getRemainingEmergencyUnblocks() > 0 }

  private var isGearLocked: Bool {
    emergencyManager.isEmergencySettingsLocked()
      && appModeManager.currentMode == .child
      && !lockCodeVerified
  }

  @State private var isPerformingEmergencyUnblock: Bool = false
  @State private var showingLockCodeEntry: Bool = false
  @State private var lockCodeVerified: Bool = false
  @State private var errorMessage: String?

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        header
        statusCard
      }
      .padding()
    }
    .onAppear {
      emergencyManager.checkAndResetEmergencyUnblocks()
      if appModeManager.currentMode == .child {
        Task { await lockCodeManager.processPendingCommands() }
      }
    }
    .sheet(isPresented: $showingLockCodeEntry) {
      LockCodeEntryView(
        title: "Enter Lock Code",
        subtitle: "Enter the parent lock code to change emergency settings",
        onVerify: { code in
          lockCodeManager.validateCode(code)
        },
        onSuccess: {
          lockCodeVerified = true
        }
      )
    }
    .alert(
      "Emergency Unblock Failed",
      isPresented: .init(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Emergency Access")
          .font(.title2).bold()

        Spacer()

        HStack(spacing: 8) {
          HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
              .font(.caption)
              .foregroundColor(.secondary)

            Group {
              if let nextResetDate = emergencyManager.getNextResetDate() {
                let timeUntilReset = nextResetDate.timeIntervalSinceNow
                if timeUntilReset <= 24 * 60 * 60 {  // Less than 24 hours
                  let hoursRemaining = max(1, Int(ceil(timeUntilReset / 3600)))
                  Text("Resets in \(hoursRemaining)h")
                    .font(.caption)
                } else {
                  Text("Resets \(nextResetDate, format: .dateTime.month().day())")
                    .font(.caption)
                }
              }
            }
          }
          .padding(.vertical, 6)

          if isGearLocked {
            Button {
              showingLockCodeEntry = true
            } label: {
              HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                  .font(.caption2)
                Image(systemName: "gearshape.fill")
                  .font(.caption)
              }
              .foregroundColor(.secondary)
              .padding(8)
              .background(Circle().fill(Color.secondary.opacity(0.1)))
            }
          } else {
            Menu {
              let currentPeriod = emergencyManager.getResetPeriodInDays()

              Button {
                emergencyManager.setResetPeriodInDays(14)
              } label: {
                if currentPeriod == 14 {
                  Label("2 weeks", systemImage: "checkmark")
                } else {
                  Text("2 weeks")
                }
              }

              Button {
                emergencyManager.setResetPeriodInDays(28)
              } label: {
                if currentPeriod == 28 {
                  Label("4 weeks", systemImage: "checkmark")
                } else {
                  Text("4 weeks")
                }
              }

              Button {
                emergencyManager.setResetPeriodInDays(42)
              } label: {
                if currentPeriod == 42 {
                  Label("6 weeks", systemImage: "checkmark")
                } else {
                  Text("6 weeks")
                }
              }

              Button {
                emergencyManager.setResetPeriodInDays(56)
              } label: {
                if currentPeriod == 56 {
                  Label("8 weeks", systemImage: "checkmark")
                } else {
                  Text("8 weeks")
                }
              }
            } label: {
              Image(systemName: "gearshape.fill")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(8)
                .background(Circle().fill(Color.secondary.opacity(0.1)))
            }
          }
        }
      }

      Text(
        "Tap the glass to reveal the emergency unblock button. Use only when absolutely necessary."
      )
      .font(.callout)
      .foregroundColor(.secondary)
    }
    .padding(.top, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var statusCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Image(systemName: hasRemaining ? "shield.lefthalf.filled" : "shield.slash")
          .font(.title3)
          .foregroundColor(hasRemaining ? .green : .red)
        VStack(alignment: .leading, spacing: 4) {
          Text("Unblocks remaining")
            .font(.subheadline)
            .foregroundColor(.secondary)
          Text("\(emergencyUnblocksRemaining)")
            .font(.title2).bold()
            .foregroundColor(hasRemaining ? .primary : .red)
        }
        Spacer()
      }

      Text("You have a limited number of emergency unblocks.")
        .font(.footnote)
        .foregroundColor(.secondary)

      BreakGlassButton(tapsToShatter: 3) {
        ActionButton(
          title: "Emergency Unblock",
          backgroundColor: .red,
          iconName: "exclamationmark.triangle.fill",
          iconColor: .white,
          isLoading: isPerformingEmergencyUnblock,
          isDisabled: !hasRemaining
        ) {
          performEmergencyUnblock()
        }
      }
      .frame(height: 56)

      if !hasRemaining {
        Text("No emergency unblocks remaining. You're out of luck.")
          .font(.footnote)
          .foregroundColor(.red)
      } else {
        Text("This will reduce your remaining count by 1.")
          .font(.footnote)
          .foregroundColor(.secondary)
      }
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(.thinMaterial)
    )
  }

  private func performEmergencyUnblock() {
    isPerformingEmergencyUnblock = true

    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(600))
      do {
        try await strategyManager.emergencyUnblock(context: context)
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
      isPerformingEmergencyUnblock = false
    }
  }
}

struct EmergencyPreviewSheetHost: View {
  @State private var show: Bool = true

  var body: some View {
    Color.clear
      .sheet(isPresented: $show) {
        NavigationView { EmergencyView() }
          .presentationDetents([.medium])
          .presentationDragIndicator(.visible)
      }
  }
}

#Preview {
  EmergencyPreviewSheetHost()
    .environmentObject(StrategyManager.shared)
    .environmentObject(EmergencyUnblockManager.shared)
    .defaultAppStorage(UserDefaults(suiteName: "preview")!)
}
