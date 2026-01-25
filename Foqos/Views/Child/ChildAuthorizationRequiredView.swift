import SwiftUI

/// View shown when a CloudKit share invitation cannot be accepted because
/// the device is not set up as a child in Apple Family Sharing.
struct ChildAuthorizationRequiredView: View {
  @Environment(\.dismiss) private var dismiss

  let onDismiss: () -> Void

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 32) {
          // Header icon
          Image(systemName: "person.crop.circle.badge.exclamationmark")
            .font(.system(size: 80))
            .foregroundStyle(.orange)
            .padding(.top, 40)

          // Title and description
          VStack(spacing: 12) {
            Text("Family Sharing Setup Required")
              .font(.title2)
              .fontWeight(.bold)
              .multilineTextAlignment(.center)

            Text(
              "To accept this invitation, this device must be set up as a child in Apple Family Sharing."
            )
            .font(.body)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
          }

          // Setup steps
          VStack(alignment: .leading, spacing: 16) {
            Text("Setup Steps")
              .font(.headline)
              .padding(.horizontal)

            VStack(spacing: 12) {
              SetupStepRow(
                number: 1,
                title: "Parent opens Settings",
                description: "On the parent's iPhone or iPad, go to Settings > Family"
              )

              SetupStepRow(
                number: 2,
                title: "Add child to Family",
                description: "Tap 'Add Member' and add this device's Apple ID as a child"
              )

              SetupStepRow(
                number: 3,
                title: "Enable Screen Time",
                description: "In Family settings, enable Screen Time for the child and approve app requests"
              )

              SetupStepRow(
                number: 4,
                title: "Try the invitation again",
                description: "Once setup is complete, have the parent send a new invitation link"
              )
            }
            .padding(.horizontal)
          }
          .padding(.vertical)
          .background(
            RoundedRectangle(cornerRadius: 16)
              .fill(Color(.secondarySystemBackground))
          )
          .padding(.horizontal)

          // Info box
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
              .foregroundColor(.blue)

            Text(
              "Apple Family Sharing ensures only verified children can receive parental controls from Family Foqos."
            )
            .font(.footnote)
            .foregroundColor(.secondary)
          }
          .padding()
          .background(
            RoundedRectangle(cornerRadius: 12)
              .fill(Color.blue.opacity(0.1))
          )
          .padding(.horizontal)

          Spacer(minLength: 40)
        }
      }
      .navigationTitle("Setup Required")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Done") {
            onDismiss()
            dismiss()
          }
        }
      }
    }
  }
}

/// A single step in the setup instructions
struct SetupStepRow: View {
  let number: Int
  let title: String
  let description: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      // Step number
      Text("\(number)")
        .font(.headline)
        .foregroundColor(.white)
        .frame(width: 28, height: 28)
        .background(Circle().fill(Color.accentColor))

      // Content
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.subheadline)
          .fontWeight(.semibold)

        Text(description)
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Spacer()
    }
  }
}

#Preview {
  ChildAuthorizationRequiredView {
    print("Dismissed")
  }
}
