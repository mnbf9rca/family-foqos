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
      let expectedProfiles = [
        "86152CDC-41B7-4668-BCA1-866042328FAB": "RC Library 01",
        "0EDD005A-2507-4AAA-AA77-3D12CD2B156B": "RC Library 02",
        "88D71748-FA0A-4BE0-A5B5-165FD2AB9717": "RC Library 03",
        "4C7ACA1A-DFCB-4598-9AF7-B23A241E9984": "RC Library 04",
        "A3CC4277-930B-4651-982A-913D1EB8D7F3": "RC Library 05",
        "AAD5123F-45CF-4B06-9B46-9CC19248833E": "RC Library 06",
        "A9720E7C-5522-4488-8A05-4DA9B14417A8": "RC Library 07",
        "4C58D3CE-8328-4564-A3C0-9ACA1F9C3131": "RC Library 08",
        "F0C426B3-E942-4A83-99E3-ACDA1CB788C1": "RC Library 09",
        "91FAAE95-6ABB-44EF-B935-0F4993FEEE53": "RC Library 10",
        "146526B7-9EC9-4FCD-8CFA-8658966D2CA1": "RC Library 11",
        "D94E43CD-4320-4FC6-9A47-99388194D901": "RC Library 12",
        "D62A7FC9-9F2B-4C04-B366-1547365231C3": "RC Library 13",
        "F19EC56F-AACA-4564-808D-970DCED9194E": "RC Library 14",
        "1BACE5B3-2ABB-4721-8230-352CBBBBAE21": "RC Library 15",
        "297974FE-CE00-486B-857B-97F1CBA17FEB": "RC Library 16",
        "49994F60-DA98-49B2-A559-C68AE7F69EE8": "RC Library 17",
        "C4BDF73B-2CC9-46BD-86A2-931AA41E454C": "RC Library 18",
        "2833CD8B-8E1C-44AD-8ECE-5147E450CFF4": "RC Library 19",
        "53ED51F9-320A-4478-A420-B9DD85CD8F84": "RC Library 20",
        "530A3017-2B80-4F10-A7A7-6FD72872E9B3": "RC Library 21",
        "6EF7F9AE-6072-4D49-A157-8621ECD10936": "RC Library 22",
        "48A0F2F5-8142-4F48-AC0D-973089AC0F7B": "RC Library 23",
        "AE9FA0D3-9A29-4907-9A29-D5CE2030D2DA": "RC Library 24",
      ]
      XCTAssertEqual(Set(profiles.map { $0.id.uuidString }), Set(expectedProfiles.keys))
      for profile in profiles {
        XCTAssertEqual(profile.name, expectedProfiles[profile.id.uuidString])
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
