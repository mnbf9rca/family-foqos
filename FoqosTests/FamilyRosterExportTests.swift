import Foundation
import XCTest

@testable import FamilyFoqos

final class FamilyRosterExportTests: XCTestCase {
  func testGivenActiveMember_WhenFormattingRoster_ThenIncludesEveryLogIdentityToken() {
    let member = FamilyMember(
      id: UUID(uuidString: "3F2A9C1B-672E-4C4A-9039-FF6107FBCE91")!,
      userRecordName: "_abc123",
      displayName: "Emma",
      role: .child
    )

    XCTAssertEqual(
      FamilyRosterExport.content(for: [member], monitoredDevices: []),
      "child·3F2A9C1B — Emma — 3F2A9C1B-672E-4C4A-9039-FF6107FBCE91 — _abc123\n"
    )
  }

  func testGivenInactiveMember_WhenFormattingRoster_ThenAppendsDeparted() {
    let member = FamilyMember(
      id: UUID(uuidString: "81D45AA0-DB15-48E2-9E20-0BE031607A19")!,
      userRecordName: "_def456",
      displayName: "Dad",
      role: .parent,
      isActive: false
    )

    XCTAssertTrue(
      FamilyRosterExport.content(for: [member], monitoredDevices: [])
        .contains("_def456 — (departed)\n")
    )
  }

  func testGivenMatchedCachedDevices_WhenFormattingRoster_ThenAddsSortedDeviceLines() {
    let member = FamilyMember(
      id: UUID(uuidString: "3F2A9C1B-672E-4C4A-9039-FF6107FBCE91")!,
      userRecordName: "_abc123",
      displayName: "Emma",
      role: .child
    )
    let devices = [
      monitoredDevice(identifier: "device-z", childRecordName: "_abc123"),
      monitoredDevice(identifier: "device-a", childRecordName: "_abc123"),
      monitoredDevice(identifier: "unmatched", childRecordName: "_missing"),
    ]

    XCTAssertEqual(
      FamilyRosterExport.content(for: [member], monitoredDevices: devices),
      """
      child·3F2A9C1B — Emma — 3F2A9C1B-672E-4C4A-9039-FF6107FBCE91 — _abc123
        device — device-a — heartbeat-_abc123-device-a
        device — device-z — heartbeat-_abc123-device-z

      """
    )
  }

  func testGivenMembersOutOfOrder_WhenFormattingRoster_ThenSortsRoleNameAndUUID() {
    let parent = FamilyMember(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
      userRecordName: "parent",
      displayName: "Alex",
      role: .parent
    )
    let laterChild = FamilyMember(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      userRecordName: "child-b",
      displayName: "Sam",
      role: .child
    )
    let earlierChild = FamilyMember(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      userRecordName: "child-a",
      displayName: "Sam",
      role: .child
    )

    let lines = FamilyRosterExport.content(
      for: [parent, laterChild, earlierChild], monitoredDevices: []
    ).split(separator: "\n")

    XCTAssertEqual(
      lines.map(String.init),
      [
        "child·00000000 — Sam — 00000000-0000-0000-0000-000000000001 — child-a",
        "child·00000000 — Sam — 00000000-0000-0000-0000-000000000002 — child-b",
        "parent·00000000 — Alex — 00000000-0000-0000-0000-000000000003 — parent",
      ])
  }

  func testGivenEmptyRecordName_WhenFormatting_ThenOmitsBlankFieldAndDoesNotMatchDevices() {
    let member = FamilyMember(
      id: UUID(uuidString: "3F2A9C1B-672E-4C4A-9039-FF6107FBCE91")!,
      userRecordName: "",
      displayName: "Emma",
      role: .child
    )

    XCTAssertEqual(
      FamilyRosterExport.content(
        for: [member],
        monitoredDevices: [monitoredDevice(identifier: "device-a", childRecordName: "")]
      ),
      "child·3F2A9C1B — Emma — 3F2A9C1B-672E-4C4A-9039-FF6107FBCE91\n"
    )
  }

  func testGivenNoMembers_WhenFormattingRoster_ThenExplainsEmptyCache() {
    XCTAssertEqual(
      FamilyRosterExport.content(for: [], monitoredDevices: []),
      "No family members were cached on this device at export time.\n"
    )
  }

  private func monitoredDevice(identifier: String, childRecordName: String) -> MonitoredDevice {
    MonitoredDevice(
      deviceIdentifier: identifier,
      deviceName: "Test Device",
      childUserRecordName: childRecordName,
      lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
      isSuppressed: false,
      notificationIdentifier: nil
    )
  }
}
