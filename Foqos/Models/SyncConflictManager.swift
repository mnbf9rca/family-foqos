// Foqos/Models/SyncConflictManager.swift
import Foundation
import SwiftUI

/// Manages sync conflicts between schema versions
@MainActor
final class SyncConflictManager: ObservableObject {
  static let shared = SyncConflictManager()

  @Published var conflictedProfileIds: Set<UUID> = []
  @Published var showConflictBanner: Bool = false

  private init() {}

  func addConflict(profileId: UUID) {
    conflictedProfileIds.insert(profileId)
    showConflictBanner = true
  }

  func dismissBanner() {
    showConflictBanner = false
  }

  func clearConflict(profileId: UUID) {
    conflictedProfileIds.remove(profileId)
    if conflictedProfileIds.isEmpty {
      showConflictBanner = false
    }
  }

  func clearAll() {
    conflictedProfileIds.removeAll()
    showConflictBanner = false
  }

  var conflictMessage: String {
    if conflictedProfileIds.count == 1 {
      return "A profile was edited on an older app version."
    } else {
      return "Several profiles were edited on an older app version."
    }
  }
}
