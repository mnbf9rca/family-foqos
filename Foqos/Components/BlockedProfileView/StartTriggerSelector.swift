// Foqos/Components/BlockedProfileView/StartTriggerSelector.swift
import SwiftUI

/// Selector for profile start triggers
struct StartTriggerSelector: View {
  @Binding var triggers: ProfileStartTriggers
  @Binding var startNFCTagId: String?
  @Binding var startQRCodeId: String?
  @Binding var startSchedule: ProfileScheduleTime?
  let disabled: Bool
  let onTriggerChange: () -> Void

  @EnvironmentObject var themeManager: ThemeManager
  @State private var showNFCScanner = false
  @State private var showQRScanner = false
  @State private var showSchedulePicker = false

  var body: some View {
    Section {
      // Manual
      Toggle("Tap to start", isOn: binding(\.manual))
        .disabled(disabled)

      // NFC options
      Group {
        Toggle("Any NFC tag", isOn: binding(\.anyNFC))
          .disabled(disabled)

        HStack {
          Toggle("Specific NFC tag", isOn: binding(\.specificNFC))
            .disabled(disabled)
          if triggers.specificNFC {
            Spacer()
            Button(startNFCTagId == nil ? "Scan" : "Change") {
              showNFCScanner = true
            }
            .buttonStyle(.bordered)
            .disabled(disabled)
          }
        }
        if triggers.specificNFC, let tagId = startNFCTagId {
          Text("Tag: \(tagId)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      // QR options
      Group {
        Toggle("Any QR code", isOn: binding(\.anyQR))
          .disabled(disabled)

        HStack {
          Toggle("Specific QR code", isOn: binding(\.specificQR))
            .disabled(disabled)
          if triggers.specificQR {
            Spacer()
            Button(startQRCodeId == nil ? "Scan" : "Change") {
              showQRScanner = true
            }
            .buttonStyle(.bordered)
            .disabled(disabled)
          }
        }
        if triggers.specificQR, let codeId = startQRCodeId {
          Text("Code: \(codeId)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      // Schedule
      HStack {
        Toggle("Schedule", isOn: binding(\.schedule))
          .disabled(disabled)
        if triggers.schedule {
          Spacer()
          Button("Configure") {
            showSchedulePicker = true
          }
          .buttonStyle(.bordered)
          .disabled(disabled)
        }
      }
      if triggers.schedule, let schedule = startSchedule {
        Text(scheduleDescription(schedule))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      // Deep Link
      Toggle("Deep link / URL", isOn: binding(\.deepLink))
        .disabled(disabled)

    } header: {
      Text("Start by...")
    } footer: {
      if !triggers.isValid {
        Text("Select at least one start trigger")
          .foregroundStyle(.red)
      }
    }
    .sheet(isPresented: $showNFCScanner) {
      NFCScannerSheet { tagId in
        startNFCTagId = tagId
        showNFCScanner = false
      }
    }
    .sheet(isPresented: $showQRScanner) {
      QRScannerSheet { codeId in
        startQRCodeId = codeId
        showQRScanner = false
      }
    }
    .sheet(isPresented: $showSchedulePicker) {
      ScheduleTimePickerSheet(schedule: $startSchedule)
    }
  }

  private func binding(_ keyPath: WritableKeyPath<ProfileStartTriggers, Bool>) -> Binding<Bool> {
    Binding(
      get: { triggers[keyPath: keyPath] },
      set: { newValue in
        triggers[keyPath: keyPath] = newValue
        onTriggerChange()
      }
    )
  }

  private func scheduleDescription(_ schedule: ProfileScheduleTime) -> String {
    let dayNames = schedule.days.map { $0.shortLabel }.joined(separator: " ")
    let time = String(format: "%d:%02d", schedule.hour, schedule.minute)
    return "\(dayNames) at \(time)"
  }
}

// MARK: - Supporting Sheets (Placeholders)

private struct NFCScannerSheet: View {
  let onScan: (String) -> Void

  var body: some View {
    // Will integrate with existing NFCScannerUtil
    Text("NFC Scanner")
      .onAppear {
        // TODO: Integrate with NFCScannerUtil.shared.readNFCTag()
      }
  }
}

private struct QRScannerSheet: View {
  let onScan: (String) -> Void

  var body: some View {
    // Will integrate with existing QR scanner
    Text("QR Scanner")
  }
}

private struct ScheduleTimePickerSheet: View {
  @Binding var schedule: ProfileScheduleTime?
  @Environment(\.dismiss) var dismiss

  var body: some View {
    NavigationStack {
      // Will create proper schedule picker
      Text("Schedule Picker")
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
    }
  }
}
