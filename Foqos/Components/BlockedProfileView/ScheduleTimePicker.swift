// Foqos/Components/BlockedProfileView/ScheduleTimePicker.swift
import SwiftUI

/// Picker for selecting days and time for a schedule
struct ScheduleTimePicker: View {
  @Binding var schedule: ProfileScheduleTime?
  let title: String
  // Snapshot is fine — sheets are modal so the other schedule can't change while this picker is open
  let otherScheduleTime: ProfileScheduleTime?

  @State private var selectedDays: Set<Weekday> = []
  @State private var selectedTime: Date = {
    Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
  }()

  @Environment(\.dismiss) var dismiss

  private var timesMatch: Bool {
    guard let other = otherScheduleTime else { return false }
    let components = Calendar.current.dateComponents([.hour, .minute], from: selectedTime)
    return components.hour == other.hour && components.minute == other.minute
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Days") {
          ForEach(Weekday.localeOrdered(), id: \.self) { day in
            Button {
              if selectedDays.contains(day) {
                selectedDays.remove(day)
              } else {
                selectedDays.insert(day)
              }
            } label: {
              HStack {
                Text(day.name)
                Spacer()
                if selectedDays.contains(day) {
                  Image(systemName: "checkmark")
                    .foregroundStyle(.blue)
                }
              }
            }
            .foregroundStyle(.primary)
          }
        }

        Section("Time") {
          DatePicker(
            "Time",
            selection: $selectedTime,
            displayedComponents: .hourAndMinute
          )
          .datePickerStyle(.wheel)
          .labelsHidden()
        }

        if timesMatch {
          Section {
            Text(
              "Start and stop times can't be the same. Try 1 minute apart for a near-24-hour schedule."
            )
            .foregroundStyle(.red)
            .font(.footnote)
          }
        }
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            saveSchedule()
            dismiss()
          }
          .disabled(selectedDays.isEmpty || timesMatch)
        }
      }
      .onAppear {
        loadExisting()
      }
    }
  }

  private func loadExisting() {
    if let existing = schedule {
      selectedDays = Set(existing.days)
      selectedTime =
        Calendar.current.date(
          from: DateComponents(hour: existing.hour, minute: existing.minute)
        ) ?? selectedTime
    }
  }

  private func saveSchedule() {
    if selectedDays.isEmpty {
      schedule = nil
    } else {
      let components = Calendar.current.dateComponents(
        [.hour, .minute], from: selectedTime)
      schedule = ProfileScheduleTime(
        // rawValue sort for locale-independent storage order (not display order)
        days: Array(selectedDays).sorted { $0.rawValue < $1.rawValue },
        hour: components.hour ?? 9,
        minute: components.minute ?? 0,
        updatedAt: Date()
      )
    }
  }
}

#Preview {
  ScheduleTimePicker(
    schedule: .constant(nil),
    title: "Start Schedule",
    otherScheduleTime: nil
  )
}
