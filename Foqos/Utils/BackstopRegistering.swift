import Foundation

/// Main-app-only DeviceActivity backstop registration seam.
protocol BackstopRegistering {
  func replaceBreakBackstop(profileId: UUID, deadline: Date, now: Date) throws
  func replaceOneMoreMinuteBackstop(profileId: UUID, deadline: Date, now: Date) throws
  func registerBreakBackstopIfAbsent(profileId: UUID, deadline: Date, now: Date) throws -> Bool
  func registerOneMoreMinuteBackstopIfAbsent(
    profileId: UUID,
    deadline: Date,
    now: Date
  ) throws -> Bool
  func removeBreakBackstop(profileId: UUID)
  func removeOneMoreMinuteBackstop(profileId: UUID)
  func hasBreakBackstop(profileId: UUID) -> Bool
  func hasOneMoreMinuteBackstop(profileId: UUID) -> Bool
}

struct DeviceActivityBackstopRegistrar: BackstopRegistering {
  func replaceBreakBackstop(profileId: UUID, deadline: Date, now: Date) throws {
    try DeviceActivityCenterUtil.replaceBreakBackstop(
      profileId: profileId, deadline: deadline, now: now)
  }

  func replaceOneMoreMinuteBackstop(profileId: UUID, deadline: Date, now: Date) throws {
    try DeviceActivityCenterUtil.replaceOneMoreMinuteBackstop(
      profileId: profileId, deadline: deadline, now: now)
  }

  func registerBreakBackstopIfAbsent(
    profileId: UUID,
    deadline: Date,
    now: Date
  ) throws -> Bool {
    try DeviceActivityCenterUtil.registerBreakBackstopIfAbsent(
      profileId: profileId, deadline: deadline, now: now)
  }

  func registerOneMoreMinuteBackstopIfAbsent(
    profileId: UUID,
    deadline: Date,
    now: Date
  ) throws -> Bool {
    try DeviceActivityCenterUtil.registerOneMoreMinuteBackstopIfAbsent(
      profileId: profileId, deadline: deadline, now: now)
  }

  func removeBreakBackstop(profileId: UUID) {
    DeviceActivityCenterUtil.removeBreakBackstop(profileId: profileId)
  }

  func removeOneMoreMinuteBackstop(profileId: UUID) {
    DeviceActivityCenterUtil.removeOneMoreMinuteBackstop(profileId: profileId)
  }

  func hasBreakBackstop(profileId: UUID) -> Bool {
    DeviceActivityCenterUtil.hasBreakBackstop(profileId: profileId)
  }

  func hasOneMoreMinuteBackstop(profileId: UUID) -> Bool {
    DeviceActivityCenterUtil.hasOneMoreMinuteBackstop(profileId: profileId)
  }
}
