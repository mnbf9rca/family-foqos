import FamilyControls
import SwiftUI

struct BlockedProfileCarousel: View {
  let profiles: [BlockedProfiles]
  let isBlocking: Bool
  let isBreakAvailable: Bool
  let isBreakActive: Bool
  let isBreakOpenRawFields: Bool
  let activeSessionProfileId: UUID?
  let elapsedTime: TimeInterval
  let startingProfileId: UUID?

  var onStartTapped: (BlockedProfiles) -> Void
  var onStopTapped: (BlockedProfiles) -> Void
  var onEditTapped: (BlockedProfiles) -> Void
  var onStatsTapped: (BlockedProfiles) -> Void
  var onBreakTapped: (BlockedProfiles) -> Void
  var onManageTapped: () -> Void
  var onEmergencyTapped: () -> Void
  var onAppSelectionTapped: (BlockedProfiles) -> Void = { _ in }

  let isOneMoreMinuteActive: Bool
  let isOneMoreMinuteAvailable: Bool
  let oneMoreMinuteStartTime: Date?
  var onOneMoreMinuteTapped: (BlockedProfiles) -> Void

  @State private var currentProfileId: UUID?

  // Constants for the carousel
  private let cardSpacing: CGFloat = 12

  private var cardHeight: CGFloat {
    if isBlocking {
      return isBreakAvailable ? 360 : 320
    }
    return 240
  }

  /// Filtered profiles excluding deleted models
  private var validProfiles: [BlockedProfiles] {
    let result = profiles.valid
    Log.debug(
      "[#285 PROBE] Carousel.validProfiles input=\(profiles.count) output=\(result.count)",
      category: .ui
    )
    for profile in profiles {
      Log.debug("[#285 PROBE] Carousel.input \(profile.debugPersistentModelStateFor285)", category: .ui)
    }
    for profile in result {
      Log.debug("[#285 PROBE] Carousel.output \(profile.debugPersistentModelStateFor285)", category: .ui)
    }
    return result
  }

  private var titleMessage: String {
    return isBlocking ? "Active Profile" : "Profile"
  }

  private var actionButtonText: String {
    return isBlocking ? "Emergency" : "Manage"
  }

  private var actionButtonIcon: String {
    return isBlocking ? "exclamationmark.triangle.fill" : "person.crop.circle"
  }

  private var actionButtonAction: () -> Void {
    return isBlocking ? onEmergencyTapped : onManageTapped
  }

  init(
    profiles: [BlockedProfiles],
    isBlocking: Bool,
    isBreakAvailable: Bool,
    isBreakActive: Bool,
    isBreakOpenRawFields: Bool = false,
    activeSessionProfileId: UUID?,
    elapsedTime: TimeInterval,
    startingProfileId: UUID? = nil,
    onStartTapped: @escaping (BlockedProfiles) -> Void,
    onStopTapped: @escaping (BlockedProfiles) -> Void,
    onEditTapped: @escaping (BlockedProfiles) -> Void,
    onStatsTapped: @escaping (BlockedProfiles) -> Void,
    onBreakTapped: @escaping (BlockedProfiles) -> Void,
    onManageTapped: @escaping () -> Void,
    onEmergencyTapped: @escaping () -> Void,
    onAppSelectionTapped: @escaping (BlockedProfiles) -> Void = { _ in },
    isOneMoreMinuteActive: Bool = false,
    isOneMoreMinuteAvailable: Bool = false,
    oneMoreMinuteStartTime: Date? = nil,
    onOneMoreMinuteTapped: @escaping (BlockedProfiles) -> Void = { _ in }
  ) {
    self.profiles = profiles
    self.isBlocking = isBlocking
    self.isBreakAvailable = isBreakAvailable
    self.isBreakActive = isBreakActive
    self.isBreakOpenRawFields = isBreakOpenRawFields
    self.activeSessionProfileId = activeSessionProfileId
    self.elapsedTime = elapsedTime
    self.startingProfileId = startingProfileId
    self.onStartTapped = onStartTapped
    self.onStopTapped = onStopTapped
    self.onEditTapped = onEditTapped
    self.onStatsTapped = onStatsTapped
    self.onBreakTapped = onBreakTapped
    self.onManageTapped = onManageTapped
    self.onEmergencyTapped = onEmergencyTapped
    self.onAppSelectionTapped = onAppSelectionTapped
    self.isOneMoreMinuteActive = isOneMoreMinuteActive
    self.isOneMoreMinuteAvailable = isOneMoreMinuteAvailable
    self.oneMoreMinuteStartTime = oneMoreMinuteStartTime
    self.onOneMoreMinuteTapped = onOneMoreMinuteTapped
  }

