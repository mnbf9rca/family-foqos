import CloudKit
import ManagedSettings
import SwiftData
import XCTest

@testable import FamilyFoqos
@testable import FoqosShared

@MainActor
final class ProfileSafetyOptionsTests: XCTestCase {
  private let suiteName = "ProfileSafetyOptionsTests-\(UUID().uuidString)"
  private let safetyStore = ManagedSettingsStore(named: .init("familyFoqosProfileSafety"))

  override func setUp() async throws {
    try await super.setUp()
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    AppBlockerUtil().deactivateRestrictions()
    safetyStore.clearAllSettings()
  }

  override func tearDown() async throws {
    AppBlockerUtil().deactivateRestrictions()
    safetyStore.clearAllSettings()
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  private func snapshot(adult: Bool, installs: Bool, allow: Bool = false, now: Date) throws
    -> SharedData.ProfileSnapshot
  {
    let profile = BlockedProfiles(
      name: "Safety", createdAt: now, updatedAt: now,
      enableStrictMode: true, enableAllowModeDomains: allow, domains: ["example.com"])
    var json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(BlockedProfiles.getSnapshot(for: profile)))
        as? [String: Any])
    json["blockAdultWebsites"] = adult
    json["blockAppInstallation"] = installs
    return try JSONDecoder().decode(
      SharedData.ProfileSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
  }

  func testGivenSafetyFlags_WhenActivated_ThenIndependentPoliciesComposeAndReplacePreviousFlags() throws {
    let now = Date()
    let applier = AppBlockerUtil()
    for allow in [false, true] {
      for (adult, installs) in [(true, true), (false, true), (true, false), (false, false)] {
        let profile = try snapshot(adult: adult, installs: installs, allow: allow, now: now)
        applier.activateRestrictions(for: profile)
        let domains: Set<WebDomain> = [.init(domain: "example.com")]
        XCTAssertEqual(applier.store.webContent.blockedByFilter, allow ? .all(except: domains) : .specific(domains))
        XCTAssertEqual(safetyStore.webContent.blockedByFilter, adult ? .auto([], except: []) : nil)
        XCTAssertEqual(safetyStore.application.denyAppInstallation == true, installs)
      }
    }
  }

  func testGivenSafetyFlags_WhenGrantReconstructsThenSessionEnds_ThenPinSurvivesAndBothStoresClear() throws {
    let now = Date()
    for isBreak in [true, false] {
      for (adult, installs) in [(true, true), (false, true), (true, false), (false, false)] {
        let profile = try snapshot(adult: adult, installs: installs, now: now)
        let applier = AppBlockerUtil()
        applier.activateRestrictions(for: profile)
        SharedData.createActiveSharedSession(
          for: .init(
            id: "s", tag: "t", blockedProfileId: profile.id, startTime: now, forceStarted: false))
        let open = isBreak ? SharedData.openBreakGrant : SharedData.openOneMoreMinuteGrant
        XCTAssertTrue(open(now, now.addingTimeInterval(60), "s", profile, applier))
        XCTAssertNil(applier.store.webContent.blockedByFilter)
        XCTAssertEqual(safetyStore.webContent.blockedByFilter, adult ? .auto([], except: []) : nil)
        XCTAssertEqual(safetyStore.application.denyAppInstallation == true, installs)
        XCTAssertEqual(applier.store.application.denyAppRemoval, true)

        let conflictingLive = try snapshot(adult: !adult, installs: !installs, now: now)
        applier.activateRestrictions(for: conflictingLive)
        SharedData.applyRestrictionsForCurrentState(
          process: .monitorExtension, liveSnapshot: conflictingLive, applier: AppBlockerUtil())
        XCTAssertEqual(safetyStore.webContent.blockedByFilter, adult ? .auto([], except: []) : nil)
        XCTAssertEqual(safetyStore.application.denyAppInstallation == true, installs)

        var ended = try XCTUnwrap(SharedData.getActiveSharedSession())
        ended.endTime = now.addingTimeInterval(1)
        SharedData.createActiveSharedSession(for: ended)
        SharedData.applyRestrictionsForCurrentState(
          process: .mainApp, liveSnapshot: profile, applier: applier)
        XCTAssertNil(safetyStore.webContent.blockedByFilter)
        XCTAssertNotEqual(safetyStore.application.denyAppInstallation, true)
        XCTAssertNotEqual(applier.store.application.denyAppRemoval, true)
        applier.activateRestrictions(for: profile)
        applier.deactivateRestrictions()
        XCTAssertNil(safetyStore.webContent.blockedByFilter)
        XCTAssertNotEqual(safetyStore.application.denyAppInstallation, true)
      }
    }
  }

  func testGivenNewSnapshotFields_WhenDecodedAndEncoded_ThenBothSurvive() throws {
    let now = Date()
    let profile = try snapshot(adult: true, installs: true, now: now)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
    XCTAssertEqual(json["blockAdultWebsites"] as? Bool, true)
    XCTAssertEqual(json["blockAppInstallation"] as? Bool, true)
  }

