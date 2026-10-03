import FoqosShared
import XCTest

@testable import FamilyFoqos

final class ProfileStartAdmissionTests: XCTestCase {
  private let c18 = "Please edit this profile before starting. Its start and stop settings need updating."
  private let c19 = "This profile has no stop for this start. Please edit it before starting."
  private let c24 = "This profile isn’t set to start this way. Please edit its start settings."

  private func snapshot(now: Date) -> SharedData.ProfileSnapshot {
    let profile = BlockedProfiles(name: "Admission", createdAt: now, updatedAt: now)
    profile.startTriggers = .init(manual: true, anyNFC: true, anyQR: true, schedule: true, deepLink: true, shortcuts: true)
    profile.startSchedule = .init(days: [.monday], hour: 9, minute: 0, updatedAt: now)
    profile.stopConditions = .init(timer: true, timerDurationMinutes: 37)
    return BlockedProfiles.getSnapshot(for: profile)
  }

  func testEveryOriginAdmissionBeforeEffects() {
    let now = Date()
    let origins: [SessionOrigin] = [
      .init(kind: .manual), .init(kind: .nfc, key: "A0FF", namespace: .nfcUID),
      .init(kind: .qr, key: "digest", namespace: .qrDigest), .init(kind: .shortcut),
      .init(kind: .link), .init(kind: .schedule),
    ]
    let stops: [ProfileStopConditions] = [
      .init(timer: true, timerDurationMinutes: 37), .init(manual: true),
      .init(nfc: .any), .init(qr: .any), .init(nfc: .specific), .init(qr: .specific),
      .init(schedule: true),
    ]
    for stop in stops {
      var snap = snapshot(now: now)
      snap.stopConditions = stop
      snap.stopNFCTagIds = ["B0FF"]
      snap.stopQRCodeIds = ["other-digest"]
      snap.stopSchedule = .init(days: [.friday], hour: 17, minute: 0, updatedAt: now)
      snap.disableBackgroundStops = true
      for origin in origins {
        XCTAssertNil(ProfileConditionValidation.startRejection(for: snap, origin: origin), "\(origin.kind) / \(stop)")
      }
    }
    var specific = snapshot(now: now)
    specific.startTriggers = .init(specificNFC: true, specificQR: true)
    specific.startNFCTagIds = ["A0FF"]
    specific.startQRCodeIds = ["digest"]
    XCTAssertNil(ProfileConditionValidation.startRejection(for: specific, origin: origins[1]))
    XCTAssertNil(ProfileConditionValidation.startRejection(for: specific, origin: origins[2]))
    XCTAssertEqual(ProfileConditionValidation.startRejection(for: specific, origin: .init(kind: .nfc, key: "B0FF", namespace: .nfcUID)), c24)
  }

  func testInvalidWholeConfigurationUsesC18() {
    let now = Date()
    let base = snapshot(now: now)
    var invalid: [SharedData.ProfileSnapshot] = []
    var unreadable = base
    unreadable.settingsReadable = false
    invalid.append(unreadable)
    var empty = base
    empty.stopConditions = .init(deepLink: true)
    invalid.append(empty)
    var missing = base
    missing.stopConditions = .init(nfc: .specific)
    invalid.append(missing)
    var recurrence = base
    recurrence.startSchedule = .init(days: [], hour: 9, minute: 0, updatedAt: now)
    invalid.append(recurrence)
    var marker = base
    marker.stopConditions = .init(manual: true, requiresEditingAfterConversion: true)
    invalid.append(marker)
    var same = base
    same.stopConditions = .init(nfc: .same, qr: .same)
    invalid.append(same)
    var nilTimer = base
    nilTimer.stopConditions = .init(timer: true)
    invalid.append(nilTimer)
    for minutes in [-1, 0, 14, 1440] {
      var snap = base
      snap.stopConditions = .init(manual: true, timer: true, timerDurationMinutes: minutes)
      invalid.append(snap)
    }
    for snap in invalid {
      for kind in [SessionOrigin.Kind.manual, .nfc, .qr, .shortcut, .link, .schedule] {
        XCTAssertEqual(ProfileConditionValidation.startRejection(for: snap, origin: .init(kind: kind)), c18)
      }
    }
    var inert = base
    inert.stopConditions = .init(timer: true, nfc: .any)
    XCTAssertNil(ProfileConditionValidation.startRejection(for: inert, origin: .init(kind: .manual)))
    var disabled = base
    disabled.startTriggers = .init(anyNFC: true)
    XCTAssertEqual(ProfileConditionValidation.startRejection(for: disabled, origin: .init(kind: .manual)), c24)
  }

