@preconcurrency import FoqosShared
import Foundation

final class RecordingRestrictionApplier: RestrictionApplying {
  enum Call: Equatable {
    case activate(profileId: UUID)
    case deactivate
  }

  private(set) var calls: [Call] = []
  var onActivate: ((SharedData.ProfileSnapshot) -> Void)?
  var onDeactivate: (() -> Void)?

  func activateRestrictions(for profile: SharedData.ProfileSnapshot) {
    calls.append(.activate(profileId: profile.id))
    onActivate?(profile)
  }

  func deactivateRestrictions() {
    calls.append(.deactivate)
    onDeactivate?()
  }
}
