// Copied only into disposable V2 Debug builds. Reports never mutate application state.
#if DEBUG
  import Combine
  import FoqosShared
  import Foundation
  import SwiftData

  enum UpgradeUI {
    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("--upgrade-ui-check") }
    static func argument(_ key: String) -> String? {
      let args = ProcessInfo.processInfo.arguments
      guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
      return args[index + 1]
    }
    @MainActor static var scans: [String] = argument("--upgrade-scan-script")?.components(separatedBy: ",") ?? []
    @MainActor static var requestIndex = 0
    @MainActor static func nextScan(kind: String) -> String {
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

  // DeviceActivity registration and enforcement are simulated, never reported as device proof.
  struct UpgradeRestrictions: RestrictionApplying {
    func activateRestrictions(for profile: SharedData.ProfileSnapshot) {}
    func deactivateRestrictions() {}
    func deactivateRestrictions(keepingSafeguardsFor profile: SharedData.ProfileSnapshot?) {}
  }
  struct UpgradeBackstops: BackstopRegistering {
    func replaceBreakBackstop(profileId: UUID, deadline: Date, now: Date) throws {}
    func replaceOneMoreMinuteBackstop(profileId: UUID, deadline: Date, now: Date) throws {}
    func registerBreakBackstopIfAbsent(profileId: UUID, deadline: Date, now: Date) throws -> Bool { true }
    func registerOneMoreMinuteBackstopIfAbsent(profileId: UUID, deadline: Date, now: Date) throws -> Bool { true }
    func removeBreakBackstop(profileId: UUID) {}
    func removeOneMoreMinuteBackstop(profileId: UUID) {}
    func hasBreakBackstop(profileId: UUID) -> Bool { true }
    func hasOneMoreMinuteBackstop(profileId: UUID) -> Bool { true }
  }

  @MainActor
  final class UpgradeReportSignal: ObservableObject {
    static let shared = UpgradeReportSignal()
    @Published var count = 0
  }

  @MainActor
  enum UpgradeDiagnostics {
    static func writeReport(context: ModelContext, phase: String) throws {
      guard UpgradeUI.isActive,
        ProcessInfo.processInfo.arguments.contains("--upgrade-diagnostics"),
        UpgradeUI.argument("--upgrade-report-phase") == phase,
        let generation = UpgradeUI.argument("--upgrade-report-generation"), UUID(uuidString: generation) != nil,
        let source = UpgradeUI.argument("--upgrade-source-revision"), source.count == 40
      else { return }
      let seed = try JSONSerialization.jsonObject(with: Data(contentsOf: URL.documentsDirectory.appending(path: "rc-v1-seed.json"))) as! [String: Any]
      let profiles = try BlockedProfiles.fetchProfiles(in: context)
      let sessions = try context.fetch(FetchDescriptor<BlockedProfileSession>())
      let locations = try SavedLocation.fetchAll(in: context)
      let rows = try profiles.map { profile -> [String: Any] in
        var row = try object(BlockedProfiles.getSnapshot(for: profile))
        row["id"] = profile.id.uuidString
        row["schema"] = profile.profileSchemaVersion
        row["needsMigration"] = profile.needsMigration
        row["newerSchema"] = profile.isNewerSchemaVersion
        row["invalid"] = profile.hasInvalidConditionSettings
        row["startConfigurationValid"] = ProfileConditionValidation.startRejection(for: BlockedProfiles.getSnapshot(for: profile), origin: SessionOrigin(kind: .manual), allowLinkForTag: false) == nil
        row["strategyData"] = profile.strategyData?.base64EncodedString() as Any? ?? NSNull()
        row["startTriggers"] = try object(profile.startTriggers)
        row["stopConditions"] = try object(profile.stopConditions)
        row["scheduleLastStoppedAt"] = profile.scheduleLastStoppedAt?.timeIntervalSinceReferenceDate as Any? ?? NSNull()
        return row
      }
      let sessionRows = try sessions.map { session -> [String: Any] in
        var row = try object(session.toSnapshot())
        row["profileID"] = session.blockedProfile.id.uuidString
        row["active"] = session.isActive
        row["origin"] = try session.origin.map { try object($0) } as Any? ?? NSNull()
        row["timerEndTime"] = session.timerEndTime?.timeIntervalSinceReferenceDate as Any? ?? NSNull()
        row["breakEndDeadline"] = session.breakEndDeadline?.timeIntervalSinceReferenceDate as Any? ?? NSNull()
        return row
      }
      let report: [String: Any] = [
        "source": source, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String,
        "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String,
        "phase": phase, "generation": generation, "count": UpgradeReportSignal.shared.count + 1, "writtenAt": Date().timeIntervalSinceReferenceDate,
        "persona": seed["persona"]!, "profiles": rows, "sessions": sessionRows,
        "profileCount": profiles.count, "activeSessionCount": sessions.filter(\.isActive).count,
        "locations": locations.map {
          [
            "id": $0.id.uuidString, "name": $0.name,
            "latitude": $0.latitude, "longitude": $0.longitude, "radius": $0.defaultRadiusMeters,
          ] as [String: Any]
        },
        "mode": AppModeManager.shared.currentMode.rawValue,
        "emergencyRemaining": EmergencyUnblockManager.shared.getRemainingEmergencyUnblocks(),
        "emergencyResetDays": EmergencyUnblockManager.shared.getResetPeriodInDays(),
        "syncEnabled": ProfileSyncManager.shared.isEnabled,
        "locale": Locale.current.identifier, "timeZone": TimeZone.current.identifier,
        "firstWeekday": Calendar.current.firstWeekday,
      ]
      if sessions.contains(where: \.isActive) {
        let path = URL.documentsDirectory.appending(path: "upgrade-session-report.json")
        var supplement = report.filter { ["source", "version", "build", "phase", "generation", "persona", "writtenAt", "timeZone", "count"].contains($0.key) }
        var accepted: [String: [String: Any]] = [:]
        if FileManager.default.fileExists(atPath: path.path) {
          let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
          if previous["phase"] as? String == phase && previous["generation"] as? String == generation {
            accepted = previous["sessions"] as! [String: [String: Any]]
          }
        }
        for session in sessions where session.isActive {
          var row = sessionRows.first { ($0["id"] as? String) == session.id }!
          row["schema"] = session.blockedProfile.profileSchemaVersion
          accepted[session.id] = row
        }
        supplement["sessions"] = accepted
        try JSONSerialization.data(withJSONObject: supplement, options: [.prettyPrinted, .sortedKeys]).write(to: path, options: .atomic)
      }
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL.documentsDirectory.appending(path: "upgrade-report.json"), options: .atomic)
      UpgradeReportSignal.shared.count += 1
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
  }
#endif
