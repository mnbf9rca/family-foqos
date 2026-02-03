// Foqos/Models/TriggerValidator.swift
import Foundation

/// Stop condition options for UI binding and validation
enum StopOption: String, CaseIterable {
  case manual
  case timer
  case anyNFC
  case specificNFC
  case sameNFC
  case anyQR
  case specificQR
  case sameQR
  case schedule
  case deepLink
}

/// A validation rule with context-aware checking
struct TriggerRule: Sendable {
  let id: String
  let check: @Sendable (ProfileStartTriggers, ProfileStopConditions) -> Bool
  let message: String
  let autoFix: (@Sendable (ProfileStartTriggers, inout ProfileStopConditions) -> Void)?
}

/// Predefined validation rules
enum TriggerRules {
  /// "Same NFC" requires an NFC start trigger
  static let sameNFCRequiresNFCStart = TriggerRule(
    id: "same-nfc-requires-nfc-start",
    check: { start, stop in !stop.sameNFC || start.hasNFC },
    message: "\"Same NFC\" requires an NFC start trigger (Any or Specific)",
    autoFix: { start, stop in
      if !start.hasNFC { stop.sameNFC = false }
    }
  )

  /// "Same QR" requires a QR start trigger
  static let sameQRRequiresQRStart = TriggerRule(
    id: "same-qr-requires-qr-start",
    check: { start, stop in !stop.sameQR || start.hasQR },
    message: "\"Same QR\" requires a QR start trigger (Any or Specific)",
    autoFix: { start, stop in
      if !start.hasQR { stop.sameQR = false }
    }
  )

  /// At least one start trigger required
  static let requiresStartTrigger = TriggerRule(
    id: "requires-start-trigger",
    check: { start, _ in start.isValid },
    message: "At least one start trigger is required",
    autoFix: nil
  )

  /// At least one stop condition required
  static let requiresStopCondition = TriggerRule(
    id: "requires-stop-condition",
    check: { _, stop in stop.isValid },
    message: "At least one stop condition is required",
    autoFix: nil
  )

  static let allRules: [TriggerRule] = [
    sameNFCRequiresNFCStart,
    sameQRRequiresQRStart,
    requiresStartTrigger,
    requiresStopCondition,
  ]
}

/// Validates trigger configurations and provides UI integration
final class TriggerValidator {
  private let rules: [TriggerRule]

  init(rules: [TriggerRule] = TriggerRules.allRules) {
    self.rules = rules
  }

  /// Check if a stop option is available given current start triggers
  func isStopAvailable(_ stop: StopOption, forStart start: ProfileStartTriggers) -> Bool {
    switch stop {
    case .sameNFC: return start.hasNFC
    case .sameQR: return start.hasQR
    default: return true
    }
  }

  /// Get reason why a stop is unavailable
  func unavailabilityReason(_ stop: StopOption, forStart start: ProfileStartTriggers) -> String? {
    switch stop {
    case .sameNFC where !start.hasNFC:
      return "Enable an NFC start trigger to use this"
    case .sameQR where !start.hasQR:
      return "Enable a QR start trigger to use this"
    default:
      return nil
    }
  }

  /// Auto-fix invalid selections when start triggers change
  func autoFix(start: ProfileStartTriggers, stop: inout ProfileStopConditions) {
    for rule in rules {
      rule.autoFix?(start, &stop)
    }
  }

  /// Get all validation errors
  func validate(start: ProfileStartTriggers, stop: ProfileStopConditions) -> [String] {
    rules
      .filter { !$0.check(start, stop) }
      .map { $0.message }
  }
}
