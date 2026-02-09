// Foqos/Models/SyncConflictManager.swift
import Foundation
import SwiftUI

/// Manages sync conflicts between schema versions
@MainActor
final class SyncConflictManager: ObservableObject {
  static let shared = SyncConflictManager()

  @Published var conflictedProfiles: [UUID: String] = [:]  // ID → name
  @Published var showConflictBanner: Bool = false

  private init() {}

  func addConflict(profileId: UUID, profileName: String) {
    conflictedProfiles[profileId] = profileName
    showConflictBanner = true
  }

  func dismissBanner() {
    showConflictBanner = false
  }

  func clearConflict(profileId: UUID) {
    conflictedProfiles.removeValue(forKey: profileId)
    if conflictedProfiles.isEmpty {
      showConflictBanner = false
    }
  }

  func clearAll() {
    conflictedProfiles.removeAll()
    showConflictBanner = false
  }

  var conflictMessage: String {
    if conflictedProfiles.count == 1, let name = conflictedProfiles.values.first {
      return "\"\(name)\" was edited on an older app version. Update Foqos on all devices to sync."
    } else {
      return "Several profiles were edited on an older app version. Update Foqos on all devices to sync."
    }
  }
}
