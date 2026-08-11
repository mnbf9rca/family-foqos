import DeviceActivity
import SwiftUI

struct DeviceActivitiesDebugCard: View {
  let activities: [DeviceActivityName]
  let profileId: UUID?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if activities.isEmpty {
        Text("No device activities scheduled")
          .font(.caption)
          .foregroundColor(.secondary)
      } else {
        DebugRow(label: "Total Activities", value: "\(activities.count)")

        Divider()

        ForEach(Array(activities.enumerated()), id: \.element.rawValue) { index, activity in
          let classification = DeviceActivityClassifier.classify(activity)

          VStack(alignment: .leading, spacing: 4) {
            Text("Activity \(index + 1)")
              .font(.caption)
              .foregroundColor(.secondary)
              .bold()

            DebugRow(label: "Name", value: activity.rawValue)
            DebugRow(label: "Type", value: classification.type)

            if let profileId {
              DebugRow(
                label: "Matches Profile",
                value: "\(classification.matches(profileId: profileId))"
              )
            }
          }

          if index < activities.count - 1 {
            Divider()
          }
        }
      }
    }
  }
}

#Preview {
  DeviceActivitiesDebugCard(
    activities: [
      DeviceActivityName(rawValue: "550e8400-e29b-41d4-a716-446655440000"),
      DeviceActivityName(
        rawValue: "BreakScheduleActivity:550e8400-e29b-41d4-a716-446655440000"),
      DeviceActivityName(
        rawValue: "ScheduleTimerActivity:550e8400-e29b-41d4-a716-446655440000"),
    ],
    profileId: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")
  )
  .padding()
}

#Preview("Empty") {
  DeviceActivitiesDebugCard(
    activities: [],
    profileId: nil
  )
  .padding()
}
