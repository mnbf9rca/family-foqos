// Foqos/Components/BlockedProfileView/ScheduleTimePicker.swift
import SwiftUI

/// Picker for selecting days and time for a schedule
struct ScheduleTimePicker: View {
  @Binding var schedule: ProfileScheduleTime?
  let title: String

  @State private var selectedDays: Set<Weekday> = []
  @State private var selectedTime: Date = {
    Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
  }()

  @Environment(\.dismiss) var dismiss

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
          .disabled(selectedDays.isEmpty)
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
    title: "Start Schedule"
  )
}
