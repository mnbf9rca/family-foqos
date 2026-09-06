@preconcurrency import FoqosShared
import Foundation

final class RecordingRestrictionApplier: RestrictionApplying {
  enum Call: Equatable {
    case activate(profileId: UUID)
    case deactivate
  }

  private(set) var calls: [Call] = []
  private(set) var denyAppRemoval = false
  var onActivate: ((SharedData.ProfileSnapshot) -> Void)?
  var onDeactivate: (() -> Void)?

  func clearForAssertion() {
    calls.removeAll()
  }

  func activateRestrictions(for profile: SharedData.ProfileSnapshot) {
    denyAppRemoval = profile.enableStrictMode
    calls.append(.activate(profileId: profile.id))
    onActivate?(profile)
  }

  func deactivateRestrictions() {
    deactivateRestrictions(keepingAppRemovalDenied: false)
  }

  func deactivateRestrictions(keepingAppRemovalDenied: Bool) {
    denyAppRemoval = keepingAppRemovalDenied
    calls.append(.deactivate)
    onDeactivate?()
  }
}
