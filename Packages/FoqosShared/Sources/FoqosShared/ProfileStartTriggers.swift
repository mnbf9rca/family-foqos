import Foundation

/// Defines which triggers can start a blocking session for a profile.
/// Multiple triggers can be enabled simultaneously.
public struct ProfileStartTriggers: Codable, Equatable {
  public var manual: Bool = false
  public var anyNFC: Bool = false
  public var specificNFC: Bool = false
  public var anyQR: Bool = false
  public var specificQR: Bool = false
  public var schedule: Bool = false
  public var deepLink: Bool = false
  public var shortcuts: Bool = false

  /// True if any NFC start trigger is enabled
  public var hasNFC: Bool { anyNFC || specificNFC }

  /// True if any QR start trigger is enabled
  public var hasQR: Bool { anyQR || specificQR }

  /// True if at least one trigger is selected
  public var isValid: Bool {
    manual || anyNFC || specificNFC || anyQR || specificQR || schedule || deepLink || shortcuts
  }
  public init(
    manual: Bool = false, anyNFC: Bool = false, specificNFC: Bool = false,
    anyQR: Bool = false, specificQR: Bool = false, schedule: Bool = false,
    deepLink: Bool = false, shortcuts: Bool = false
  ) {
    self.manual = manual
    self.anyNFC = anyNFC
    self.specificNFC = specificNFC
    self.anyQR = anyQR
    self.specificQR = specificQR
    self.schedule = schedule
    self.deepLink = deepLink
    self.shortcuts = shortcuts
  }

}

// Preserve the shipped V1/V2 start-trigger wire format.
extension ProfileStartTriggers {
  enum CodingKeys: String, CodingKey {
    case manual, anyNFC, specificNFC, anyQR, specificQR, schedule, deepLink, shortcuts
  }

  public init(from decoder: Decoder) throws {
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
