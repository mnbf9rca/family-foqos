import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class DeleteProfileCleanupTests: XCTestCase {
  func testGivenProfileDelete_WhenDeleting_ThenRemovesBothSchedulesAndPreActivationReminders()
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
      }
    )

    try BlockedProfiles.deleteProfile(profile, in: context, cleanup: cleanup)

    XCTAssertEqual(
      cleanupActions,
      ["removeStartSchedule", "removeStopSchedule", "cancelPreActivationReminders"]
    )
    XCTAssertNil(try BlockedProfiles.findProfile(byID: profile.id, in: context))
  }
}
