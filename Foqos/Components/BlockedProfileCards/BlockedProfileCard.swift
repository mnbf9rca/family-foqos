import FamilyControls
import SwiftUI

struct BlockedProfileCard: View {
  @EnvironmentObject var themeManager: ThemeManager

  let data: BlockedProfileCardData

  var isActive: Bool = false
  var isBreakAvailable: Bool = false
  var isBreakActive: Bool = false
  var isBreakOpenRawFields: Bool = false

  var elapsedTime: TimeInterval? = nil

  var onStartTapped: () -> Void
  var onStopTapped: () -> Void
  var onEditTapped: () -> Void
  var onStatsTapped: () -> Void = {}
  var onBreakTapped: () -> Void
  var onAppSelectionTapped: () -> Void = {}

  var isOneMoreMinuteActive: Bool = false
  var isOneMoreMinuteAvailable: Bool = false
  var oneMoreMinuteStartTime: Date? = nil
  var onOneMoreMinuteTapped: () -> Void = {}

  // Keep a reference to the CardBackground to access color
  private var cardBackground: CardBackground {
    CardBackground(isActive: isActive, customColor: themeManager.themeColor)
  }

  var body: some View {
    ZStack {
      // Use the CardBackground component
      cardBackground

      // Content
      VStack(alignment: .leading, spacing: 12) {
        // Header section - Profile name, edit button, and indicators
        HStack {
          VStack(alignment: .leading, spacing: 10) {
            Text(data.name)
              .font(.title3)
              .fontWeight(.bold)
              .foregroundColor(.primary)

            // Using the new ProfileIndicators component
            ProfileIndicators(
              enableLiveActivity: data.enableLiveActivity,
              hasReminders: data.hasReminders,
              enableBreaks: data.enableBreaks,
              enableStrictMode: data.enableStrictMode
            )
          }

          Spacer()

          // Menu button moved to top right
          Menu {
            if !data.isNewerSchemaVersion {
              Button(action: {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onEditTapped()
              }) {
                Label("Edit", systemImage: "pencil")
              }
            }
            Button(action: {
              UIImpactFeedbackGenerator(style: .light).impactOccurred()
              onStatsTapped()
            }) {
              Label("Stats for Nerds", systemImage: "eyeglasses")
            }

            if !data.isNewerSchemaVersion {
              Divider()

              if isActive {
                Button(action: {
                  UIImpactFeedbackGenerator(style: .light).impactOccurred()
                  onStopTapped()
                }) {
                  Label("Stop", systemImage: "stop.fill")
                }
              } else {
                Button(action: {
                  UIImpactFeedbackGenerator(style: .light).impactOccurred()
                  onStartTapped()
                }) {
                  Label("Start", systemImage: "play.fill")
                }
              }
            }
          } label: {
            Image(systemName: "ellipsis")
              .font(.system(size: 14, weight: .medium))
              .foregroundColor(.primary)
              .padding(10)
              .background(
                Circle()
                  .fill(.thinMaterial)
                  .overlay(
                    Circle()
                      .stroke(
                        Color.primary.opacity(0.2),
                        lineWidth: 1
                      )
                  )
              )
          }
        }

        if data.isNewerSchemaVersion {
          // Read-only indicator for profiles from newer app version
          HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundColor(.orange)
            Text("Update app to edit")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        } else {
          // Middle section - Strategy and apps info
          VStack(alignment: .leading, spacing: 16) {
            // Strategy and schedule side-by-side with divider
            HStack(spacing: 16) {
              StrategyInfoView(strategyId: data.blockingStrategyId)

              Divider()
                .frame(height: 24)

              ProfileScheduleRow(data: data, isActive: isActive)
            }

            // Using the new ProfileStatsRow component
            ProfileStatsRow(
              selectedActivity: data.selectedActivity,
              sessionCount: data.sessionCount,
              domainsCount: data.domainsCount
            )
          }
        }

        // Show app selection banner if needed (not for newer schema profiles)
        if data.needsAppSelection && !data.isNewerSchemaVersion {
          Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onAppSelectionTapped()
          }) {
            AppSelectionRequiredBanner()
          }
          .buttonStyle(.plain)
        }

        Spacer(minLength: 4)

        if !data.isNewerSchemaVersion {
          ProfileTimerButton(
            isActive: isActive,
            isBreakAvailable: isBreakAvailable,
            isBreakActive: isBreakActive,
            isBreakOpenRawFields: isBreakOpenRawFields,
            elapsedTime: elapsedTime,
            onStartTapped: onStartTapped,
            onStopTapped: onStopTapped,
            onBreakTapped: onBreakTapped,
            isOneMoreMinuteActive: isOneMoreMinuteActive,
            isOneMoreMinuteAvailable: isOneMoreMinuteAvailable,
            oneMoreMinuteStartTime: oneMoreMinuteStartTime,
            onOneMoreMinuteTapped: onOneMoreMinuteTapped
          )
        }
      }
      .padding(16)
    }
  }
}

#Preview {
  ZStack {
    Color(.systemGroupedBackground).ignoresSafeArea()

    VStack(spacing: 40) {
      let work = BlockedProfiles(
        id: UUID(),
        name: "Work",
        selectedActivity: FamilyActivitySelection(),
        blockingStrategyId: NFCBlockingStrategy.id,
        enableLiveActivity: true,
        reminderTimeInSeconds: 3600
      )
      let gaming = BlockedProfiles(
        id: UUID(),
        name: "Gaming",
        selectedActivity: FamilyActivitySelection(),
        blockingStrategyId: QRCodeBlockingStrategy.id,
        enableLiveActivity: true,
        reminderTimeInSeconds: 3600
      )

      // Inactive card
      BlockedProfileCard(
        data: work.cardData,
        onStartTapped: {},
        onStopTapped: {},
        onEditTapped: {},
        onBreakTapped: {}
      )

      // Active card with timer
      BlockedProfileCard(
        data: gaming.cardData,
        isActive: true,
        isBreakAvailable: true,
        elapsedTime: 1845,  // 30 minutes and 45 seconds
        onStartTapped: {},
        onStopTapped: {},
        onEditTapped: {},
        onBreakTapped: {}
      )
    }
  }
}
