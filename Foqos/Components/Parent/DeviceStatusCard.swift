import SwiftUI

struct DeviceStatusCard: View {
  let device: MonitoredDevice
  let onSuppress: () -> Void
  let onRemove: () -> Void

  private var statusColor: Color {
    if device.isSuppressed { return .secondary }
    if device.shouldAlert() { return .red }
    return .green
  }

  private var statusText: String {
    if device.isSuppressed { return "Alerts suppressed" }
    if device.shouldAlert() { return "Not seen recently" }
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
          onRemove()
        }
        .font(.caption)
      }
    }
    .padding()
    .background(Color(.secondarySystemGroupedBackground))
    .cornerRadius(12)
  }
}
