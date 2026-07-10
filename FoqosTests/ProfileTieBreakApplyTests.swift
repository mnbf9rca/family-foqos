import CloudKit
import XCTest

@testable import FamilyFoqos

@MainActor
final class ProfileTieBreakApplyTests: XCTestCase {

  private func synced(name: String, updatedAt: Date, device: String) -> SyncedProfile {
    let source = BlockedProfiles(id: UUID(), name: name, updatedAt: updatedAt)
    return SyncedProfile(from: source, originDeviceId: device)
  }

  func testGivenTie_WhenRemoteHasNewerUpdatedAt_ThenRemoteWins() {
    let now = Date()
    let remote = synced(name: "R", updatedAt: now, device: "A")
    let local = synced(name: "L", updatedAt: now.addingTimeInterval(-10), device: "B")
    XCTAssertTrue(SyncApplyService.remoteWinsProfileTie(remote: remote, local: local))
  }

  func testGivenTie_WhenLocalHasNewerUpdatedAt_ThenLocalWins() {
    let now = Date()
    let remote = synced(name: "R", updatedAt: now.addingTimeInterval(-10), device: "A")
    let local = synced(name: "L", updatedAt: now, device: "B")
    XCTAssertFalse(SyncApplyService.remoteWinsProfileTie(remote: remote, local: local))
  }

  func testGivenEqualUpdatedAt_WhenBreaking_ThenLowerOriginDeviceIdWins() {
    let now = Date()
    let remote = synced(name: "R", updatedAt: now, device: "A")
    let local = synced(name: "L", updatedAt: now, device: "B")
    XCTAssertTrue(SyncApplyService.remoteWinsProfileTie(remote: remote, local: local))
    XCTAssertFalse(SyncApplyService.remoteWinsProfileTie(remote: local, local: remote))
  }
}
