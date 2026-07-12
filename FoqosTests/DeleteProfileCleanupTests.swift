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
        "removeBreakBackstop", "removeOneMoreMinuteBackstop",
      ]
    )
    XCTAssertNil(try BlockedProfiles.findProfile(byID: profile.id, in: context))
  }
}
