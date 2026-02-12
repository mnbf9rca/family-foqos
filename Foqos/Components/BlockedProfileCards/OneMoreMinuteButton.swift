import SwiftUI

struct OneMoreMinuteButton: View {
  let isActive: Bool
  let isAvailable: Bool
  let oneMoreMinuteStartTime: Date?

  let onTapped: () -> Void

  private func timeRemaining(at date: Date) -> TimeInterval {
    guard let startTime = oneMoreMinuteStartTime else { return 0 }
    return max(0, 60 - date.timeIntervalSince(startTime))
  }

  var body: some View {
    if isActive && oneMoreMinuteStartTime != nil && timeRemaining(at: .now) > 0 {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let remaining = timeRemaining(at: context.date)
        if remaining > 0 {
          HStack(spacing: 6) {
            Image(systemName: "clock.fill")
              .font(.system(size: 16, weight: .medium))
              .foregroundColor(.yellow)
            Text(timeString(from: remaining))
              .font(.system(size: 16, weight: .semibold, design: .monospaced))
              .foregroundColor(.yellow)
              .contentTransition(.numericText())
              .animation(.default, value: remaining)
          }
          .padding(.vertical, 10)
          .padding(.horizontal, 12)
          .frame(minWidth: 0, maxWidth: .infinity)
          .background(
            RoundedRectangle(cornerRadius: 16)
              .fill(.thinMaterial)
              .overlay(
                RoundedRectangle(cornerRadius: 16)
                  .stroke(Color.yellow.opacity(0.3), lineWidth: 1)
              )
          )
        }
      }
    } else if isAvailable {
      GlassButton(
        title: "One more minute",
        icon: "clock",
        fullWidth: true,
        color: .yellow
      ) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onTapped()
      }
    }
  }

  private func timeString(from timeInterval: TimeInterval) -> String {
    let seconds = Int(timeInterval)
    return String(format: "0:%02d", seconds)
  }
}

#Preview {
  VStack(spacing: 20) {
    OneMoreMinuteButton(
      isActive: false,
      isAvailable: true,
      oneMoreMinuteStartTime: nil,
      onTapped: {}
    )

    OneMoreMinuteButton(
      isActive: true,
      isAvailable: false,
      oneMoreMinuteStartTime: Date(),
      onTapped: {}
    )

    OneMoreMinuteButton(
      isActive: false,
      isAvailable: false,
      oneMoreMinuteStartTime: nil,
      onTapped: {}
    )
  }
  .padding()
  .background(Color(.systemGroupedBackground))
}
