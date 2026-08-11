import Foundation

enum FamilyRosterExport {
  static func content(
    for members: [FamilyMember],
    monitoredDevices: [MonitoredDevice]
  ) -> String {
    let devicesByMember = Dictionary(grouping: monitoredDevices, by: \.childUserRecordName)
    let lines = members.sorted(by: memberComesBefore).flatMap { member -> [String] in
      var fields = [member.redactedLogLabel, member.displayName, member.id.uuidString]
      if !member.userRecordName.isEmpty {
        fields.append(member.userRecordName)
      }
      if !member.isActive {
        fields.append("(departed)")
      }

      let matchedDevices =
        member.userRecordName.isEmpty ? [] : (devicesByMember[member.userRecordName] ?? [])
      let deviceLines =
        matchedDevices
        .sorted(by: deviceComesBefore)
        .map { device in
          let heartbeatRecordName = DeviceHeartbeat.recordName(
            childUserRecordName: device.childUserRecordName,
            deviceIdentifier: device.deviceIdentifier
          )
          return "  device — \(device.deviceIdentifier) — \(heartbeatRecordName)"
        }

      return [fields.joined(separator: " — ")] + deviceLines
    }

    guard !lines.isEmpty else {
      return "No family members were cached on this device at export time.\n"
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func memberComesBefore(_ lhs: FamilyMember, _ rhs: FamilyMember) -> Bool {
    if lhs.role.rawValue != rhs.role.rawValue {
      return lhs.role.rawValue < rhs.role.rawValue
    }
    if lhs.displayName != rhs.displayName {
      return lhs.displayName < rhs.displayName
    }
    return lhs.id.uuidString < rhs.id.uuidString
  }

  private static func deviceComesBefore(_ lhs: MonitoredDevice, _ rhs: MonitoredDevice) -> Bool {
    if lhs.deviceIdentifier != rhs.deviceIdentifier {
      return lhs.deviceIdentifier < rhs.deviceIdentifier
    }
    return DeviceHeartbeat.recordName(
      childUserRecordName: lhs.childUserRecordName,
      deviceIdentifier: lhs.deviceIdentifier
    )
      < DeviceHeartbeat.recordName(
        childUserRecordName: rhs.childUserRecordName,
        deviceIdentifier: rhs.deviceIdentifier
      )
  }
}
