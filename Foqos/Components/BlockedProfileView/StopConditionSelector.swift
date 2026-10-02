import FoqosShared
import SwiftUI

/// Selector for profile stop conditions
struct StopConditionSelector: View {
  @Binding var conditions: ProfileStopConditions
  @Binding var stopNFCTagIds: [String]
  @Binding var stopQRCodeIds: [String]
  @Binding var stopSchedule: ProfileScheduleTime?
  let startTriggers: ProfileStartTriggers
  let nfcTags: [(id: String, name: String)]
  let qrTags: [(id: String, name: String)]
  let disabled: Bool
  let onConditionChange: () -> Void
  let onScanNFCTag: () -> Void
  let onScanQRCode: () -> Void
  let onConfigureSchedule: () -> Void
  let onConfigureTimer: () -> Void

  @State private var nfcOption: NFCStopOption = .none
  @State private var qrOption: QRStopOption = .none

  var body: some View {
    Section {
      // Manual
      Toggle("Tap to stop", isOn: binding(\.manual))
        .disabled(disabled)

      // Timer
      HStack {
        Toggle("Timer", isOn: binding(\.timer))
          .disabled(disabled)
        if conditions.timer {
          Spacer()
          Button("Configure", action: onConfigureTimer)
            .buttonStyle(.bordered)
            .disabled(disabled)
        }
      }
      if conditions.timer {
        if let minutes = conditions.timerDurationMinutes {
          Text("\(minutes / 60)h \(minutes % 60)m")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text("Set a timer duration. Timer won’t stop this profile until you do.")
            .font(.caption)
            .foregroundStyle(.orange)
        }
        Toggle("Allow changing timer before start", isOn: binding(\.allowChangingTimerBeforeStart))
          .disabled(disabled)
        Text("You can choose a different duration for an interactive start. Tag, link, Shortcut and scheduled starts use the saved duration.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

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
      if nfcOption == .same {
        Text("Stop with the same NFC tag that started this session. Other starts need another stop.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if nfcOption == .specific {
        TagPickerRows(
          selectedIds: $stopNFCTagIds, tags: nfcTags,
          scanLabel: "Scan new tag", disabled: disabled, onChange: onConditionChange, onScan: onScanNFCTag)
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
      if qrOption == .same {
        Text("Stop with the same QR code that started this session. Other starts need another stop.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if qrOption == .specific {
        TagPickerRows(
          selectedIds: $stopQRCodeIds, tags: qrTags,
          scanLabel: "Scan new code", disabled: disabled, onChange: onConditionChange, onScan: onScanQRCode)
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

    } header: {
      Text("Continue until...")
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        if !conditions.manual && !conditions.timer && !conditions.hasNFC && !conditions.hasQR && !conditions.schedule {
          Text("Add at least one stop before saving this profile.")
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
