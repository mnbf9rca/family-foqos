// Foqos/Models/ProfileStopConditions.swift
import Foundation

/// Defines which conditions can end a blocking session for a profile.
/// Multiple conditions can be enabled simultaneously.
struct ProfileStopConditions: Codable, Equatable {
  var manual: Bool = false
  var timer: Bool = false
  var anyNFC: Bool = false
  var specificNFC: Bool = false
  var sameNFC: Bool = false
  var anyQR: Bool = false
  var specificQR: Bool = false
  var sameQR: Bool = false
  var schedule: Bool = false
  var deepLink: Bool = false

  /// True if at least one condition is selected
  var isValid: Bool {
    manual || timer || anyNFC || specificNFC || sameNFC
      || anyQR || specificQR || sameQR || schedule || deepLink
  }

  /// True if every enabled stop condition requires a specific physical item.
  /// When this is true the user risks being unable to stop the profile if they
  /// lose access to the required item. Emergency Unblock (limited to 3 per 4 weeks)
  /// would be the only escape.
  var requiresPhysicalItemOnly: Bool {
    guard isValid else { return false }
    let hasAlwaysAvailable = manual || timer || anyNFC || anyQR || schedule
    return !hasAlwaysAvailable
  }
}
