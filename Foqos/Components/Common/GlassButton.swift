import SwiftUI

struct GlassButton: View {
  let title: String
  let icon: String
  var fullWidth: Bool = true
  var equalWidth: Bool = false
  var longPressEnabled: Bool = false
  var longPressDuration: Double = 0.8
  var color: Color? = nil
  let action: () -> Void

  var body: some View {
    if longPressEnabled {
      longPressButton
    } else {
      standardButton
    }
  }

  private var standardButton: some View {
    Button(action: action) {
      buttonContent
    }
    .buttonStyle(PressableButtonStyle())
    .frame(minWidth: 0, maxWidth: equalWidth ? .infinity : nil)
  }

  @State private var isPressed = false

  private var longPressButton: some View {
    buttonContent
      .contentShape(Rectangle())
      .frame(minWidth: 0, maxWidth: equalWidth ? .infinity : nil)
      .scaleEffect(isPressed ? 0.96 : 1.0)
      .animation(.spring(response: 0.3), value: isPressed)
      .onLongPressGesture(
        minimumDuration: longPressDuration,
        pressing: { pressing in
          isPressed = pressing
        },
        perform: {
          UIImpactFeedbackGenerator(style: .medium).impactOccurred()
          action()
          isPressed = false
        }
      )

  }

  private var buttonContent: some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .font(.system(size: 16, weight: .medium))
      Text(title)
        .fontWeight(.semibold)
        .font(.subheadline)
    }
    .frame(
      minWidth: 0,
      maxWidth: fullWidth ? .infinity : (equalWidth ? .infinity : nil)
    )
    .padding(.vertical, 12)
    .padding(.horizontal, fullWidth ? nil : 24)
    .background(
      RoundedRectangle(cornerRadius: 16)
        .fill(.thinMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: 16)
            .stroke((color ?? Color.primary).opacity(0.2), lineWidth: 1)
        )
    )
    .foregroundColor(color ?? .primary)
  }
}

private struct PressableButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(Rectangle())
      .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
      .animation(.spring(response: 0.3), value: configuration.isPressed)
  }
}

#Preview {
  VStack(spacing: 20) {
    GlassButton(
      title: "Regular Button",
      icon: "play.fill"
    ) {
      Log.debug("Regular button tapped", category: .ui)
    }

    GlassButton(
      title: "Blue Button",
      icon: "star.fill",
      color: .blue
    ) {
      Log.debug("Blue button tapped", category: .ui)
    }

    GlassButton(
      title: "Hold to Start",
      icon: "play.fill",
      longPressEnabled: true,
      color: .green
    ) {
      Log.debug("Long press completed", category: .ui)
    }
  }
  .padding()
  .background(Color(.systemGroupedBackground))
}
