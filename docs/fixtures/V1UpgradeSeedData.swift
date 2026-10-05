// Copied only to the frozen V1 disposable worktree. Never a hosted test.
#if DEBUG
  import Foundation
  import SwiftData

  enum UpgradeUI {
    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("--upgrade-ui-check") }
    static func argument(_ key: String) -> String? {
      let args = ProcessInfo.processInfo.arguments
      guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
      return args[index + 1]
    }
    static var scans: [String] = argument("--upgrade-scan-script")?.components(separatedBy: ",") ?? []
    static var requestIndex = 0
    static func nextScan(kind: String) -> String {
      precondition(isActive, "Upgrade scan opt-in is required")
      guard let phase = argument("--upgrade-report-phase"),
        let generation = argument("--upgrade-report-generation"), UUID(uuidString: generation) != nil
      else { preconditionFailure("Missing scan evidence generation/phase") }
      let input = scans.isEmpty ? "exhausted" : scans.removeFirst()
      let result = ["wrong", "correct", "cancel"].contains(input) ? input : "exhausted"
      let entry: [String: Any] = [
        "phase": phase, "generation": generation, "kind": kind,
        "requestIndex": requestIndex, "scriptIndex": requestIndex, "value": result,
      ]
      requestIndex += 1
      do {
        let path = URL.documentsDirectory.appending(path: "upgrade-scans.jsonl")
        if !FileManager.default.fileExists(atPath: path.path) { try Data().write(to: path, options: .withoutOverwriting) }
        let file = try FileHandle(forWritingTo: path)
        try file.seekToEnd()
        var line = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        line.append(10)
        try file.write(contentsOf: line)
        try file.close()
      } catch { preconditionFailure("Upgrade scan evidence write failed") }
      return result
    }
    static let nfc = "04AABBCCDD"
    static let qr = "RC upgrade correct QR"
  }

  @MainActor
  enum RCUpgradeSeedData {
    static func seed(persona: String, context: ModelContext, now: Date) throws {
      guard UpgradeUI.isActive else { throw failure("Upgrade UI opt-in is required") }
      let documents = URL.documentsDirectory
      let seedURL = documents.appending(path: "rc-v1-seed.json")
      let marker =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: documents.appending(path: "upgrade-disposable.json"))) as? [String: String]
      guard marker?["persona"] == persona,
        marker?["token"] == UpgradeUI.argument("--upgrade-store-token"),
        !FileManager.default.fileExists(atPath: seedURL.path),
        try context.fetch(FetchDescriptor<BlockedProfiles>()).isEmpty,
        try context.fetch(FetchDescriptor<BlockedProfileSession>()).isEmpty,
        try context.fetch(FetchDescriptor<SavedLocation>()).isEmpty
      else { throw failure("Refusing unrelated or already seeded application data") }
      let suite = UserDefaults(suiteName: "group.com.cynexia.family-foqos")!
      guard !suite.dictionaryRepresentation().keys.contains(where: { $0.hasPrefix("family_foqos_") })
      else { throw failure("Refusing V2 app-group data") }
      let strategies = [
        "ManualBlockingStrategy", "NFCBlockingStrategy", "QRCodeBlockingStrategy",
        "NFCTimerBlockingStrategy", "QRTimerBlockingStrategy", "ShortcutTimerBlockingStrategy",
        "NFCManualBlockingStrategy", "QRManualBlockingStrategy",
      ]
      let selected: [String: Int] = [
        "manual": 0, "nfc": 1, "qr": 2, "nfc-timer": 3,
        "qr-timer": 4, "shortcut-timer": 5, "manual-nfc": 6, "manual-qr": 7,
        "schedule": 0, "break": 0, "emergency": 0, "parent": 0, "child": 0, "library": 0,
      ]
      guard let strategyIndex = selected[persona] else { throw failure("Unknown persona") }
      let defaults = UserDefaults.standard
      defaults.set(false, forKey: "showIntroScreen")
      defaults.set(true, forKey: "hasCompletedOnboarding")
      defaults.set(false, forKey: "showModeSelection")
      defaults.set(true, forKey: "showHabitTracker")
      defaults.set(0, forKey: "launchCount")
      defaults.set(persona == "emergency" ? 1 : 3, forKey: "emergencyUnblocksRemaining")
      defaults.set(persona == "emergency" ? 2 : 4, forKey: "emergencyUnblocksResetPeriodInWeeks")
      defaults.set(now.timeIntervalSinceReferenceDate, forKey: "lastEmergencyUnblocksResetDate")
      let mode: AppMode = persona == "parent" ? .parent : persona == "child" ? .child : .individual
      AppModeManager.shared.selectMode(mode)
      defaults.set(mode == .child ? "child" : "individual", forKey: "family_foqos_authorization_type")
      defaults.set(now, forKey: "family_foqos_authorization_verified_at")
      SharedData.deviceSyncEnabled = false
      SharedData.flushActiveSession()
      SharedData.profileSnapshots = [:]
      SharedData.flushCompletedSessionsForSchedular()
      let timer = try JSONEncoder().encode(StrategyTimerData(durationInMinutes: 37))
      var profiles: [BlockedProfiles] = []
      let count = persona == "library" ? 24 : 2
      for index in 0..<count {
        let id = index == 0 ? strategyIndex : persona == "library" ? index % strategies.count : 0
        let name =
          persona == "library"
          ? String(format: "RC Library %02d", index + 1)
          : index == 0 ? "RC \(persona)" : "RC Control"
        let profile = try BlockedProfiles.createProfile(
          in: context, name: name, blockingStrategyId: strategies[id],
          strategyData: [3, 4, 5].contains(id) && !(persona == "library" && index == 5) ? timer : nil,
          reminderTimeInSeconds: 300, customReminderMessage: "RC retained reminder",
          enableBreaks: true, breakTimeInMinutes: 30, enableStrictMode: true,
          enableAllowMode: false, enableAllowModeDomains: false, enableSafariBlocking: false,
          domains: ["example.com"],
          physicalUnblockNFCTagId: id == 6 ? UpgradeUI.nfc : nil,
          physicalUnblockQRCodeId: id == 7 ? UpgradeUI.qr : nil,
          disableBackgroundStops: true, isManaged: index == 0 && [.parent, .child].contains(mode))
        profile.createdAt = now.addingTimeInterval(-86_400)
        profile.updatedAt = now
        if persona == "schedule" && index == 0 {
          let calendar = Calendar.current
          let start = calendar.dateComponents([.hour, .minute], from: now.addingTimeInterval(-1800))
          let end = calendar.dateComponents([.hour, .minute], from: now.addingTimeInterval(7200))
          profile.schedule = BlockedProfileSchedule(
            days: Weekday.allCases,
            startHour: start.hour!, startMinute: start.minute!, endHour: end.hour!, endMinute: end.minute!, updatedAt: now)
        }
        profiles.append(profile)
      }
      if persona == "library" {
        let location = SavedLocation(
          name: "RC Study", latitude: 51.5054, longitude: -0.0235,
          defaultRadiusMeters: 500, createdAt: now, updatedAt: now)
        context.insert(location)
        profiles[22].geofenceRule = ProfileGeofenceRule(
          ruleType: .within,
          locationReferences: [ProfileLocationReference(savedLocationId: location.id)])
      }
      for profile in profiles { BlockedProfiles.updateSnapshot(for: profile) }
      // Completed history is constructed in the actual V1 store, without changing the active snapshot.
      let history = BlockedProfileSession(
        tag: ManualBlockingStrategy.id, blockedProfile: persona == "library" ? profiles[23] : profiles[0],
        startTime: now.addingTimeInterval(-7200))
      history.endTime = now.addingTimeInterval(-3600)
      context.insert(history)
      var active: BlockedProfileSession?
      if persona != "library" {
        let tag =
          persona == "nfc"
          ? UpgradeUI.nfc
          : persona == "qr"
            ? UpgradeUI.qr
            : persona == "schedule"
              ? profiles[0].id.uuidString
              : ["nfc-timer", "qr-timer", "shortcut-timer"].contains(persona)
                ? strategies[strategyIndex] : ManualBlockingStrategy.id
        active = BlockedProfileSession.createSession(
          in: context, withTag: tag,
          withProfile: profiles[0], startTime: now.addingTimeInterval(-120))
        if persona == "break" {
          active!.breakStartTime = now.addingTimeInterval(-60)
          SharedData.createActiveSharedSession(for: active!.toSnapshot())
        }
      }
      try context.save()
      suite.synchronize()
      defaults.synchronize()
      let snapshots = try profiles.map { profile -> [String: Any] in
        var row = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BlockedProfiles.getSnapshot(for: profile))) as! [String: Any]
        row["id"] = profile.id.uuidString
        row["schema"] = profile.profileSchemaVersion
        return row
      }
      let seed: [String: Any] = [
        "persona": persona, "profiles": snapshots,
        "sessionID": active?.id as Any? ?? NSNull(),
        "session": try active.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0.toSnapshot())) } ?? NSNull(),
        "historyID": history.id,
        "history": try JSONSerialization.jsonObject(with: JSONEncoder().encode(history.toSnapshot())),
        "mode": mode.rawValue,
        "store": context.container.configurations.first!.url.path,
        "setupTime": now.timeIntervalSinceReferenceDate,
        "locale": Locale.current.identifier, "timeZone": TimeZone.current.identifier,
        "firstWeekday": Calendar.current.firstWeekday,
        "emergencyRemaining": persona == "emergency" ? 1 : 3,
        "emergencyWeeks": persona == "emergency" ? 2 : 4,
      ]
      try JSONSerialization.data(withJSONObject: seed, options: [.prettyPrinted, .sortedKeys])
        .write(to: seedURL, options: .atomic)
    }

    private static func failure(_ message: String) -> Error {
      NSError(domain: "UpgradeFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
  }
#endif
