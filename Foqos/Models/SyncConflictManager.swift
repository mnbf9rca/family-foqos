// Foqos/Models/SyncConflictManager.swift
import Foundation
import SwiftUI

/// Manages sync conflicts between schema versions
@MainActor
final class SyncConflictManager: ObservableObject {
  static let shared = SyncConflictManager()

  @Published var conflictedProfiles: [UUID: String] = [:]  // ID → name (older device edited)
  @Published var newerVersionProfiles: [UUID: String] = [:]  // ID → name (this device outdated)
  @Published var divergenceProfiles: [UUID: String] = [:]  // ID → name (concurrent edit)
  @Published var showConflictBanner: Bool = false
  @Published var resetWasSuperseded: Bool = false  // profile-less: a reset request did not run

  init() {}

  func addConflict(profileId: UUID, profileName: String) {
    conflictedProfiles[profileId] = profileName
    showConflictBanner = true
  }

  /// Surfaces a "your reset did not run" conflict. Profile-less: reset requests are
  /// device-scoped, not tied to any single profile.
  func addResetSupersededConflict() {
    resetWasSuperseded = true
    showConflictBanner = true
  }

  func addNewerVersionConflict(profileId: UUID, profileName: String) {
    newerVersionProfiles[profileId] = profileName
    showConflictBanner = true
  }

  /// Records a same-version concurrent edit resolved by the deterministic tie-break (#218).
  func addDivergenceConflict(profileId: UUID, profileName: String) {
    divergenceProfiles[profileId] = profileName
    showConflictBanner = true
  }

  func dismissBanner() {
    divergenceProfiles.removeAll()
    showConflictBanner = false
    resetWasSuperseded = false
  }

  func clearConflict(profileId: UUID) {
    conflictedProfiles.removeValue(forKey: profileId)
    newerVersionProfiles.removeValue(forKey: profileId)
    divergenceProfiles.removeValue(forKey: profileId)
    if conflictedProfiles.isEmpty && newerVersionProfiles.isEmpty && divergenceProfiles.isEmpty {
      showConflictBanner = false
    }
  }

  func clearAll() {
    conflictedProfiles.removeAll()
    newerVersionProfiles.removeAll()
    divergenceProfiles.removeAll()
    showConflictBanner = false
    resetWasSuperseded = false
  }

  var shouldShowNewerVersionBanner: Bool {
    !newerVersionProfiles.isEmpty && showConflictBanner
  }

  var shouldShowOlderDeviceBanner: Bool {
    !conflictedProfiles.isEmpty && showConflictBanner
  }

  var shouldShowDivergenceBanner: Bool {
    !divergenceProfiles.isEmpty && showConflictBanner
  }

  var divergenceMessage: String {
    if divergenceProfiles.count == 1, let name = divergenceProfiles.values.first {
      return "\"\(name)\" was changed on another device. Keeping the most recently edited copy."
    } else {
      return
        "Several profiles were changed on more than one device. Keeping the most recently edited copies."
    }
  }

  var conflictMessage: String {
    if conflictedProfiles.count == 1, let name = conflictedProfiles.values.first {
      return "\"\(name)\" was edited on an older app version. Update Foqos on all devices to sync."
    } else {
      return
        "Several profiles were edited on an older app version. Update Foqos on all devices to sync."
    }
  }

  var newerVersionMessage: String {
    if newerVersionProfiles.count == 1, let name = newerVersionProfiles.values.first {
      return
        "\"\(name)\" was updated on a newer version of Foqos. Update this device to continue syncing."
    } else {
      return
        "Some profiles were updated on a newer version of Foqos. Update this device to continue syncing."
    }
  }
}
