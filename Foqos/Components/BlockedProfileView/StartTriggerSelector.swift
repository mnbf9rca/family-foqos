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
        scanRow(
          tagId: startNFCTagId,
          onScan: onScanNFCTag,
          label: "Tag"
        )
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
        scanRow(
          tagId: startQRCodeId,
          onScan: onScanQRCode,
          label: "Code"
        )
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
  }

  @ViewBuilder
  private func scanRow(tagId: String?, onScan: @escaping () -> Void, label: String) -> some View {
    HStack {
      if let tagId {
        Text("\(label): \(tagId)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button(tagId == nil ? "Scan" : "Change") {
        onScan()
      }
      .buttonStyle(.bordered)
      .disabled(disabled)
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
