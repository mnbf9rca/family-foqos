import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class V1StoreMigrationTests: XCTestCase {
  func testCapturedV1LibraryStoreMigratesWithoutLosingRows() throws {
    let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "v1-library", withExtension: "store"))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = directory.appendingPathComponent("default.store")
    try FileManager.default.copyItem(at: fixture, to: store)

    try autoreleasepool {
      // Use the production schema/configuration, not a test-only destination model.
      let container = try ModelContainer(for: AppModelStore.schema, configurations: [AppModelStore.makeConfiguration(url: store)])
      let context = ModelContext(container)
      let locations = try context.fetch(FetchDescriptor<SavedLocation>())
      XCTAssertEqual(locations.count, 1)
      let location = try XCTUnwrap(locations.first)
      XCTAssertEqual(location.id.uuidString, "4F1EB7D8-543B-4BA7-8AC0-96D5FAC8289E")
      XCTAssertEqual(location.name, "RC Study")
      XCTAssertEqual(location.latitude, 51.5054)
      XCTAssertEqual(location.longitude, -0.0235)
      XCTAssertEqual(location.defaultRadiusMeters, 500)
      XCTAssertFalse(location.isLocked)
      XCTAssertEqual(location.createdAt.timeIntervalSinceReferenceDate, 812830159.972465, accuracy: 0.000001)
      XCTAssertEqual(location.updatedAt, location.createdAt)
      XCTAssertEqual(location.syncVersion, 0)

      let profiles = try context.fetch(FetchDescriptor<BlockedProfiles>())
      XCTAssertEqual(profiles.count, 24)
      for profile in profiles {
        XCTAssertEqual(profile.profileSchemaVersion, 1)
        XCTAssertFalse(profile.blockAdultWebsites)
        XCTAssertFalse(profile.blockAppInstallation)
        XCTAssertTrue(profile.startNFCTagIds.isEmpty)
        XCTAssertTrue(profile.startQRCodeIds.isEmpty)
        XCTAssertTrue(profile.stopNFCTagIds.isEmpty)
        XCTAssertTrue(profile.stopQRCodeIds.isEmpty)
      }
      let sessions = try context.fetch(FetchDescriptor<BlockedProfileSession>())
      XCTAssertEqual(sessions.count, 1)
      let session = try XCTUnwrap(sessions.first)
      XCTAssertEqual(session.id, "513DAD0E-BD8E-46F1-8922-529ECF11BA1C")
      XCTAssertEqual(session.tag, "ManualBlockingStrategy")
      XCTAssertEqual(session.blockedProfile.name, "RC Library 24")
      XCTAssertTrue(session.blockedProfile.sessions.contains { $0.id == session.id })
      XCTAssertEqual(session.startTime.timeIntervalSinceReferenceDate, 812822959.972465, accuracy: 0.000001)
      XCTAssertEqual(try XCTUnwrap(session.endTime).timeIntervalSinceReferenceDate, 812826559.972465, accuracy: 0.000001)
      XCTAssertFalse(session.forceStarted)
      XCTAssertFalse(session.oneMoreMinuteUsed)
      XCTAssertFalse(session.sessionStartSyncPending)
      XCTAssertNil(session.timerEndTime)
      XCTAssertNil(session.origin)
      XCTAssertEqual(try context.fetchCount(FetchDescriptor<SavedTag>()), 0)

      location.syncVersion = 7
      try context.save()
    }

    // A normal reopen retains a saved counter rather than applying the migration default again.
    let reopened = try ModelContainer(for: AppModelStore.schema, configurations: [AppModelStore.makeConfiguration(url: store)])
    let context = ModelContext(reopened)
    XCTAssertEqual(try context.fetch(FetchDescriptor<SavedLocation>()).first?.syncVersion, 7)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<BlockedProfiles>()), 24)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<BlockedProfileSession>()), 1)
  }
}
