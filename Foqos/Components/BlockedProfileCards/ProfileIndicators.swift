import SwiftUI

struct ProfileIndicators: View {
  let enableLiveActivity: Bool
  let hasReminders: Bool
  let enableBreaks: Bool
  let enableStrictMode: Bool
  var isSynced: Bool = false

  var body: some View {
    HStack(spacing: 16) {
      if isSynced {
        syncIndicatorView()
      }
      if enableBreaks {
        indicatorView(label: "Breaks")
      }
      if enableStrictMode {
        indicatorView(label: "Strict")
      }
      if enableLiveActivity {
        indicatorView(label: "Live Activity")
      }
      if hasReminders {
        indicatorView(label: "Reminders")
      }
    }
  }

  private func syncIndicatorView() -> some View {
    HStack(spacing: 6) {
      Image(systemName: "arrow.triangle.2.circlepath")
        .font(.system(size: 8))
        .foregroundColor(.blue)

      Text("Synced")
        .font(.caption2)
        .foregroundColor(.blue)
    }
  }

  private func indicatorView(label: String) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(Color.primary.opacity(0.85))
        .frame(width: 6, height: 6)

      Text(label)
        .font(.caption2)
        .foregroundColor(.secondary)
    }
  }
}

#Preview {
  VStack(spacing: 20) {
    ProfileIndicators(
      enableLiveActivity: true,
      hasReminders: true,
      enableBreaks: false,
      enableStrictMode: false,
    )
    ProfileIndicators(
      enableLiveActivity: false,
      hasReminders: false,
      enableBreaks: true,
      enableStrictMode: true,
    )
  }
  .padding()
  .background(Color(.systemGroupedBackground))
}
