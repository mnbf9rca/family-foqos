// Foqos/Models/ProfileScheduleTime.swift
import Foundation

/// A time-of-day schedule for starting or stopping a profile.
/// Independent from the existing BlockedProfileSchedule which combines start and stop.
struct ProfileScheduleTime: Codable, Equatable {
  var days: [Weekday]
  var hour: Int
  var minute: Int
  var updatedAt: Date

  var isActive: Bool { !days.isEmpty }
}
