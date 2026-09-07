import FoqosShared
import SwiftUI

/// Selector for profile stop conditions
struct StopConditionSelector: View {
  @Binding var conditions: ProfileStopConditions
  @Binding var stopNFC: [PhysicalKey]
  @Binding var stopQR: [PhysicalKey]
  @Binding var stopSchedule: ProfileScheduleTime?
  let startTriggers: ProfileStartTriggers
  let disabled: Bool
  let onConditionChange: () -> Void
  let onScanNFCTag: () -> Void
  let onScanQRCode: () -> Void
  let onConfigureSchedule: () -> Void

  @State private var nfcOption: NFCStopOption = .none
  @State private var qrOption: QRStopOption = .none

  var body: some View {
    Section {
      // Manual
      Toggle("Tap to stop", isOn: binding(\.manual))
        .disabled(disabled)

      // Timer
      Toggle("Timer", isOn: binding(\.timer))
        .disabled(disabled)

      // NFC picker
      Picker("NFC", selection: $nfcOption) {
        ForEach(NFCStopOption.availableOptions(forStart: startTriggers)) { option in
          Text(option.label).tag(option)
        }
      }
      .disabled(disabled)
      .onChange(of: nfcOption) { _, newValue in
        newValue.apply(to: &conditions)
        onConditionChange()
      }
      .onChange(of: startTriggers.hasNFC) { _, hasNFC in
        if !hasNFC && nfcOption == .same {
          nfcOption = .none
          NFCStopOption.none.apply(to: &conditions)
          onConditionChange()
        }
      }
      if nfcOption == .specific {
        PhysicalKeyRows(keys: $stopNFC, label: "Tag", disabled: disabled, onScan: onScanNFCTag, onChange: onConditionChange)
      }

      // QR picker
      Picker("QR", selection: $qrOption) {
        ForEach(QRStopOption.availableOptions(forStart: startTriggers)) { option in
          Text(option.label).tag(option)
        }
      }
      .disabled(disabled)
      .onChange(of: qrOption) { _, newValue in
        newValue.apply(to: &conditions)
        onConditionChange()
      }
      .onChange(of: startTriggers.hasQR) { _, hasQR in
        if !hasQR && qrOption == .same {
          qrOption = .none
          QRStopOption.none.apply(to: &conditions)
          onConditionChange()
        }
      }
      if qrOption == .specific {
        PhysicalKeyRows(keys: $stopQR, label: "Code", disabled: disabled, onScan: onScanQRCode, onChange: onConditionChange)
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

      // Deep Link
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
          Text(
            "All selected stop conditions require a specific physical item (NFC tag or QR code). If you lose access to it, Emergency Unblock (limited to 3 per 4 weeks) will be your only way to stop this profile."
          )
          .foregroundStyle(.orange)
        }
      }
    }
    .onAppear {
      nfcOption = NFCStopOption.from(conditions)
      qrOption = QRStopOption.from(conditions)
    }
    .onChange(of: conditions) { _, newConditions in
      nfcOption = NFCStopOption.from(newConditions)
      qrOption = QRStopOption.from(newConditions)
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
