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
  var shortcuts: Bool = false

  /// True if any NFC start trigger is enabled
  var hasNFC: Bool { anyNFC || specificNFC }

  /// True if any QR start trigger is enabled
  var hasQR: Bool { anyQR || specificQR }

  /// True if at least one trigger is selected
  var isValid: Bool {
    manual || anyNFC || specificNFC || anyQR || specificQR || schedule || deepLink || shortcuts
  }
}

// Keep the memberwise initializer for new, explicitly selected configurations.
extension ProfileStartTriggers {
  enum CodingKeys: String, CodingKey {
    case manual, anyNFC, specificNFC, anyQR, specificQR, schedule, deepLink, shortcuts
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    manual = try values.decode(Bool.self, forKey: .manual)
    anyNFC = try values.decode(Bool.self, forKey: .anyNFC)
    specificNFC = try values.decode(Bool.self, forKey: .specificNFC)
    anyQR = try values.decode(Bool.self, forKey: .anyQR)
    specificQR = try values.decode(Bool.self, forKey: .specificQR)
    schedule = try values.decode(Bool.self, forKey: .schedule)
    deepLink = try values.decode(Bool.self, forKey: .deepLink)
    shortcuts = try values.decodeIfPresent(Bool.self, forKey: .shortcuts) ?? manual
  }
}
