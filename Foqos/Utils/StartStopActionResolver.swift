import FoqosShared
import Foundation

/// Pure functions for determining start/stop actions and validating stop methods.
/// No instance state — all methods are static.
@MainActor
enum StartStopActionResolver {

  static let availableStrategies: [BlockingStrategy] = [
    ManualBlockingStrategy(),
    NFCBlockingStrategy(),
    NFCManualBlockingStrategy(),
    NFCTimerBlockingStrategy(),
    QRCodeBlockingStrategy(),
    QRManualBlockingStrategy(),
    QRTimerBlockingStrategy(),
    ShortcutTimerBlockingStrategy(),
  ]

  static func getStrategyFromId(id: String) -> BlockingStrategy {
    switch id {
    case ManualBlockingStrategy.id: return ManualBlockingStrategy()
    case NFCBlockingStrategy.id: return NFCBlockingStrategy()
    case NFCManualBlockingStrategy.id: return NFCManualBlockingStrategy()
    case NFCTimerBlockingStrategy.id: return NFCTimerBlockingStrategy()
    case QRCodeBlockingStrategy.id: return QRCodeBlockingStrategy()
    case QRManualBlockingStrategy.id: return QRManualBlockingStrategy()
    case QRTimerBlockingStrategy.id: return QRTimerBlockingStrategy()
    case ShortcutTimerBlockingStrategy.id: return ShortcutTimerBlockingStrategy()
    default: return NFCBlockingStrategy()
    }
  }

  // MARK: - Start Action Determination

  /// Determines what action to take based on enabled start triggers.
  /// - Parameters:
  ///   - triggers: The profile's start triggers.
  ///   - stopConditions: The profile's stop conditions. Pass `nil` to skip
  ///     stop-condition validation (e.g., in tests). An empty `ProfileStopConditions()`
  ///     with no conditions enabled will return `.cannotStart`.
  static func determineStartAction(
    for triggers: ProfileStartTriggers,
    stopConditions: ProfileStopConditions? = nil
  ) -> StartAction {
    // Guard: don't allow starting if stop conditions are missing
    if let stop = stopConditions, !stop.isValid {
      return .cannotStart(reason: "Please edit this profile before starting. Its start and stop settings need updating.")
    }

    var manualOptions: [StartAction] = []

    if triggers.manual {
      manualOptions.append(.startImmediately)
    }
    if triggers.hasNFC {
      manualOptions.append(.scanNFC)
    }
    if triggers.hasQR {
      manualOptions.append(.scanQR)
    }

    // If no manual options but has schedule/deeplink only
    if manualOptions.isEmpty {
      if triggers.schedule {
        return .waitForSchedule
      }
      if triggers.deepLink {
        return .deepLinkOnly
      }
      if triggers.shortcuts {
        return .cannotStart(reason: "Start this profile with Siri or Shortcuts.")
      }
      return .cannotStart(reason: "Please edit this profile before starting. Its start and stop settings need updating.")
    }

    // Single option - do it directly
    if manualOptions.count == 1 {
      return manualOptions[0]
    }

    // Multiple options - show picker
    return .showPicker(options: manualOptions)
  }

  // MARK: - Stop Action Determination

  /// Determines the appropriate stop action based on the profile's stop conditions.
  /// Priority: manual (immediate) > single scan method > picker for multiple scan methods.
  static func determineStopAction(
    for conditions: ProfileStopConditions
  ) -> StopAction {
    if conditions.manual {
      return .stopImmediately
    }

    var scanOptions: [StopAction] = []
    if conditions.hasNFC {
      scanOptions.append(.scanNFC)
    }
    if conditions.hasQR {
      scanOptions.append(.scanQR)
    }

    if scanOptions.isEmpty {
      if conditions.timer && conditions.schedule {
        return .cannotStop(reason: "This profile stops on a timer or at its scheduled time")
      } else if conditions.timer {
        return .cannotStop(reason: "This profile can only be stopped when the timer runs out")
      } else if conditions.schedule {
        return .cannotStop(reason: "This profile stops at its scheduled time")

      }
      return .cannotStop(reason: "This profile has no manual stop method configured")
    }
    if scanOptions.count == 1 {
      return scanOptions[0]
    }
    return .showPicker(options: scanOptions)
  }

  // MARK: - Stop Validation

