import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class DeleteProfileCleanupTests: XCTestCase {
  func testGivenProfileDelete_WhenDeleting_ThenRemovesSchedulesRemindersAndDeadlineBackstops()
    throws
  {
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Homework")
    context.insert(profile)
    try context.save()

    var cleanupActions: [String] = []
    let cleanup = BlockedProfiles.DeleteCleanup(
      removeStartSchedule: { _ in cleanupActions.append("removeStartSchedule") },
      removeStopSchedule: { _ in cleanupActions.append("removeStopSchedule") },
      cancelPreActivationReminders: { _ in
        cleanupActions.append("cancelPreActivationReminders")
      },
      cancelSessionAndBreakReminders: { profileId in
        XCTAssertEqual(profileId, profile.id)
        cleanupActions.append("cancelSessionAndBreakReminders")
      },
      removeBreakBackstop: { profileId in
        XCTAssertEqual(profileId, profile.id)
        cleanupActions.append("removeBreakBackstop")
      },
      removeOneMoreMinuteBackstop: { profileId in
        XCTAssertEqual(profileId, profile.id)
        cleanupActions.append("removeOneMoreMinuteBackstop")
      }
    )

    try BlockedProfiles.deleteProfile(profile, in: context, cleanup: cleanup)

    XCTAssertEqual(
      cleanupActions,
      [
        "removeStartSchedule", "removeStopSchedule", "cancelPreActivationReminders",
        "cancelSessionAndBreakReminders", "removeBreakBackstop", "removeOneMoreMinuteBackstop",
      ]
    )
    XCTAssertNil(try BlockedProfiles.findProfile(byID: profile.id, in: context))
  }
  func testDeletingProfileCancelsOnlyItsActiveExactTimer() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Timed", createdAt: now, updatedAt: now)
    context.insert(profile)
    let active = BlockedProfileSession(
      tag: "manual", blockedProfile: profile, startTime: now,
      origin: .init(kind: .manual))
    context.insert(active)
    let ended = BlockedProfileSession(tag: "old", blockedProfile: profile, startTime: now.addingTimeInterval(-100))
    ended.endTime = now.addingTimeInterval(-10)
    context.insert(ended)
    try context.save()
    let activeId = active.id
    var cancellations: [String] = []
    let cleanup = BlockedProfiles.DeleteCleanup(
      removeStartSchedule: { _ in }, removeStopSchedule: { _ in },
      cancelPreActivationReminders: { _ in }, cancelSessionAndBreakReminders: { _ in },
      removeBreakBackstop: { _ in }, removeOneMoreMinuteBackstop: { _ in },
      cancelStrategyTimer: { id, sessionId in
        XCTAssertEqual(id, profile.id)
        cancellations.append(sessionId)
      })
    try BlockedProfiles.deleteProfile(profile, in: context, cleanup: cleanup)
    XCTAssertEqual(cancellations, [activeId])
  }

}
