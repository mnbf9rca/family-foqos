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
  let onConditionChange: () -> Void
  let onScanNFCTag: () -> Void
  let onScanQRCode: () -> Void
  let onConfigureSchedule: () -> Void

  private let validator = TriggerValidator()

  var body: some View {
    Section {
      // Manual
      Toggle("Tap to stop", isOn: binding(\.manual))
        .disabled(disabled)

      // Timer
      Toggle("Timer", isOn: binding(\.timer))
        .disabled(disabled)

      // NFC options
      Group {
        Toggle("Any NFC tag", isOn: binding(\.anyNFC))
          .disabled(disabled)

        HStack {
          Toggle("Specific NFC tag", isOn: binding(\.specificNFC))
            .disabled(disabled)
          if conditions.specificNFC {
            Spacer()
            Button(stopNFCTagId == nil ? "Scan" : "Change") {
              onScanNFCTag()
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
          isOn: binding(\.sameNFC),
          option: .sameNFC
        )
      }

      // QR options
      Group {
        Toggle("Any QR code", isOn: binding(\.anyQR))
          .disabled(disabled)

        HStack {
          Toggle("Specific QR code", isOn: binding(\.specificQR))
            .disabled(disabled)
          if conditions.specificQR {
            Spacer()
            Button(stopQRCodeId == nil ? "Scan" : "Change") {
              onScanQRCode()
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
          isOn: binding(\.sameQR),
          option: .sameQR
        )
      }

      // Schedule
      HStack {
        Toggle("Schedule", isOn: binding(\.schedule))
          .disabled(disabled)
        if conditions.schedule {
          Spacer()
          Button("Configure") {
            onConfigureSchedule()
          }
          .buttonStyle(.bordered)
          .disabled(disabled)
        }
      }
      if conditions.schedule, let schedule = stopSchedule {
        Text(schedule.scheduleDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      // Deep Link (written NFC tag or printed QR code containing a profile URL)
      Toggle("Written NFC / printed QR", isOn: binding(\.deepLink))
        .disabled(disabled)

    } header: {
      Text("Continue until...")
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        if !conditions.isValid {
          Text("Select at least one stop condition")
            .foregroundStyle(.red)
        }
        if conditions.requiresPhysicalItemOnly {
          Text("All selected stop conditions require a specific physical item (NFC tag or QR code). If you lose access to it, Emergency Unblock (limited to 3 per 4 weeks) will be your only way to stop this profile.")
            .foregroundStyle(.orange)
        }
      }
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

  private func binding(_ keyPath: WritableKeyPath<ProfileStopConditions, Bool>) -> Binding<Bool> {
    Binding(
      get: { conditions[keyPath: keyPath] },
      set: { newValue in
        conditions[keyPath: keyPath] = newValue
        onConditionChange()
      }
    )
  }
}
