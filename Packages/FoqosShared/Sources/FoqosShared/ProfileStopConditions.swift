import Foundation

public enum TagStopKind: String, Codable, CaseIterable, Equatable {
  case none, any, same, specific
}

/// Stop-owned settings shared with the app-group monitor and private account sync.
public struct ProfileStopConditions: Codable, Equatable {
  public var manual: Bool
  public var timer: Bool
  public var nfc: TagStopKind
  public var qr: TagStopKind
  public var schedule: Bool
  // Inert in V2; retained only for genuinely active V1 session compatibility.
  public var deepLink: Bool
  public var timerDurationMinutes: Int?
  public var allowChangingTimerBeforeStart: Bool
  /// A nil V1 strategy must be deliberately edited even if modifiers provide a stop.
  public var requiresEditingAfterConversion: Bool

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
    deepLink: Bool = false,
    nfc: TagStopKind? = nil,
    qr: TagStopKind? = nil,
    timerDurationMinutes: Int? = nil,
    allowChangingTimerBeforeStart: Bool = false,
    requiresEditingAfterConversion: Bool = false
  ) {
    self.manual = manual
    self.timer = timer
    self.nfc = nfc ?? (specificNFC ? .specific : sameNFC ? .same : anyNFC ? .any : .none)
    self.qr = qr ?? (specificQR ? .specific : sameQR ? .same : anyQR ? .any : .none)
    self.schedule = schedule
    self.deepLink = deepLink
    self.timerDurationMinutes = timerDurationMinutes
    self.allowChangingTimerBeforeStart = allowChangingTimerBeforeStart
    self.requiresEditingAfterConversion = requiresEditingAfterConversion
  }

  public var anyNFC: Bool {
    get { nfc == .any }
    set {
      if newValue { nfc = .any } else if nfc == .any { nfc = .none }
    }
  }

  public var specificNFC: Bool {
    get { nfc == .specific }
    set {
      if newValue { nfc = .specific } else if nfc == .specific { nfc = .none }
    }
  }

  public var sameNFC: Bool {
    get { nfc == .same }
    set {
      if newValue { nfc = .same } else if nfc == .same { nfc = .none }
    }
  }

  public var anyQR: Bool {
    get { qr == .any }
    set {
      if newValue { qr = .any } else if qr == .any { qr = .none }
    }
  }

  public var specificQR: Bool {
    get { qr == .specific }
    set {
      if newValue { qr = .specific } else if qr == .specific { qr = .none }
    }
  }

  public var sameQR: Bool {
    get { qr == .same }
    set {
      if newValue { qr = .same } else if qr == .same { qr = .none }
    }
  }

  /// Selected-family predicate for existing runtime consumers.
  public var isValid: Bool {
    manual || timer || hasNFC || hasQR || schedule
  }

  public var hasNFC: Bool { nfc != .none }
  public var hasQR: Bool { qr != .none }

  public var requiresPhysicalItemOnly: Bool {
    guard isValid else { return false }
    return !(manual || timer || anyNFC || anyQR || schedule)
  }

  private enum CodingKeys: String, CodingKey {
    case manual, timer, nfc, qr, schedule, deepLink
    case timerDurationMinutes, allowChangingTimerBeforeStart, requiresEditingAfterConversion
    case anyNFC, specificNFC, sameNFC, anyQR, specificQR, sameQR
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    manual = try values.decodeIfPresent(Bool.self, forKey: .manual) ?? false
    timer = try values.decodeIfPresent(Bool.self, forKey: .timer) ?? false
    schedule = try values.decodeIfPresent(Bool.self, forKey: .schedule) ?? false
    deepLink = try values.decodeIfPresent(Bool.self, forKey: .deepLink) ?? false
    timerDurationMinutes = try values.decodeIfPresent(Int.self, forKey: .timerDurationMinutes)
    allowChangingTimerBeforeStart = try values.decodeIfPresent(Bool.self, forKey: .allowChangingTimerBeforeStart) ?? false
    requiresEditingAfterConversion = try values.decodeIfPresent(Bool.self, forKey: .requiresEditingAfterConversion) ?? false

    func kind(_ key: CodingKeys, any: CodingKeys, same: CodingKeys, specific: CodingKeys) throws -> TagStopKind {
      if values.contains(key) { return try values.decode(TagStopKind.self, forKey: key) }
      // Decode every legacy flag so an invalid sibling cannot silently broaden a stop.
      let anyValue = try values.contains(any) ? values.decode(Bool.self, forKey: any) : false
      let sameValue = try values.contains(same) ? values.decode(Bool.self, forKey: same) : false
      let specificValue = try values.contains(specific) ? values.decode(Bool.self, forKey: specific) : false
      return specificValue ? .specific : sameValue ? .same : anyValue ? .any : .none
    }
    nfc = try kind(.nfc, any: .anyNFC, same: .sameNFC, specific: .specificNFC)
    qr = try kind(.qr, any: .anyQR, same: .sameQR, specific: .specificQR)
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(manual, forKey: .manual)
    try values.encode(timer, forKey: .timer)
    try values.encode(nfc, forKey: .nfc)
    try values.encode(qr, forKey: .qr)
    try values.encode(schedule, forKey: .schedule)
    try values.encode(deepLink, forKey: .deepLink)
    try values.encodeIfPresent(timerDurationMinutes, forKey: .timerDurationMinutes)
    try values.encode(allowChangingTimerBeforeStart, forKey: .allowChangingTimerBeforeStart)
    try values.encode(requiresEditingAfterConversion, forKey: .requiresEditingAfterConversion)
  }
}
