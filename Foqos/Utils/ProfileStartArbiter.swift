import Foundation

enum ProfileStartArbiter {
  enum Decision: Equatable {
    case start
    case reject
    case adopt
  }

  static func decide(
    incomingStartTime: Date,
    incomingProfileId: UUID,
    existingStartTime: Date?,
    existingProfileId: UUID?
  ) -> Decision {
    guard
      let existingStartTime,
      let existingProfileId,
      existingProfileId != incomingProfileId
    else {
      return .start
    }
    if incomingStartTime > existingStartTime { return .adopt }
    if incomingStartTime < existingStartTime { return .reject }
    return incomingProfileId.uuidString > existingProfileId.uuidString ? .adopt : .reject
  }
}