  private func initialSetup() {
    // First priority: active session profile
    if let activeId = activeSessionProfileId,
      validProfiles.contains(where: { $0.id == activeId })
    {
      currentProfileId = activeId
      return
    }

    // Second priority: starting profile
    if let startingId = startingProfileId,
      validProfiles.contains(where: { $0.id == startingId })
    {
      currentProfileId = startingId
      return
    }

    // Default: first profile if available
    currentProfileId = validProfiles.first?.id
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {

      SectionTitle(
        titleMessage,
        buttonText: actionButtonText,
        buttonAction: {
          actionButtonAction()
        },
        buttonIcon: actionButtonIcon
      )
      .padding(.horizontal, 16)

      VStack(spacing: 16) {
        // Card carousel
        ScrollView(.horizontal) {
          LazyHStack(spacing: cardSpacing) {
            ForEach(validProfiles) { profile in
              let _ = Log.debug(
                "[#285 PROBE] Carousel.ForEach child \(profile.debugPersistentModelStateFor285)",
                category: .ui
              )
              SafeModelView(profile) { profile in
                BlockedProfileCard(
                  profile: profile,
                  isActive: profile.id == activeSessionProfileId,
                  isBreakAvailable: isBreakAvailable,
                  isBreakActive: isBreakActive,
                  isBreakOpenRawFields: isBreakOpenRawFields,
                  elapsedTime: elapsedTime,
                  onStartTapped: { onStartTapped(profile) },
                  onStopTapped: { onStopTapped(profile) },
                  onEditTapped: { onEditTapped(profile) },
                  onStatsTapped: { onStatsTapped(profile) },
                  onBreakTapped: { onBreakTapped(profile) },
                  onAppSelectionTapped: { onAppSelectionTapped(profile) },
                  isOneMoreMinuteActive: isOneMoreMinuteActive,
                  isOneMoreMinuteAvailable: isOneMoreMinuteAvailable,
                  oneMoreMinuteStartTime: oneMoreMinuteStartTime,
                  onOneMoreMinuteTapped: { onOneMoreMinuteTapped(profile) }
                )
              }
              .containerRelativeFrame(.horizontal)
            }
          }
          .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $currentProfileId)
        .scrollDisabled(isBlocking)
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, 16)
        .frame(height: cardHeight)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: cardHeight)
        .padding(.bottom, 10)

        // Page indicator dots
        HStack(spacing: 8) {
          if !isBlocking && validProfiles.count > 1 {
            ForEach(validProfiles) { profile in
              Circle()
                .fill(
                  profile.id == currentProfileId
                    ? Color.primary
                    : Color.secondary.opacity(0.3)
                )
                .frame(width: 8, height: 8)
                .animation(.easeInOut, value: currentProfileId)
            }
          }
        }
        .frame(height: 8)
        .opacity(!isBlocking && validProfiles.count > 1 ? 1 : 0)
        .animation(.easeInOut, value: isBlocking)
      }
    }
    .onAppear {
      initialSetup()
    }
    .onChange(of: activeSessionProfileId) { _, _ in
      initialSetup()
    }
    .onChange(of: profiles) { _, _ in
      initialSetup()
    }
    .onChange(of: startingProfileId) { _, _ in
      initialSetup()
    }
  }

}