  func testGivenCloudKitFields_WhenDecodedAndEncoded_ThenBothSurviveAndLegacyDefaultsOff() throws {
    let now = Date()
    let source = BlockedProfiles(name: "Safety", createdAt: now, updatedAt: now)
    let zone = CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
    let record = SyncedProfile(from: source, originDeviceId: "device-A").toCKRecord(in: zone)
    for value: Bool? in [true, false, nil] {
      record["blockAdultWebsites"] = value
      record["blockAppInstallation"] = value
      let decoded = try XCTUnwrap(SyncedProfile(from: record))
      let encoded = decoded.toCKRecord(in: zone)
      XCTAssertEqual(encoded["blockAdultWebsites"] as? Bool, value ?? false)
      XCTAssertEqual(encoded["blockAppInstallation"] as? Bool, value ?? false)
    }
  }

  func testGivenModelOptions_WhenCreatedClonedUpdated_ThenPersistAndSnapshot() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = try BlockedProfiles.createProfile(
      in: context, name: "Safety", blockAdultWebsites: true, blockAppInstallation: true)
    let clone = try BlockedProfiles.cloneProfile(profile, in: context, newName: "Copy")
    XCTAssertTrue(clone.blockAdultWebsites)
    XCTAssertTrue(clone.blockAppInstallation)
    XCTAssertEqual(SharedData.snapshot(for: clone.id.uuidString)?.blockAdultWebsites, true)
    XCTAssertEqual(SharedData.snapshot(for: clone.id.uuidString)?.blockAppInstallation, true)
    _ = try BlockedProfiles.updateProfile(
      profile, in: context, now: now, blockAdultWebsites: false, blockAppInstallation: false)
    XCTAssertFalse(profile.blockAdultWebsites)
    XCTAssertFalse(profile.blockAppInstallation)
    XCTAssertEqual(SharedData.snapshot(for: profile.id.uuidString)?.blockAdultWebsites, false)
    XCTAssertEqual(SharedData.snapshot(for: profile.id.uuidString)?.blockAppInstallation, false)
    let fresh = BlockedProfiles(name: "Default", createdAt: now, updatedAt: now)
    XCTAssertFalse(fresh.blockAdultWebsites)
    XCTAssertFalse(fresh.blockAppInstallation)
  }

  func testGivenLegacyJSON_WhenDecoded_ThenSafetyDefaultsOffAndPayloadMatchesExplicitFalse() throws {
    let now = Date()
    let source = BlockedProfiles(name: "Legacy", createdAt: now, updatedAt: now)
    let synced = SyncedProfile(from: source, originDeviceId: "device-A")
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(synced)) as? [String: Any])
    json.removeValue(forKey: "blockAdultWebsites")
    json.removeValue(forKey: "blockAppInstallation")
    var decoded = try JSONDecoder().decode(SyncedProfile.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertTrue(SyncPayloadEquality.profilesPayloadEqual(synced, decoded))
    decoded.blockAdultWebsites = true
    XCTAssertFalse(SyncPayloadEquality.profilesPayloadEqual(synced, decoded))
    decoded.blockAdultWebsites = false
    decoded.blockAppInstallation = true
    XCTAssertFalse(SyncPayloadEquality.profilesPayloadEqual(synced, decoded))

    var snapshotJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(BlockedProfiles.getSnapshot(for: source))) as? [String: Any])
    snapshotJSON.removeValue(forKey: "blockAdultWebsites")
    snapshotJSON.removeValue(forKey: "blockAppInstallation")
    let legacy = try JSONDecoder().decode(SharedData.ProfileSnapshot.self, from: JSONSerialization.data(withJSONObject: snapshotJSON))
    safetyStore.webContent.blockedByFilter = .auto([], except: [])
    safetyStore.application.denyAppInstallation = true
    AppBlockerUtil().activateRestrictions(for: legacy)
    XCTAssertNil(safetyStore.webContent.blockedByFilter)
    XCTAssertNotEqual(safetyStore.application.denyAppInstallation, true)
  }

  func testGivenEitherSafetyOnlyOption_WhenExplicitlySaving_ThenValidationAllowsIt() {
    for (adult, installs) in [(true, false), (false, true)] {
      XCTAssertNil(
        BlockedProfileView.emptyProfileValidationMessage(
          selection: .init(), domains: [], enableAllowMode: false, enableAllowModeDomains: false,
          needsAppSelection: true, blockAdultWebsites: adult, blockAppInstallation: installs))
      XCTAssertFalse(
        BlockedProfiles.needsAppSelectionAfterLocalSave(
          currentNeedsAppSelection: true, selection: .init(),
          blockAdultWebsites: adult, blockAppInstallation: installs))
    }
  }

}
