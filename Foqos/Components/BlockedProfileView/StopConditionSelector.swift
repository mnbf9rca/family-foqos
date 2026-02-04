// Foqos/Components/BlockedProfileView/StopConditionSelector.swift
import SwiftUI

/// Selector for profile stop conditions
struct StopConditionSelector: View {
  @Binding var conditions: ProfileStopConditions
  @Binding var stopNFCTagId: String?
  @Binding var stopQRCodeId: String?
  @Binding var stopSchedule: ProfileScheduleTime?
  let startTriggers: ProfileStartTriggers
  let disabled: Bool

  @EnvironmentObject var themeManager: ThemeManager
  @State private var showNFCScanner = false
  @State private var showQRScanner = false
  @State private var showSchedulePicker = false

  private let validator = TriggerValidator()

  var body: some View {
    Section {
      // Manual
      Toggle("Tap to stop", isOn: $conditions.manual)
        .disabled(disabled)

      // Timer
      Toggle("Timer", isOn: $conditions.timer)
        .disabled(disabled)

      // NFC options
      Group {
        Toggle("Any NFC tag", isOn: $conditions.anyNFC)
          .disabled(disabled)

        HStack {
          Toggle("Specific NFC tag", isOn: $conditions.specificNFC)
            .disabled(disabled)
          if conditions.specificNFC {
            Spacer()
            Button(stopNFCTagId == nil ? "Scan" : "Change") {
              showNFCScanner = true
            }
            .buttonStyle(.bordered)
            .disabled(disabled)
          }
        }
        if conditions.specificNFC, let tagId = stopNFCTagId {
          Text("Tag: \(tagId)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        // Same NFC - may be disabled
        optionRow(
          title: "Same NFC tag",
          isOn: $conditions.sameNFC,
          option: .sameNFC
        )
      }

      // QR options
      Group {
        Toggle("Any QR code", isOn: $conditions.anyQR)
          .disabled(disabled)

        HStack {
          Toggle("Specific QR code", isOn: $conditions.specificQR)
            .disabled(disabled)
          if conditions.specificQR {
            Spacer()
            Button(stopQRCodeId == nil ? "Scan" : "Change") {
              showQRScanner = true
            }
            .buttonStyle(.bordered)
            .disabled(disabled)
          }
        }
        if conditions.specificQR, let codeId = stopQRCodeId {
          Text("Code: \(codeId)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        // Same QR - may be disabled
        optionRow(
          title: "Same QR code",
          isOn: $conditions.sameQR,
          option: .sameQR
        )
      }

      // Schedule
      HStack {
        Toggle("Schedule", isOn: $conditions.schedule)
          .disabled(disabled)
        if conditions.schedule {
          Spacer()
          Button("Configure") {
            showSchedulePicker = true
          }
          .buttonStyle(.bordered)
          .disabled(disabled)
        }
      }
      if conditions.schedule, let schedule = stopSchedule {
        Text(scheduleDescription(schedule))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      // Deep Link
      Toggle("Deep link / URL", isOn: $conditions.deepLink)
        .disabled(disabled)

    } header: {
      Text("Continue until...")
    } footer: {
      if !conditions.isValid {
        Text("Select at least one stop condition")
          .foregroundStyle(.red)
      }
    }
    .sheet(isPresented: $showNFCScanner) {
      StopNFCScannerSheet { tagId in
        stopNFCTagId = tagId
        showNFCScanner = false
      }
    }
    .sheet(isPresented: $showQRScanner) {
      StopQRScannerSheet { codeId in
        stopQRCodeId = codeId
        showQRScanner = false
      }
    }
    .sheet(isPresented: $showSchedulePicker) {
      StopScheduleTimePickerSheet(schedule: $stopSchedule)
    }
  }

  @ViewBuilder
  private func optionRow(
    title: String,
    isOn: Binding<Bool>,
    option: StopOption
  ) -> some View {
    let isAvailable = validator.isStopAvailable(option, forStart: startTriggers)
    let reason = validator.unavailabilityReason(option, forStart: startTriggers)

    VStack(alignment: .leading, spacing: 4) {
      Toggle(title, isOn: isOn)
        .disabled(disabled || !isAvailable)
        .opacity(isAvailable ? 1.0 : 0.5)

      if let reason = reason {
        Text(reason)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func scheduleDescription(_ schedule: ProfileScheduleTime) -> String {
    let dayNames = schedule.days.map { $0.shortLabel }.joined(separator: " ")
    let time = String(format: "%d:%02d", schedule.hour, schedule.minute)
    return "\(dayNames) at \(time)"
  }
}

// MARK: - Supporting Sheets

private struct StopNFCScannerSheet: View {
  let onScan: (String) -> Void

  var body: some View {
    Text("NFC Scanner for Stop")
  }
}

private struct StopQRScannerSheet: View {
  let onScan: (String) -> Void

  var body: some View {
    Text("QR Scanner for Stop")
  }
}

private struct StopScheduleTimePickerSheet: View {
  @Binding var schedule: ProfileScheduleTime?
  @Environment(\.dismiss) var dismiss

  var body: some View {
    NavigationStack {
      Text("Stop Schedule Picker")
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
    }
  }
}
