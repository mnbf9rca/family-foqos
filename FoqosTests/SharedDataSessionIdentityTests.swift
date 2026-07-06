@preconcurrency import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SharedDataSessionIdentityTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!
  private var suiteName: String!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "SharedDataSessionIdentityTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    container = try TestModelContainer.create()
    context = container.mainContext
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  // #237: an in-app stop of session A must NOT clobber an extension-created session B.
  func testGivenExtensionSessionForOtherProfile_WhenInAppSessionEnds_ThenExtensionSessionUntouched()
    throws
  {
    let now = Date()
    let profileA = BlockedProfiles(name: "A")
    let profileB = BlockedProfiles(name: "B")
    context.insert(profileA)
    context.insert(profileB)
    // App session for A (its snapshot is NOT the shared active session -- the extension replaced it).
    let sessionA = BlockedProfileSession(tag: "A", blockedProfile: profileA)
    context.insert(sessionA)
    try context.save()

    // Extension replaced the shared active session with B's scheduled session (fresh id).
    SharedData.createSessionForScheduler(for: profileB.id)
    let sharedBefore = SharedData.getActiveSharedSession()
    XCTAssertEqual(sharedBefore?.blockedProfileId, profileB.id)
    XCTAssertNotEqual(sharedBefore?.id, sessionA.id, "precondition: shared session is B, not A")

    // Act: user taps Stop on the still-displayed A.
    sessionA.endSession(now: now)

    // Assert: B's shared session is intact -- not end-stamped, not flushed.
    let sharedAfter = SharedData.getActiveSharedSession()
    XCTAssertEqual(sharedAfter?.blockedProfileId, profileB.id, "B must survive the A stop (#237)")
    XCTAssertNil(sharedAfter?.endTime, "B must not be end-stamped by A's stop")
    // A's own SwiftData row still receives its endTime (the local mutation is unconditional).
    XCTAssertEqual(sessionA.endTime, now)
  }

  // The matching case still works: ending the session that owns the shared snapshot clears it.
  func testGivenOwnSharedSession_WhenInAppSessionEnds_ThenSharedSessionFlushed() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Own")
    context.insert(profile)
    let session = BlockedProfileSession(tag: "own", blockedProfile: profile)
    context.insert(session)
    try context.save()

    // App start wrote the shared snapshot with session.id.
    SharedData.createActiveSharedSession(for: session.toSnapshot())
    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, session.id)

    session.endSession(now: now)

    XCTAssertNil(SharedData.getActiveSharedSession(), "own shared session is flushed on stop")
    XCTAssertEqual(session.endTime, now)
  }
}