  func testSameNeedsUsableTypedInitiatingIdentity() {
    let now = Date()
    for (kind, namespace, stop) in [(SessionOrigin.Kind.nfc, SessionOrigin.KeyNamespace.nfcUID, ProfileStopConditions(nfc: .same)), (.qr, .qrDigest, .init(qr: .same))] {
      var snap = snapshot(now: now)
      snap.startTriggers = kind == .nfc ? .init(anyNFC: true) : .init(anyQR: true)
      snap.stopConditions = stop
      XCTAssertNil(ProfileConditionValidation.startRejection(for: snap, origin: .init(kind: kind, key: "identity", namespace: namespace)))
      XCTAssertEqual(ProfileConditionValidation.startRejection(for: snap, origin: .init(kind: kind)), c19)
      XCTAssertEqual(ProfileConditionValidation.startRejection(for: snap, origin: .init(kind: kind, key: " ", namespace: namespace)), c19)
      XCTAssertEqual(ProfileConditionValidation.startRejection(for: snap, origin: .init(kind: kind, key: "identity", namespace: namespace == .nfcUID ? .qrDigest : .nfcUID)), c19)
      XCTAssertNotNil(ProfileConditionValidation.startRejection(for: snap, origin: .init(kind: .link)))
    }
  }

  func testStoredBlobsAndSchemaAreNotReplacedByValidDefaults() {
    let now = Date()
    for blob in [Data(), Data("{\"nfc\":\"unknown\"}".utf8)] {
      let profile = BlockedProfiles(name: "Invalid", createdAt: now, updatedAt: now)
      profile.startTriggers = .init(manual: true)
      profile.stopConditionsData = blob
      let snap = BlockedProfiles.getSnapshot(for: profile)
      XCTAssertNil(snap.stopConditions)
      XCTAssertEqual(snap.settingsReadable, false)
      XCTAssertEqual(ProfileConditionValidation.startRejection(for: snap, origin: .init(kind: .manual)), c18)
    }
    let profile = BlockedProfiles(name: "Newer", createdAt: now, updatedAt: now)
    profile.profileSchemaVersion = BlockedProfiles.currentSchemaVersion + 1
    profile.startTriggers = .init(manual: true)
    profile.stopConditions = .init(manual: true)
    XCTAssertEqual(ProfileConditionValidation.startRejection(for: BlockedProfiles.getSnapshot(for: profile), origin: .init(kind: .manual)), c18)
  }
  func testSpecificStartRequiresAKeyAndMayUseTheSameSpecificStopKey() {
    let now = Date()
    for kind in [SessionOrigin.Kind.nfc, .qr] {
      var snap = snapshot(now: now)
      snap.startTriggers = kind == .nfc ? .init(specificNFC: true) : .init(specificQR: true)
      snap.stopConditions = kind == .nfc ? .init(nfc: .specific) : .init(qr: .specific)
      snap.stopNFCTagIds = ["KEY"]
      snap.stopQRCodeIds = ["KEY"]
      let origin = SessionOrigin(kind: kind, key: "KEY", namespace: kind == .nfc ? .nfcUID : .qrDigest)
      XCTAssertEqual(ProfileConditionValidation.startRejection(for: snap, origin: origin), c18)
      snap.startNFCTagIds = ["KEY"]
      snap.startQRCodeIds = ["KEY"]
      XCTAssertNil(ProfileConditionValidation.startRejection(for: snap, origin: origin))
    }
  }

}