// Active preview
#Preview {
  let activeId = UUID()

  ZStack {
    Color(.systemGroupedBackground).ignoresSafeArea()

    BlockedProfileCarousel(
      profiles: [
        BlockedProfiles(
          id: activeId,
          name: "Work",
          selectedActivity: FamilyActivitySelection(),
          blockingStrategyId: NFCBlockingStrategy.id,
          enableLiveActivity: true,
          reminderTimeInSeconds: 3600
        ),
        BlockedProfiles(
          id: UUID(),
          name: "Gaming",
          selectedActivity: FamilyActivitySelection(),
          blockingStrategyId: QRCodeBlockingStrategy.id,
          enableLiveActivity: false,
          reminderTimeInSeconds: nil
        ),
        BlockedProfiles(
          id: UUID(),
          name: "Social Media",
          selectedActivity: FamilyActivitySelection(),
          blockingStrategyId: ManualBlockingStrategy.id,
          enableLiveActivity: true,
          reminderTimeInSeconds: 1800
        ),
      ],
      isBlocking: true,
      isBreakAvailable: true,
      isBreakActive: false,
      activeSessionProfileId: activeId,
      elapsedTime: 1234,
      onStartTapped: { _ in },
      onStopTapped: { _ in },
      onEditTapped: { _ in },
      onStatsTapped: { _ in },
      onBreakTapped: { _ in },
      onManageTapped: {},
      onEmergencyTapped: {}
    )
  }
}

#Preview {
  ZStack {
    Color(.systemGroupedBackground).ignoresSafeArea()

    BlockedProfileCarousel(
      profiles: [
        BlockedProfiles(
          id: UUID(),
          name: "Work",
          selectedActivity: FamilyActivitySelection(),
          blockingStrategyId: NFCBlockingStrategy.id,
          enableLiveActivity: true,
          reminderTimeInSeconds: 3600
        ),
        BlockedProfiles(
          id: UUID(),
          name: "Gaming",
          selectedActivity: FamilyActivitySelection(),
          blockingStrategyId: QRCodeBlockingStrategy.id,
          enableLiveActivity: false,
          reminderTimeInSeconds: nil
        ),
        BlockedProfiles(
          id: UUID(),
          name: "Social Media",
          selectedActivity: FamilyActivitySelection(),
          blockingStrategyId: ManualBlockingStrategy.id,
          enableLiveActivity: true,
          reminderTimeInSeconds: 1800
        ),
      ],
      isBlocking: false,
      isBreakAvailable: false,
      isBreakActive: false,
      activeSessionProfileId: nil,
      elapsedTime: 1234,
      onStartTapped: { _ in },
      onStopTapped: { _ in },
      onEditTapped: { _ in },
      onStatsTapped: { _ in },
      onBreakTapped: { _ in },
      onManageTapped: {},
      onEmergencyTapped: {}
    )
  }
}

// Preview with startingProfileId set to "Gaming" (second profile)
#Preview("Starting Profile - Gaming") {
  let gamingProfileId = UUID()

  ZStack {
    Color(.systemGroupedBackground).ignoresSafeArea()

    BlockedProfileCarousel(
      profiles: [
        BlockedProfiles(
          id: UUID(),
          name: "Work",
          selectedActivity: FamilyActivitySelection(),
          blockingStrategyId: NFCBlockingStrategy.id,
          enableLiveActivity: true,
          reminderTimeInSeconds: 3600
        ),
        BlockedProfiles(
          id: gamingProfileId,
          name: "Gaming",
          selectedActivity: FamilyActivitySelection(),
          blockingStrategyId: QRCodeBlockingStrategy.id,
          enableLiveActivity: false,
          reminderTimeInSeconds: nil
        ),
        BlockedProfiles(
          id: UUID(),
          name: "Social Media",
          selectedActivity: FamilyActivitySelection(),
          blockingStrategyId: ManualBlockingStrategy.id,
          enableLiveActivity: true,
          reminderTimeInSeconds: 1800
        ),
      ],
      isBlocking: false,
      isBreakAvailable: false,
      isBreakActive: false,
      activeSessionProfileId: nil,
      elapsedTime: 1234,
      startingProfileId: gamingProfileId,
      onStartTapped: { _ in },
      onStopTapped: { _ in },
      onEditTapped: { _ in },
      onStatsTapped: { _ in },
      onBreakTapped: { _ in },
      onManageTapped: {},
      onEmergencyTapped: {}
    )
  }
}