  /// Validates whether a stop method is allowed given profile configuration
  static func canStop(
    with method: StopMethod,
    conditions: ProfileStopConditions,
    sessionTag: String?,
    stopNFCTagIds: [String],
    stopQRCodeIds: [String],
    sessionOrigin: SessionOrigin? = nil, legacySession: Bool = false
  ) -> StopValidationResult {

    switch method {
    case .manual:
      if conditions.manual {
        return .allowed()
      }
      return .denied("Manual stop is not enabled for this profile")

    case .timer:
      if conditions.timer {
        return .allowed()
      }
      return .denied("Timer stop is not enabled for this profile")

    case .nfc(let key):
      return canStopTag(
        TagEvent(type: .nfc, namespace: .nfcUID, key: key), conditions: conditions,
        sessionTag: sessionTag, nfcKeys: stopNFCTagIds, qrKeys: stopQRCodeIds, origin: sessionOrigin, legacySession: legacySession)
    case .qr(let key, let raw):
      return canStopTag(
        TagEvent(type: .qr, namespace: .qrDigest, key: key, rawKey: raw), conditions: conditions,
        sessionTag: sessionTag, nfcKeys: stopNFCTagIds, qrKeys: stopQRCodeIds, origin: sessionOrigin, legacySession: legacySession)
    case .tag(let event):
      return canStopTag(
        event, conditions: conditions, sessionTag: sessionTag,
        nfcKeys: stopNFCTagIds, qrKeys: stopQRCodeIds, origin: sessionOrigin, legacySession: legacySession)

    case .schedule:
      if conditions.schedule {
        return .allowed()
      }
      return .denied("Scheduled stop is not enabled for this profile")

    case .deepLink:
      if legacySession && conditions.deepLink {
        return .allowed()
      }
      return .denied("Deep link stop is not enabled for this profile")
    }
  }
  private static func canStopTag(
    _ event: TagEvent, conditions: ProfileStopConditions,
    sessionTag: String?, nfcKeys: [String], qrKeys: [String], origin: SessionOrigin?, legacySession: Bool
  ) -> StopValidationResult {
    let kind = event.type == .nfc ? conditions.nfc : conditions.qr
    let keys = event.type == .nfc ? nfcKeys : qrKeys
    let originKind: SessionOrigin.Kind = event.type == .nfc ? .nfc : .qr
    let wrong = event.type == .nfc ? "That NFC tag doesn’t match. Scan the required tag." : "That QR code doesn’t match. Scan the required code."
    switch kind {
    case .none:
      return .denied(event.type == .nfc ? "NFC stop is not enabled for this profile" : "QR code stop is not enabled for this profile")
    case .any: return .allowed()
    case .specific:
      if keys.contains(where: event.matchesStoredKey) { return .allowed() }
    case .same:
      if origin?.kind == originKind {
        if origin?.isUnidentifiedLegacyTag == true { return .allowed() }
        if origin?.namespace == event.namespace, let key = origin?.initiatingKey,
          event.matchesStoredKey(key)
        {
          return .allowed()
        }
      }
      if legacySession, let tag = sessionTag, tag.hasPrefix(event.type.rawValue + ":"),
        event.namespace == (event.type == .nfc ? .nfcUID : .qrDigest)
      {
        let key = String(tag.dropFirst(event.type.rawValue.count + 1))
        if key == event.key || key == event.rawKey { return .allowed() }
      }
    }
    return .denied(wrong)
  }

}

/// Action to take when user taps Start button
enum StartAction: Equatable, Hashable {
  case startImmediately
  case scanNFC
  case scanQR
  case waitForSchedule
  case deepLinkOnly
  case cannotStart(reason: String)
  indirect case showPicker(options: [StartAction])
}

/// Action to take when user taps Stop button
enum StopAction: Equatable, Hashable {
  case stopImmediately
  case scanNFC
  case scanQR
  case cannotStop(reason: String)
  indirect case showPicker(options: [StopAction])
}

/// How a stop was triggered
enum StopMethod {
  case tag(TagEvent)
  case manual
  case timer
  case nfc(tag: String)
  case qr(code: String, rawHash: String? = nil)
  case schedule
  case deepLink
}

/// Result of stop validation
struct StopValidationResult {
  let allowed: Bool
  let errorMessage: String?

  static func allowed() -> StopValidationResult {
    StopValidationResult(allowed: true, errorMessage: nil)
  }

  static func denied(_ message: String) -> StopValidationResult {
    StopValidationResult(allowed: false, errorMessage: message)
  }
}
