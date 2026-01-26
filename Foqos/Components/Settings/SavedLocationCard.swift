import SwiftUI

struct SavedLocationCard: View {
  @EnvironmentObject var themeManager: ThemeManager

  let location: SavedLocation
  let onEdit: () -> Void
  let onDelete: () -> Void
  var disabled: Bool = false

  var body: some View {
    HStack(spacing: 12) {
      // Location icon
      ZStack {
        Circle()
          .fill(themeManager.themeColor.opacity(0.15))
          .frame(width: 40, height: 40)
        Image(systemName: "mappin.circle.fill")
          .font(.title2)
          .foregroundColor(themeManager.themeColor)
      }

      // Location details
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(location.name)
            .font(.headline)
            .foregroundColor(.primary)

          if location.isLocked {
            Image(systemName: "lock.fill")
              .font(.caption)
              .foregroundColor(.orange)
          }
        }

        Text("Radius: \(SavedLocation.formatRadius(location.defaultRadiusMeters))")
          .font(.subheadline)
          .foregroundColor(.secondary)
      }

      Spacer()

      // Actions
      if !disabled {
        Menu {
          Button {
            onEdit()
          } label: {
            Label("Edit", systemImage: "pencil")
          }

          Button(role: .destructive) {
            onDelete()
          } label: {
            Label("Delete", systemImage: "trash")
          }
        } label: {
          Image(systemName: "ellipsis.circle")
            .font(.title3)
            .foregroundColor(.secondary)
        }
      }
    }
    .padding(.vertical, 8)
    .contentShape(Rectangle())
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
      onEdit: {},
      onDelete: {}
    )

    SavedLocationCard(
      location: SavedLocation(
        name: "Office",
        latitude: 51.5155,
        longitude: -0.1419,
        defaultRadiusMeters: 1000,
        isLocked: true
      ),
      onEdit: {},
      onDelete: {}
    )

    SavedLocationCard(
      location: SavedLocation(
        name: "School",
        latitude: 51.5200,
        longitude: -0.1300,
        defaultRadiusMeters: 250,
        isLocked: false
      ),
      onEdit: {},
      onDelete: {},
      disabled: true
    )
  }
  .environmentObject(ThemeManager.shared)
}
