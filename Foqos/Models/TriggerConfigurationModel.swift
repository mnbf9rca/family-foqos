import FoqosShared
import Foundation
import SwiftData
import SwiftUI

/// Observable model for trigger configuration UI
@MainActor
final class TriggerConfigurationModel: ObservableObject {
  private let validator = TriggerValidator()

  @Published var startTriggers = ProfileStartTriggers()
  @Published var stopConditions = ProfileStopConditions() {
    didSet {
      if oldValue.nfc != stopConditions.nfc && stopConditions.nfc != .specific {
        stopNFCTagIds = []
      }
      if oldValue.qr != stopConditions.qr && stopConditions.qr != .specific {
        stopQRCodeIds = []
      }
    }
  }
  @Published var validationErrors: [String] = []
  @Published private(set) var hasLoadedProfile = false

  // Tag bindings
  @Published var startNFCTagIds: [String] = []
  @Published var startQRCodeIds: [String] = []
  @Published var stopNFCTagIds: [String] = []
  @Published var stopQRCodeIds: [String] = []

  // Schedule bindings
  @Published var startSchedule: ProfileScheduleTime?
  @Published var stopSchedule: ProfileScheduleTime?

  init() {}

  /// Start edits only clean up abandoned start assignments and revalidate.
  func startTriggersDidChange() {
    if !startTriggers.specificNFC { startNFCTagIds = [] }
    if !startTriggers.specificQR { startQRCodeIds = [] }
    validate()
  }

  /// Call when stop conditions change to re-run validation
  func stopConditionsDidChange() {
    validate()
  }

  /// Run validation and update error list
  func validate() {
    let errors = validator.validate(
      start: startTriggers, stop: stopConditions,
      startNFCTagIds: startNFCTagIds, startQRCodeIds: startQRCodeIds,
      stopNFCTagIds: stopNFCTagIds, stopQRCodeIds: stopQRCodeIds,
      startSchedule: startSchedule, stopSchedule: stopSchedule,
      settingsReadable: true, forSave: true
    )

    validationErrors = errors
    if !validationErrors.isEmpty {
      Log.debug(
        "Trigger validation errors: \(validationErrors.joined(separator: ", ")). "
          + "Start: manual=\(startTriggers.manual), NFC=\(startTriggers.hasNFC), QR=\(startTriggers.hasQR), schedule=\(startTriggers.schedule), deepLink=\(startTriggers.deepLink). "
          + "Stop: manual=\(stopConditions.manual), timer=\(stopConditions.timer), NFC=\(stopConditions.anyNFC || stopConditions.specificNFC || stopConditions.sameNFC), "
          + "QR=\(stopConditions.anyQR || stopConditions.specificQR || stopConditions.sameQR), schedule=\(stopConditions.schedule), deepLink=\(stopConditions.deepLink)",
        category: .ui
      )
    }
  }

  /// Load from profile
  func loadFromProfile(
    _ profile: BlockedProfiles, in context: ModelContext, hasActiveSession: Bool = false
  ) throws {
    hasLoadedProfile = false
    let migrated = try ProfileMigrationUtil.migrate(profile, hasActiveSession: hasActiveSession)
    if !hasActiveSession && profile.needsMigration {
      throw NSError(
        domain: "ProfileMigration", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not migrate this profile’s trigger settings."])
    }
    if migrated { BlockedProfiles.updateSnapshot(for: profile) }
    startTriggers = profile.startTriggers
    stopConditions = profile.stopConditions
    startNFCTagIds = profile.startNFCTagIds
    startQRCodeIds = profile.startQRCodeIds
    stopNFCTagIds = profile.stopNFCTagIds
    stopQRCodeIds = profile.stopQRCodeIds
    startSchedule = profile.startSchedule
    stopSchedule = profile.stopSchedule
    validate()
    hasLoadedProfile = true
  }

  /// Save to profile
  func saveToProfile(_ profile: BlockedProfiles, now: Date = Date()) {
    validate()
    if !profile.startTriggers.schedule && startTriggers.schedule { startSchedule?.updatedAt = now }
    if !profile.stopConditions.schedule && stopConditions.schedule { stopSchedule?.updatedAt = now }
    profile.startTriggers = startTriggers
    var stops = stopConditions
    if validationErrors.isEmpty { stops.requiresEditingAfterConversion = false }
    profile.stopConditions = stops
    profile.startNFCTagIds = startNFCTagIds
    profile.startQRCodeIds = startQRCodeIds
    profile.stopNFCTagIds = stopNFCTagIds
    profile.stopQRCodeIds = stopQRCodeIds
    profile.startSchedule = startSchedule
    profile.stopSchedule = stopSchedule

    // The create/update boundary persists before publishing its snapshot.
  }
}
