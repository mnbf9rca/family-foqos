// Foqos/Models/ProfileStartTriggers.swift
import Foundation

/// Defines which triggers can start a blocking session for a profile.
/// Multiple triggers can be enabled simultaneously.
struct ProfileStartTriggers: Codable, Equatable {
  var manual: Bool = false
  var anyNFC: Bool = false
  var specificNFC: Bool = false
  var anyQR: Bool = false
  var specificQR: Bool = false
  var schedule: Bool = false
  var deepLink: Bool = false

  /// True if any NFC start trigger is enabled
  var hasNFC: Bool { anyNFC || specificNFC }

  /// True if any QR start trigger is enabled
  var hasQR: Bool { anyQR || specificQR }

  /// True if at least one trigger is selected
  var isValid: Bool {
    manual || anyNFC || specificNFC || anyQR || specificQR || schedule || deepLink
  }
}
