import SwiftUI

struct VersionFooter: View {
  @EnvironmentObject var themeManager: ThemeManager

  let profileIsActive: Bool
  let mode: AppMode
  let tapProfileDebugHandler: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      if profileIsActive && !DiagnosticsAccess.isRestricted(mode: mode) {
        Button(action: tapProfileDebugHandler) {
          Text("Debug mode")
            .font(.footnote)
            .foregroundColor(themeManager.themeColor)
        }
      }
    }
    .padding(.bottom, 8)
  }
}

#Preview {
  VStack(spacing: 20) {
    VersionFooter(
      profileIsActive: false,
      mode: .individual,
      tapProfileDebugHandler: {}
    )
    .environmentObject(ThemeManager.shared)

    VersionFooter(
      profileIsActive: true,
      mode: .individual,
      tapProfileDebugHandler: {}
    )
    .environmentObject(ThemeManager.shared)
  }
}
