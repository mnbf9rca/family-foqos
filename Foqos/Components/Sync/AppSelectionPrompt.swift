import SwiftUI

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

#Preview {
  AppSelectionRequiredBanner()
    .environmentObject(ThemeManager.shared)
}
