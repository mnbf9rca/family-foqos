import SwiftUI

struct ScheduleWarningPrompt: View {
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.title2)
        .foregroundColor(.yellow)
      VStack(alignment: .leading, spacing: 8) {
        Text("Schedule not registered on this device")
          .font(.headline)
        Text("A required schedule is not registered. The app retries when you return to it.")
          .font(.subheadline)
      }
      .foregroundColor(.primary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
  }
}

#Preview {
  Form {
    ScheduleWarningPrompt()
  }
}
