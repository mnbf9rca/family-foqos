//
//  DeviceActivityMonitorExtension.swift
//  FoqosDeviceMonitor
//
//  Created by Ali Waseem on 2025-05-27.
//

import DeviceActivity
import FoqosShared
import ManagedSettings
import OSLog

private let log = Logger(
  subsystem: "com.cynexia.family-foqos.monitor",
  category: "DeviceActivity"
)

// Optionally override any of the functions below.
// Make sure that your class name matches the NSExtensionPrincipalClass in your Info.plist.
class DeviceActivityMonitorExtension: DeviceActivityMonitor {
  private let appBlocker = AppBlockerUtil()

  override init() {
    SharedData.configure(
      suite: UserDefaults(suiteName: "group.com.cynexia.family-foqos")!
    )
    super.init()
  }

  override func intervalDidStart(for activity: DeviceActivityName) {
    super.intervalDidStart(for: activity)

    log.info("intervalDidStart for activity: \(activity.rawValue)")
    TimerActivityUtil.startTimerActivity(for: activity)
    reconcileAfterWake()
  }

  override func intervalDidEnd(for activity: DeviceActivityName) {
    super.intervalDidEnd(for: activity)

    log.info("intervalDidEnd for activity: \(activity.rawValue)")
    TimerActivityUtil.stopTimerActivity(for: activity)
    reconcileAfterWake()
  }

  private func reconcileAfterWake() {
    guard let session = SharedData.getActiveSharedSession(), session.endTime == nil else { return }
    let live = SharedData.snapshot(for: session.blockedProfileId.uuidString)
    SharedData.reconcileExpiredGrants(
      process: .monitorExtension,
      now: Date(),
      liveSnapshot: live,
      breakDurationMinutes: live?.breakTimeInMinutes,
      applier: appBlocker)
  }
}
