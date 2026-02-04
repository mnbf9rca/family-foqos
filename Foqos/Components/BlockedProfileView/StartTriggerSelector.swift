// Foqos/Components/BlockedProfileView/StartTriggerSelector.swift
import CodeScanner
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
      ScheduleTimePicker(schedule: $startSchedule, title: "Start Schedule")
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

// MARK: - Scanner Sheets

private struct NFCScannerSheet: View {
  let onScan: (String) -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var nfcScanner = NFCScannerUtil()
  @State private var errorMessage: String?
  @State private var isScanning = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        Image(systemName: "wave.3.right")
          .font(.system(size: 60))
          .foregroundStyle(.blue)

        Text("Scan NFC Tag")
          .font(.title2)
          .bold()

        Text("Hold your iPhone near an NFC tag to bind it to this profile's start trigger.")
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
          .padding(.horizontal)

        if isScanning {
          ProgressView("Scanning...")
        }

        if let error = errorMessage {
          Text(error)
            .foregroundStyle(.red)
            .font(.caption)
        }

        Button {
          startScanning()
        } label: {
          Label("Start Scanning", systemImage: "wave.3.right")
        }
        .buttonStyle(.borderedProminent)
        .disabled(isScanning)

        Spacer()
      }
      .padding()
      .navigationTitle("NFC Scanner")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
      }
    }
    .onAppear {
      setupCallbacks()
      startScanning()
    }
  }

  private func setupCallbacks() {
    nfcScanner.onTagScanned = { result in
      isScanning = false
      onScan(result.id)
    }
    nfcScanner.onError = { error in
      isScanning = false
      errorMessage = error
    }
  }

  private func startScanning() {
    errorMessage = nil
    isScanning = true
    nfcScanner.scan(profileName: "profile")
  }
}

private struct QRScannerSheet: View {
  let onScan: (String) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      LabeledCodeScannerView(
        heading: "Scan QR Code",
        subtitle: "Point your camera at a QR code to bind it to this profile's start trigger."
      ) { result in
        switch result {
        case .success(let scanResult):
          onScan(scanResult.string)
        case .failure:
          // Error handled by LabeledCodeScannerView
          break
        }
      }
      .navigationTitle("QR Scanner")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
      }
    }
  }
}

