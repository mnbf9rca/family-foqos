// Foqos/Components/BlockedProfileView/ScheduleTimePicker.swift
import SwiftUI

/// Picker for selecting days and time for a schedule
struct ScheduleTimePicker: View {
  @Binding var schedule: ProfileScheduleTime?
  let title: String

  @State private var selectedDays: Set<Weekday> = []
  @State private var selectedHour: Int = 9
  @State private var selectedMinute: Int = 0

  @Environment(\.dismiss) var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("Days") {
          ForEach(Weekday.allCases, id: \.self) { day in
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
          HStack {
            Picker("Hour", selection: $selectedHour) {
              ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%02d", hour)).tag(hour)
              }
            }
            .pickerStyle(.wheel)
            .frame(width: 80)

            Text(":")
              .font(.title)

            Picker("Minute", selection: $selectedMinute) {
              ForEach([0, 15, 30, 45], id: \.self) { minute in
                Text(String(format: "%02d", minute)).tag(minute)
              }
            }
            .pickerStyle(.wheel)
            .frame(width: 80)
          }
          .frame(maxWidth: .infinity, alignment: .center)
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
      selectedHour = existing.hour
      selectedMinute = existing.minute
    }
  }

  private func saveSchedule() {
    if selectedDays.isEmpty {
      schedule = nil
    } else {
      schedule = ProfileScheduleTime(
        days: Array(selectedDays).sorted { $0.rawValue < $1.rawValue },
        hour: selectedHour,
        minute: selectedMinute,
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
