import SwiftUI

struct ActionButton: View {
  let title: String
  let backgroundColor: Color?
  let iconName: String?
  let iconColor: Color?
  let isLoading: Bool
  let isDisabled: Bool

  let action: () -> Void

  init(
    title: String,
    backgroundColor: Color? = nil,
    iconName: String? = nil,
    iconColor: Color? = nil,
    isLoading: Bool = false,
    isDisabled: Bool = false,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.backgroundColor = backgroundColor
    self.iconName = iconName
    self.iconColor = iconColor
    self.isLoading = isLoading
    self.isDisabled = isDisabled
    self.action = action
  }

  var body: some View {
    Button(action: (isLoading || isDisabled) ? {} : action) {
      HStack(spacing: 8) {
        if isLoading {
          ProgressView()
            .progressViewStyle(CircularProgressViewStyle(tint: .white))
            .scaleEffect(0.8)
        } else {
          if let iconName = iconName {
            Image(systemName: iconName)
              .font(.headline)
              .foregroundColor(iconColor ?? .white)
          }

          Text(title)
            .font(.headline)
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
        }
      }.frame(maxWidth: .infinity)
        .frame(minHeight: 40)
        .padding(.vertical, 8)
    }
    .modifier(
      GlassProminentIfAvailable(
        backgroundColor: backgroundColor ?? Color.indigo,
        isLoading: isLoading,
        isDisabled: isDisabled
      )
    )
    .disabled(isLoading || isDisabled)
  }
}

private struct GlassProminentIfAvailable: ViewModifier {
  let backgroundColor: Color
  let isLoading: Bool
  let isDisabled: Bool

  func body(content: Content) -> some View {
    Group {
      if #available(iOS 26.0, *) {
        content
          .frame(minHeight: 50)
          .buttonStyle(.glassProminent)
          .tint(backgroundColor)
      } else {
        content
          .background(backgroundColor)
          .opacity((isLoading || isDisabled) ? 0.6 : 1.0)
          .clipShape(Capsule())
          .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 2)
          .padding(.horizontal, 20)
      }
    }
  }
}

#Preview("Action Button Examples") {
  VStack(spacing: 20) {
    // Basic button
    ActionButton(title: "Save") {
      Log.debug("Save tapped", category: .ui)
    }

    // Button with icon
    ActionButton(
      title: "Download",
      iconName: "arrow.down.circle"
    ) {
      Log.debug("Download tapped", category: .ui)
    }

    // Loading state
    ActionButton(
      title: "Saving...",
      isLoading: true
    ) {
      Log.debug("This won't execute while loading", category: .ui)
    }

    // Custom background with icon
    ActionButton(
      title: "Delete",
      backgroundColor: .red,
      iconName: "trash"
    ) {
      Log.debug("Delete tapped", category: .ui)
    }

    // Success button with icon
    ActionButton(
      title: "Complete",
      backgroundColor: .green,
      iconName: "checkmark.circle"
    ) {
      Log.debug("Complete tapped", category: .ui)
    }

    // Custom icon color example
    ActionButton(
      title: "Favorite",
      backgroundColor: .gray,
      iconName: "heart.fill",
      iconColor: .red
    ) {
      Log.debug("Favorite tapped", category: .ui)
    }

    // Loading with custom color
    ActionButton(
      title: "Processing...",
      backgroundColor: .orange,
      isLoading: true
    ) {
      Log.debug("Processing", category: .ui)
    }

    // Warning button
    ActionButton(
      title: "Backup",
      backgroundColor: .yellow,
      iconName: "cloud.fill"
    ) {
      Log.debug("Backup tapped", category: .ui)
    }

    // Icon only style (short title)
    ActionButton(
      title: "Share",
      backgroundColor: .blue,
      iconName: "square.and.arrow.up"
    ) {
      Log.debug("Share tapped", category: .ui)
    }

    // Disabled state
    ActionButton(
      title: "Disabled",
      backgroundColor: .gray,
      iconName: "lock.fill",
      isDisabled: true
    ) {
      Log.debug("Should not tap", category: .ui)
    }
  }
  .padding()
  .background(Color(.systemGroupedBackground))
}
