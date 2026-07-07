import Foundation

@testable import FamilyFoqos

final class RecordingBackstopRegistrar: BackstopRegistering {
  enum Call: Equatable {
    case replaceBreak(UUID)
    case replaceOMM(UUID)
    case registerBreakIfAbsent(UUID)
    case registerOMMIfAbsent(UUID)
    case removeBreak(UUID)
    case removeOMM(UUID)
  }

  private(set) var calls: [Call] = []
  var throwOnReplaceBreak = false
  var throwOnReplaceOMM = false
  var throwOnRegisterIfAbsent = false
  var hasBreakBackstopReturns = false
  var hasOMMBackstopReturns = false
  private(set) var didStartMonitoringBreak = false
  private(set) var didStartMonitoringOMM = false

  enum Err: Error {
    case configured
  }

  func replaceBreakBackstop(profileId: UUID, deadline: Date, now: Date) throws {
    calls.append(.replaceBreak(profileId))
    if throwOnReplaceBreak { throw Err.configured }
    didStartMonitoringBreak = true
  }

  func replaceOneMoreMinuteBackstop(profileId: UUID, deadline: Date, now: Date) throws {
    calls.append(.replaceOMM(profileId))
    if throwOnReplaceOMM { throw Err.configured }
    didStartMonitoringOMM = true
  }

  func registerBreakBackstopIfAbsent(profileId: UUID, deadline: Date, now: Date) throws -> Bool {
    calls.append(.registerBreakIfAbsent(profileId))
    if throwOnRegisterIfAbsent { throw Err.configured }
    if hasBreakBackstopReturns { return false }
    didStartMonitoringBreak = true
    return true
  }

  func registerOneMoreMinuteBackstopIfAbsent(
    profileId: UUID,
    deadline: Date,
    now: Date
  ) throws -> Bool {
    calls.append(.registerOMMIfAbsent(profileId))
    if throwOnRegisterIfAbsent { throw Err.configured }
    if hasOMMBackstopReturns { return false }
    didStartMonitoringOMM = true
    return true
  }

  func removeBreakBackstop(profileId: UUID) {
    calls.append(.removeBreak(profileId))
  }

  func removeOneMoreMinuteBackstop(profileId: UUID) {
    calls.append(.removeOMM(profileId))
  }

  func hasBreakBackstop(profileId: UUID) -> Bool {
    hasBreakBackstopReturns
  }

  func hasOneMoreMinuteBackstop(profileId: UUID) -> Bool {
    hasOMMBackstopReturns
  }
}
