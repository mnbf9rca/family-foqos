import FoqosShared
import XCTest

final class BackgroundStopPolicyTests: XCTestCase {

  private func manualOnly() -> ProfileStopConditions { ProfileStopConditions(manual: true) }
  private func nfcOnly() -> ProfileStopConditions { ProfileStopConditions(anyNFC: true) }
  private func scheduleOnly() -> ProfileStopConditions { ProfileStopConditions(schedule: true) }

  // MARK: - Session Match

  func testGivenNoSessionMatch_WhenEvaluating_ThenDeniedNoMatchingSession() {
    let d = BackgroundStopPolicy.evaluate(
      channel: .shortcut, sessionMatchesProfile: false, geofence: .noRule, stopConditions: manualOnly())
    XCTAssertEqual(d, .denied(.noMatchingSession))
  }

  // MARK: - Configured stops

  // MARK: - Geofence

  func testGivenGeofenceUnavailable_WhenShortcut_ThenDeniedFailClosed() {
    let d = BackgroundStopPolicy.evaluate(
      channel: .shortcut, sessionMatchesProfile: true, geofence: .unavailable, stopConditions: manualOnly())
    XCTAssertEqual(d, .denied(.geofenceUnavailable))
  }

  func testGivenGeofenceNotSatisfied_WhenShortcut_ThenDeniedWithReason() {
    let d = BackgroundStopPolicy.evaluate(
      channel: .shortcut, sessionMatchesProfile: true, geofence: .notSatisfied(reason: "Not at home"),
      stopConditions: manualOnly())
    XCTAssertEqual(d, .denied(.geofenceNotSatisfied(reason: "Not at home")))
  }

  // MARK: - canStop: .shortcut / .takeover require conditions.manual

  func testGivenManualAllowed_WhenShortcut_ThenAllowed() {
    let d = BackgroundStopPolicy.evaluate(
      channel: .shortcut, sessionMatchesProfile: true, geofence: .noRule, stopConditions: manualOnly())
    XCTAssertEqual(d, .allowed)
  }

  func testGivenNFCOnly_WhenShortcut_ThenDeniedStopConditionNotMet() {
    let d = BackgroundStopPolicy.evaluate(
      channel: .shortcut, sessionMatchesProfile: true, geofence: .noRule, stopConditions: nfcOnly())
    guard case .denied(.stopConditionNotMet) = d else {
      return XCTFail("NFC-only profile must refuse a Shortcuts (manual-equivalent) stop (#261)")
    }
  }

  func testGivenNFCOnly_WhenTakeover_ThenDeniedStopConditionNotMet() {
    let d = BackgroundStopPolicy.evaluate(
      channel: .takeover, sessionMatchesProfile: true, geofence: .noRule, stopConditions: nfcOnly())
    guard case .denied(.stopConditionNotMet) = d else {
      return XCTFail("a commitment victim must not be force-ended by a scheduled takeover (#236)")
    }
  }

  // MARK: - canStop: .schedule requires conditions.schedule

  func testGivenScheduleAllowed_WhenScheduleChannel_ThenAllowed() {
    let d = BackgroundStopPolicy.evaluate(
      channel: .schedule, sessionMatchesProfile: true, geofence: .noRule, stopConditions: scheduleOnly())
    XCTAssertEqual(d, .allowed)
  }

  func testGivenManualOnly_WhenScheduleChannel_ThenDeniedStopConditionNotMet() {
    let d = BackgroundStopPolicy.evaluate(
      channel: .schedule, sessionMatchesProfile: true, geofence: .noRule, stopConditions: manualOnly())
    guard case .denied(.stopConditionNotMet) = d else {
      return XCTFail("manual-only profile must refuse a scheduled stop (#206)")
    }
  }

  func testScheduleBypassesGeofenceWhileTakeoverRequiresIt() {
    for geofence in [BackgroundStopPolicy.GeofenceState.unavailable, .notSatisfied(reason: "Away")] {
      XCTAssertEqual(
        BackgroundStopPolicy.evaluate(
          channel: .schedule, sessionMatchesProfile: true,
          geofence: geofence, stopConditions: scheduleOnly()), .allowed)
      guard
        case .denied = BackgroundStopPolicy.evaluate(
          channel: .takeover, sessionMatchesProfile: true,
          geofence: geofence, stopConditions: manualOnly())
      else {
        return XCTFail("Takeover must retain the outgoing geofence requirement")
      }
    }
  }

  func testGivenNilStopConditions_WhenSchedule_ThenDenied() {
    let d = BackgroundStopPolicy.evaluate(
      channel: .schedule, sessionMatchesProfile: true, geofence: .noRule, stopConditions: nil)
    guard case .denied = d else { return XCTFail("nil conditions must fail closed") }
  }
}
