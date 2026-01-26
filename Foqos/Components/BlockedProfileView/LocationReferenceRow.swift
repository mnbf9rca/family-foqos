import SwiftUI

struct LocationReferenceRow: View {
  @EnvironmentObject var themeManager: ThemeManager

  let location: SavedLocation
  @Binding var reference: ProfileLocationReference
  let isSelected: Bool
  let onToggle: (Bool) -> Void

  @State private var showRadiusOverride: Bool = false

  private var effectiveRadius: Double {
    reference.radiusOverrideMeters ?? location.defaultRadiusMeters
  }

  private var hasOverride: Bool {
    reference.radiusOverrideMeters != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        // Checkbox
        Button {
          onToggle(!isSelected)
        } label: {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .foregroundColor(isSelected ? themeManager.themeColor : .secondary)
        }
        .buttonStyle(.plain)

        // Location info
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(location.name)
              .font(.body)
              .foregroundColor(.primary)

            if location.isLocked {
              Image(systemName: "lock.fill")
                .font(.caption2)
                .foregroundColor(.orange)
            }
          }

          Text("Radius: \(SavedLocation.formatRadius(effectiveRadius))")
            .font(.caption)
            .foregroundColor(.secondary)
        }

        Spacer()

        // Radius override button (only show when selected)
        if isSelected {
          Button {
            showRadiusOverride.toggle()
          } label: {
            HStack(spacing: 4) {
              if hasOverride {
                Image(systemName: "ruler")
                  .font(.caption)
              }
              Image(systemName: "chevron.down")
                .font(.caption2)
                .rotationEffect(.degrees(showRadiusOverride ? 180 : 0))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .clipShape(Capsule())
          }
          .buttonStyle(.plain)
        }
      }

      // Radius override picker (expandable)
      if isSelected && showRadiusOverride {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Override radius for this profile:")
              .font(.caption)
              .foregroundColor(.secondary)
            Spacer()
            if hasOverride {
              Button("Reset") {
                reference.radiusOverrideMeters = nil
              }
              .font(.caption)
              .foregroundColor(themeManager.themeColor)
            }
          }

          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              ForEach(SavedLocation.radiusPresets, id: \.meters) { preset in
                radiusButton(label: preset.label, meters: preset.meters)
              }
            }
          }
        }
        .padding(.leading, 44)
        .padding(.top, 4)
      }
    }
    .padding(.vertical, 4)
    .animation(.easeInOut(duration: 0.2), value: showRadiusOverride)
  }

  @ViewBuilder
  private func radiusButton(label: String, meters: Double) -> some View {
    let isCurrentRadius = abs(effectiveRadius - meters) < 1

    Button {
      if abs(location.defaultRadiusMeters - meters) < 1 {
        // If selecting the default, clear the override
        reference.radiusOverrideMeters = nil
      } else {
        reference.radiusOverrideMeters = meters
      }
    } label: {
      Text(label)
        .font(.caption)
        .fontWeight(isCurrentRadius ? .semibold : .regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isCurrentRadius ? themeManager.themeColor : Color.secondary.opacity(0.15))
        .foregroundColor(isCurrentRadius ? .white : .primary)
        .clipShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}

#Preview {
  struct PreviewContainer: View {
    @State var reference = ProfileLocationReference(savedLocationId: UUID())
    @State var isSelected = true

    var body: some View {
      List {
        LocationReferenceRow(
          location: SavedLocation(
            name: "Home",
            latitude: 51.5074,
            longitude: -0.1278,
            defaultRadiusMeters: 500
          ),
          reference: $reference,
          isSelected: isSelected,
          onToggle: { isSelected = $0 }
        )

        LocationReferenceRow(
          location: SavedLocation(
            name: "Office",
            latitude: 51.5155,
            longitude: -0.1419,
            defaultRadiusMeters: 1000,
            isLocked: true
          ),
          reference: .constant(ProfileLocationReference(savedLocationId: UUID(), radiusOverrideMeters: 250)),
          isSelected: true,
          onToggle: { _ in }
        )

        LocationReferenceRow(
          location: SavedLocation(
            name: "School",
            latitude: 51.5200,
            longitude: -0.1300,
            defaultRadiusMeters: 250
          ),
          reference: .constant(ProfileLocationReference(savedLocationId: UUID())),
          isSelected: false,
          onToggle: { _ in }
        )
      }
      .environmentObject(ThemeManager.shared)
    }
  }

  return PreviewContainer()
}
