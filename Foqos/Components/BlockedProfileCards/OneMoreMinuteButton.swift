import SwiftUI

struct OneMoreMinuteButton: View {
  let isActive: Bool
  let isAvailable: Bool
  let timeRemaining: TimeInterval

  let onTapped: () -> Void

  var body: some View {
    if isActive && timeRemaining > 0 {
      // Show countdown (no cancel option)
      HStack(spacing: 6) {
        Image(systemName: "clock.fill")
          .font(.system(size: 16, weight: .medium))
          .foregroundColor(.yellow)
        Text(timeString(from: timeRemaining))
          .font(.system(size: 16, weight: .semibold, design: .monospaced))
          .foregroundColor(.yellow)
          .contentTransition(.numericText())
          .animation(.default, value: timeRemaining)
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
      timeRemaining: 0,
      onTapped: {}
    )

    OneMoreMinuteButton(
      isActive: true,
      isAvailable: false,
      timeRemaining: 45,
      onTapped: {}
    )

    OneMoreMinuteButton(
      isActive: false,
      isAvailable: false,
      timeRemaining: 0,
      onTapped: {}
    )
  }
  .padding()
  .background(Color(.systemGroupedBackground))
}
