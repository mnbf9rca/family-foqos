import FoqosShared
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
    switch conditions.nfc {
    case .none: return .none
    case .any: return .any
    case .same: return .same
    case .specific: return .specific
    }
  }

  func apply(to conditions: inout ProfileStopConditions) {
    switch self {
    case .none: conditions.nfc = .none
    case .any: conditions.nfc = .any
    case .same: conditions.nfc = .same
    case .specific: conditions.nfc = .specific
    }
  }

  static func availableOptions(forStart start: ProfileStartTriggers) -> [NFCStopOption] { allCases }

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
    switch conditions.qr {
    case .none: return .none
    case .any: return .any
    case .same: return .same
    case .specific: return .specific
    }
  }

  func apply(to conditions: inout ProfileStopConditions) {
    switch self {
    case .none: conditions.qr = .none
    case .any: conditions.qr = .any
    case .same: conditions.qr = .same
    case .specific: conditions.qr = .specific
    }
  }

  static func availableOptions(forStart start: ProfileStartTriggers) -> [QRStopOption] { allCases }

}
