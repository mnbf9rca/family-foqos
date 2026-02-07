// Foqos/Models/TriggerPickerOptions.swift
import Foundation

// MARK: - NFC Start

enum NFCStartOption: String, CaseIterable, Identifiable {
  case none
  case any
  case specific

  var id: String { rawValue }

  var label: String {
    switch self {
    case .none: return "None"
    case .any: return "Any tag"
    case .specific: return "Specific tag"
    }
  }

  static func from(_ triggers: ProfileStartTriggers) -> NFCStartOption {
    if triggers.anyNFC { return .any }
    if triggers.specificNFC { return .specific }
    return .none
  }

  func apply(to triggers: inout ProfileStartTriggers) {
    triggers.anyNFC = (self == .any)
    triggers.specificNFC = (self == .specific)
  }
}

// MARK: - NFC Stop

enum NFCStopOption: String, CaseIterable, Identifiable {
  case none
  case any
  case same
  case specific

  var id: String { rawValue }

  var label: String {
    switch self {
    case .none: return "None"
    case .any: return "Any tag"
    case .same: return "Same tag"
    case .specific: return "Specific tag"
    }
  }

  static func from(_ conditions: ProfileStopConditions) -> NFCStopOption {
    if conditions.anyNFC { return .any }
    if conditions.sameNFC { return .same }
    if conditions.specificNFC { return .specific }
    return .none
  }

  func apply(to conditions: inout ProfileStopConditions) {
    conditions.anyNFC = (self == .any)
    conditions.sameNFC = (self == .same)
    conditions.specificNFC = (self == .specific)
  }

  static func availableOptions(forStart start: ProfileStartTriggers) -> [NFCStopOption] {
    if start.hasNFC {
      return [.none, .any, .same, .specific]
    }
    return [.none, .any, .specific]
  }
}

// MARK: - QR Start

enum QRStartOption: String, CaseIterable, Identifiable {
  case none
  case any
  case specific

  var id: String { rawValue }

  var label: String {
    switch self {
    case .none: return "None"
    case .any: return "Any code"
    case .specific: return "Specific code"
    }
  }

  static func from(_ triggers: ProfileStartTriggers) -> QRStartOption {
    if triggers.anyQR { return .any }
    if triggers.specificQR { return .specific }
    return .none
  }

  func apply(to triggers: inout ProfileStartTriggers) {
    triggers.anyQR = (self == .any)
    triggers.specificQR = (self == .specific)
  }
}

// MARK: - QR Stop

enum QRStopOption: String, CaseIterable, Identifiable {
  case none
  case any
  case same
  case specific

  var id: String { rawValue }

  var label: String {
    switch self {
    case .none: return "None"
    case .any: return "Any code"
    case .same: return "Same code"
    case .specific: return "Specific code"
    }
  }

  static func from(_ conditions: ProfileStopConditions) -> QRStopOption {
    if conditions.anyQR { return .any }
    if conditions.sameQR { return .same }
    if conditions.specificQR { return .specific }
    return .none
  }

  func apply(to conditions: inout ProfileStopConditions) {
    conditions.anyQR = (self == .any)
    conditions.sameQR = (self == .same)
    conditions.specificQR = (self == .specific)
  }

  static func availableOptions(forStart start: ProfileStartTriggers) -> [QRStopOption] {
    if start.hasQR {
      return [.none, .any, .same, .specific]
    }
    return [.none, .any, .specific]
  }
}
