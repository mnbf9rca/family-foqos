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
      return .cannotStart(reason: "No stop conditions configured. Edit the profile to add one.")
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
      return .cannotStart(reason: "No start triggers configured. Edit the profile to add one.")
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
      } else if conditions.deepLink {
        return .cannotStop(
          reason: "This profile can only be stopped via a programmed NFC tag or QR code")
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
    stopNFCTagId: String?,
    stopQRCodeId: String?
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

    case .nfc(let scannedTag):
      // Check specific NFC first (highest priority)
      if conditions.specificNFC {
        if let requiredTag = stopNFCTagId, scannedTag == requiredTag {
          return .allowed()
        }
        return .denied("Scan the correct NFC tag to stop")
      }

      // Check same NFC (match session tag - must be NFC type)
      if conditions.sameNFC {
        if let sessionStartTag = sessionTag,
          sessionStartTag.hasPrefix("nfc:"),
          scannedTag == String(sessionStartTag.dropFirst(4))
        {
          return .allowed()
        }
        return .denied("Scan the same NFC tag you used to start")
      }

      // Check any NFC
      if conditions.anyNFC {
        return .allowed()
      }

      return .denied("NFC stop is not enabled for this profile")

    case .qr(let scannedCode):
      // Check specific QR first
      if conditions.specificQR {
        if let requiredCode = stopQRCodeId, scannedCode == requiredCode {
          return .allowed()
        }
        return .denied("Scan the correct QR code to stop")
      }

      // Check same QR (match session tag - must be QR type)
      if conditions.sameQR {
        if let sessionStartCode = sessionTag,
          sessionStartCode.hasPrefix("qr:"),
          scannedCode == String(sessionStartCode.dropFirst(3))
        {
          return .allowed()
        }
        return .denied("Scan the same QR code you used to start")
      }

      // Check any QR
      if conditions.anyQR {
        return .allowed()
      }

      return .denied("QR code stop is not enabled for this profile")

    case .schedule:
      if conditions.schedule {
        return .allowed()
      }
      return .denied("Scheduled stop is not enabled for this profile")

    case .deepLink:
      if conditions.deepLink {
        return .allowed()
      }
      return .denied("Deep link stop is not enabled for this profile")
    }
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
  case manual
  case timer
  case nfc(tag: String)
  case qr(code: String)
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
