import SwiftUI

struct SavedLocationCard: View {
  @EnvironmentObject var themeManager: ThemeManager

  let location: SavedLocation
  let onTap: () -> Void
  var inUseByProfile: String? = nil

  private var isDisabled: Bool {
    inUseByProfile != nil
  }

  var body: some View {
    Button {
      if !isDisabled {
        onTap()
      }
    } label: {
      HStack(spacing: 12) {
        // Location icon
        ZStack {
          Circle()
            .fill(isDisabled ? Color.secondary.opacity(0.15) : themeManager.themeColor.opacity(0.15))
            .frame(width: 40, height: 40)
          Image(systemName: "mappin.circle.fill")
            .font(.title2)
            .foregroundColor(isDisabled ? .secondary : themeManager.themeColor)
        }

        // Location details
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text(location.name)
              .font(.headline)
              .foregroundColor(isDisabled ? .secondary : .primary)

            if location.isLocked {
              Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundColor(.orange)
            }
          }

          if let profileName = inUseByProfile {
            Text("In use by \"\(profileName)\"")
              .font(.subheadline)
              .foregroundColor(.orange)
          } else {
            Text("Distance: \(SavedLocation.formatRadius(location.defaultRadiusMeters))")
              .font(.subheadline)
              .foregroundColor(.secondary)
          }
        }

        Spacer()

        if !isDisabled {
          Image(systemName: "chevron.right")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
  }
}

#Preview {
  List {
    SavedLocationCard(
      location: SavedLocation(
        name: "Home",
        latitude: 51.5074,
        longitude: -0.1278,
        defaultRadiusMeters: 500,
        isLocked: false
      ),
      onTap: {}
    )

    SavedLocationCard(
      location: SavedLocation(
        name: "Office",
        latitude: 51.5155,
        longitude: -0.1419,
        defaultRadiusMeters: 1000,
        isLocked: true
      ),
      onTap: {}
    )

    SavedLocationCard(
      location: SavedLocation(
        name: "School",
        latitude: 51.5200,
        longitude: -0.1300,
        defaultRadiusMeters: 250,
        isLocked: false
      ),
      onTap: {},
      inUseByProfile: "Focus Mode"
    )
  }
  .environmentObject(ThemeManager.shared)
}
