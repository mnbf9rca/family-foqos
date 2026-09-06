// Foqos/Components/BlockedProfileView/StartTriggerSelector.swift
import SwiftUI

/// Selector for profile start triggers
struct StartTriggerSelector: View {
  @Binding var triggers: ProfileStartTriggers
  @Binding var startNFC: [PhysicalKey]
  @Binding var startQR: [PhysicalKey]
  @Binding var startSchedule: ProfileScheduleTime?
  let disabled: Bool
  let onTriggerChange: () -> Void
  let onScanNFCTag: () -> Void
  let onScanQRCode: () -> Void
  let onConfigureSchedule: () -> Void

  @State private var nfcOption: NFCStartOption = .none
  @State private var qrOption: QRStartOption = .none

  var body: some View {
    Section {
      // Manual
      Toggle("Tap to start", isOn: binding(\.manual))
        .disabled(disabled)

      // NFC picker
      Picker("NFC", selection: $nfcOption) {
        ForEach(NFCStartOption.allCases) { option in
          Text(option.label).tag(option)
        }
      }
      .disabled(disabled)
      .onChange(of: nfcOption) { _, newValue in
        newValue.apply(to: &triggers)
        onTriggerChange()
      }
      if nfcOption == .specific {
        PhysicalKeyRows(keys: $startNFC, label: "Tag", disabled: disabled, onScan: onScanNFCTag)
      }

      // QR picker
      Picker("QR", selection: $qrOption) {
        ForEach(QRStartOption.allCases) { option in
          Text(option.label).tag(option)
        }
      }
      .disabled(disabled)
      .onChange(of: qrOption) { _, newValue in
        newValue.apply(to: &triggers)
        onTriggerChange()
      }
      if qrOption == .specific {
        PhysicalKeyRows(keys: $startQR, label: "Code", disabled: disabled, onScan: onScanQRCode)
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
        Text(schedule.scheduleDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      // Deep Link
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
    .onAppear {
      nfcOption = NFCStartOption.from(triggers)
      qrOption = QRStartOption.from(triggers)
    }
    .onChange(of: triggers) { _, newTriggers in
      nfcOption = NFCStartOption.from(newTriggers)
      qrOption = QRStartOption.from(newTriggers)
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
}

struct PhysicalKeyRows: View {
  @Binding var keys: [PhysicalKey]
  let label: String
  let disabled: Bool
  let onScan: () -> Void

  var body: some View {
    ForEach($keys) { $key in
      VStack(alignment: .leading) {
        TextField("Name", text: $key.name)
        Text(label == "Tag" ? "NFC tag" : "QR code")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .disabled(disabled)
    }
    .onDelete { offsets in
      guard !disabled else { return }
      keys.remove(atOffsets: offsets)
    }
    .deleteDisabled(disabled)
    Button(keys.isEmpty ? "Scan \(label.lowercased())" : "Scan another \(label.lowercased())", action: onScan)
      .buttonStyle(.bordered)
      .disabled(disabled)
  }
}
