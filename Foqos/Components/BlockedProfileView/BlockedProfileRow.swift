import FamilyControls
import SwiftUI

struct ProfileRow: View {
  let data: ProfileRowData

  var formattedUpdateTime: String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: data.updatedAt, relativeTo: Date())
  }

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 12) {
        Text(data.name)
          .font(.headline)

        HStack(spacing: 4) {
          Image(systemName: "clock")
          Text("Updated \(formattedUpdateTime)")
        }
        .foregroundStyle(.secondary)
        .font(.caption)
      }

      Spacer()

      HStack(spacing: 4) {
        Image(systemName: "list.bullet.circle.fill")
        Text("\(data.selectedItemsCount) items")
      }
      .foregroundStyle(.secondary)
      .font(.subheadline)
    }
  }
}

#Preview {
  let previewProfile = BlockedProfiles(
    name: "⌛ School Hours",
    selectedActivity: FamilyActivitySelection(),
    createdAt: Date(),
    updatedAt: Date().addingTimeInterval(-3600)
  )

  return ProfileRow(data: previewProfile.profileRowData)
    .padding()
}
