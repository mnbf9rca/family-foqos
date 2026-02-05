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
  let onScanNFCTag: () -> Void
  let onScanQRCode: () -> Void
  let onConfigureSchedule: () -> Void

  @EnvironmentObject var themeManager: ThemeManager

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
              onScanNFCTag()
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
              onScanQRCode()
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
            onConfigureSchedule()
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

      // Deep Link (written NFC tag or printed QR code containing a profile URL)
      Toggle("Written NFC / printed QR", isOn: binding(\.deepLink))
        .disabled(disabled)

    } header: {
      Text("Start by...")
    } footer: {
      if !triggers.isValid {
        Text("Select at least one start trigger")
          .foregroundStyle(.red)
      }
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
