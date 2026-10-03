import SwiftUI

struct SectionTitle: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let title: String
  let buttonText: String?
  let buttonAction: (() -> Void)?
  let buttonIcon: String?

  init(
    _ title: String, buttonText: String? = nil, buttonAction: (() -> Void)? = nil,
    buttonIcon: String? = nil
  ) {
    self.title = title
    self.buttonText = buttonText
    self.buttonAction = buttonAction
    self.buttonIcon = buttonIcon
  }

  var body: some View {
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
    layout {
      Text(title)
        .font(.headline)
        .fontWeight(.medium)
        .foregroundColor(.secondary)

      if !dynamicTypeSize.isAccessibilitySize { Spacer() }

      if let buttonText = buttonText, let buttonAction = buttonAction {
        RoundedButton(buttonText, action: buttonAction, iconName: buttonIcon)
      }
    }
    .padding(.bottom, 10)
  }
}

// Preview
#Preview {
  VStack(spacing: 24) {
    SectionTitle("Recent Activity")

    SectionTitle(
      "Your Focus Sessions",
      buttonText: "See All",
      buttonAction: { Log.debug("See All tapped", category: .ui) })

    SectionTitle(
      "Weekly Insights",
      buttonText: "View Report",
      buttonAction: { Log.debug("View Report tapped", category: .ui) })

    SectionTitle(
      "Achievements",
      buttonText: "Manage",
      buttonAction: { Log.debug("Manage tapped", category: .ui) })

    SectionTitle(
      "App Usage",
      buttonText: "Settings",
      buttonAction: { Log.debug("Settings tapped", category: .ui) })
  }
  .padding(20)
}
