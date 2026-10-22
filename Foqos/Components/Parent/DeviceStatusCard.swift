import SwiftUI

struct DeviceStatusCard: View {
  let device: MonitoredDevice
  let onSuppress: () -> Void
  let onRemove: () -> Void

  @State private var showRemoveConfirmation = false

  private var statusColor: Color {
    if device.isSuppressed { return .secondary }
    if device.isAuthRevoked { return .red }
    if device.isStale() { return .orange }
    return .green
  }

  private var statusText: String {
    if device.isSuppressed { return "Alerts suppressed" }
    if device.isAuthRevoked { return "Permissions revoked" }
    if device.isStale() { return "Not seen recently" }
    return "Active"
  }

  private var lastSeenText: String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: device.lastSeenAt, relativeTo: Date())
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "iphone")
          .foregroundColor(statusColor)
        Text(device.deviceName)
          .font(.subheadline.weight(.medium))
        Spacer()
        Circle()
          .fill(statusColor)
          .frame(width: 8, height: 8)
      }

      HStack {
        Text(statusText)
          .font(.caption)
          .foregroundColor(statusColor)
        Spacer()
        Text("Last seen \(lastSeenText)")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      HStack(spacing: 12) {
        Button(device.isSuppressed ? "Unsuppress" : "Suppress") {
          onSuppress()
        }
        .font(.caption)

        Button("Remove", role: .destructive) {
          showRemoveConfirmation = true
        }
        .font(.caption)
      }
    }
    .padding()
    .background(Color(.secondarySystemGroupedBackground))
    .cornerRadius(12)
    .alert(
      "Remove \(device.deviceName)?",
      isPresented: $showRemoveConfirmation
    ) {
      Button("Remove", role: .destructive) {
        onRemove()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This removes the device from Device Status and cancels its status notifications. "
          + "It will appear again if it reports status.")
    }
  }
}
