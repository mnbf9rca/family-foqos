// Copied temporarily over the explicit V1 LogTailTests.swift target member by the runbook.
import FamilyControls
import Foundation
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class RCUpgradeSeedTests: XCTestCase {
  func testSeedActualV1Store() throws {
    let now = Date()
    let schema = Schema([BlockedProfileSession.self, BlockedProfiles.self, SavedLocation.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
    let store = try ModelContainer(for: schema, configurations: [configuration])
    let context = store.mainContext
    let existing = try BlockedProfiles.fetchProfiles(in: context)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "group.com.cynexia.family-foqos"))
    guard existing.allSatisfy({ $0.name.hasPrefix("RC ") }),
      !defaults.dictionaryRepresentation().keys.contains(where: { $0.hasPrefix("family_foqos_") })
    else {
      XCTFail("Seed refused: unrelated profiles or V2 shared keys remain in the disposable store")
      return
    }
    for old in existing {
      for session in old.sessions { context.delete(session) }
      context.delete(old)
    }
    try context.save()
    SharedData.flushActiveSession()
    SharedData.profileSnapshots = [:]
    SharedData.completedSessionsInScheduler = []
    let timer = try JSONEncoder().encode(StrategyTimerData(durationInMinutes: 37))
    let rows: [(String, String, Data?, String?, String?)] = [
      ("RC plain NFC", "NFCBlockingStrategy", nil, nil, nil),
      ("RC plain QR", "QRCodeBlockingStrategy", nil, nil, nil),
      ("RC specific NFC", "NFCBlockingStrategy", nil, "04AABBCCDD", nil),
      ("RC specific QR", "QRCodeBlockingStrategy", nil, nil, "legacy-unlock-qr"),
      ("RC Shortcut timer", "ShortcutTimerBlockingStrategy", timer, nil, nil),
      ("RC missing timer", "ShortcutTimerBlockingStrategy", nil, nil, nil),
      ("RC NFC timer", "NFCTimerBlockingStrategy", timer, nil, nil),
      ("RC QR timer", "QRTimerBlockingStrategy", timer, nil, nil),
      ("RC manual NFC", "NFCManualBlockingStrategy", nil, "04AABBCCDD", nil),
      ("RC manual QR", "QRManualBlockingStrategy", nil, nil, "legacy-unlock-qr"),
      ("RC schedule", "ManualBlockingStrategy", nil, nil, nil),
      ("RC manual", "ManualBlockingStrategy", nil, nil, nil),
      ("RC invalid key", "NFCBlockingStrategy", nil, " ", nil),
      ("RC active NFC", "NFCBlockingStrategy", nil, nil, nil),
    ]
    var seeded: [BlockedProfiles] = []
    for (name, strategy, data, nfc, qr) in rows {
      let p = try BlockedProfiles.createProfile(
        in: context, name: name, blockingStrategyId: strategy, strategyData: data,
        enableLiveActivity: true, reminderTimeInSeconds: 300, customReminderMessage: "RC retained reminder",
        enableBreaks: true, breakTimeInMinutes: 7, enableStrictMode: true, enableAllowMode: true,
        enableAllowModeDomains: true, enableSafariBlocking: false, domains: ["example.com"],
        physicalUnblockNFCTagId: nfc, physicalUnblockQRCodeId: qr, disableBackgroundStops: true, isManaged: true)
      p.createdAt = now
      p.updatedAt = now
      if name == "RC schedule" {
        p.schedule = BlockedProfileSchedule(days: [.monday, .friday], startHour: 9, startMinute: 13, endHour: 17, endMinute: 47, updatedAt: now)
      }
      BlockedProfiles.updateSnapshot(for: p)
      seeded.append(p)
    }
    let active = try XCTUnwrap(seeded.first { $0.name == "RC active NFC" })
    let session = BlockedProfileSession.createSession(in: context, withTag: "nfc:04AABBCCDD", withProfile: active, startTime: now)
    try context.save()
    XCTAssertEqual(try BlockedProfiles.fetchProfiles(in: context).count, rows.count)
    XCTAssertEqual(session.blockedProfile.profileSchemaVersion, 1)
    defaults.synchronize()
    let evidence: [String: Any] = ["profiles": seeded.map { ["name": $0.name, "id": $0.id.uuidString] }, "sessionID": session.id, "sessionStart": now.timeIntervalSince1970, "store": configuration.url.path]
    try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/rc-v1-seed.json"))
  }
}
