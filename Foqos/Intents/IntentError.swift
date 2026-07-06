import AppIntents

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
  case profileNotFound
  case sessionAlreadyActive
  case durationOutOfRange
  case noActiveSession(profileName: String)
  case backgroundStopsDisabled(profileName: String)
  case geofenceBlocked(reason: String)
  case stopConditionsNotMet(reason: String)
  case unexpected(String)

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .profileNotFound:
      "Could not find that profile."
    case .sessionAlreadyActive:
      "A session is already active."
    case .durationOutOfRange:
      "Duration must be between 15 minutes and 23 hours 59 minutes."
    case .noActiveSession(let name):
      "\(name) is not currently active."
    case .backgroundStopsDisabled(let name):
      "\(name) cannot be stopped remotely."
    case .geofenceBlocked(let reason):
      "Cannot stop — \(reason)"
    case .stopConditionsNotMet(let reason):
      "\(reason)"
    case .unexpected(let message):
      "\(message)"
    }
  }
}
