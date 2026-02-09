// Foqos/Components/SyncConflictBanner.swift
import SwiftUI

struct SyncConflictBanner: View {
  let message: String
  let onDismiss: () -> Void

  var body: some View {
    HStack {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.yellow)

      VStack(alignment: .leading, spacing: 2) {
        Text("Sync Conflict")
          .font(.subheadline.bold())
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button {
        onDismiss()
      } label: {
        Image(systemName: "xmark")
          .foregroundStyle(.secondary)
      }
      .accessibilityLabel("Dismiss sync conflict")
    }
    .padding()
    .background(.yellow.opacity(0.1))
    .cornerRadius(12)
    .padding(.horizontal)
  }
}

#Preview {
  SyncConflictBanner(
    message: "A profile was edited on an older app version.",
    onDismiss: {}
  )
}
