import Foundation

/// Defines which conditions can end a blocking session for a profile.
/// Multiple conditions can be enabled simultaneously.
/// Lives in FoqosShared so the DeviceActivity monitor extension can evaluate
/// stop conditions from the app-group ProfileSnapshot (it has no StartStopActionResolver).
public struct ProfileStopConditions: Codable, Equatable {
  public var manual: Bool
  public var timer: Bool
  public var anyNFC: Bool
  public var specificNFC: Bool
  public var sameNFC: Bool
  public var anyQR: Bool
  public var specificQR: Bool
  public var sameQR: Bool
  public var schedule: Bool
  public var deepLink: Bool

  public init(
    manual: Bool = false,
    timer: Bool = false,
    anyNFC: Bool = false,
    specificNFC: Bool = false,
    sameNFC: Bool = false,
    anyQR: Bool = false,
    specificQR: Bool = false,
    sameQR: Bool = false,
    schedule: Bool = false,
    deepLink: Bool = false
  ) {
    self.manual = manual
    self.timer = timer
    self.anyNFC = anyNFC
    self.specificNFC = specificNFC
    self.sameNFC = sameNFC
    self.anyQR = anyQR
    self.specificQR = specificQR
    self.sameQR = sameQR
    self.schedule = schedule
    self.deepLink = deepLink
  }

  /// True if at least one condition is selected
  public var isValid: Bool {
    manual || timer || anyNFC || specificNFC || sameNFC
      || anyQR || specificQR || sameQR || schedule || deepLink
  }

  /// True if any NFC stop condition is enabled
  public var hasNFC: Bool { anyNFC || sameNFC || specificNFC }

  /// True if any QR stop condition is enabled
  public var hasQR: Bool { anyQR || sameQR || specificQR }

  /// True if every enabled stop condition requires a specific physical item.
  /// When this is true the user risks being unable to stop the profile if they
  /// lose access to the required item. Emergency Unblock (limited to 3 per 4 weeks)
  /// would be the only escape.
  public var requiresPhysicalItemOnly: Bool {
    guard isValid else { return false }
    let hasAlwaysAvailable = manual || timer || anyNFC || anyQR || schedule
    return !hasAlwaysAvailable
  }
}
