// FoqosTests/StrategyManagerStartTests.swift
import FoqosShared
import XCTest

@testable import FamilyFoqos

@MainActor
final class StrategyManagerStartTests: XCTestCase {

  func testGivenManualTriggerOnly_WhenDeterminingStartAction_ThenReturnsStartImmediately() {
    var start = ProfileStartTriggers()
    start.manual = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .startImmediately)
  }

  func testGivenNFCTriggerOnly_WhenDeterminingStartAction_ThenReturnsScanNFC() {
    var start = ProfileStartTriggers()
    start.anyNFC = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .scanNFC)
  }

  func testGivenQRTriggerOnly_WhenDeterminingStartAction_ThenReturnsScanQR() {
    var start = ProfileStartTriggers()
    start.anyQR = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .scanQR)
  }

  func testGivenScheduleTriggerOnly_WhenDeterminingStartAction_ThenReturnsWaitForSchedule() {
    var start = ProfileStartTriggers()
    start.schedule = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .waitForSchedule)
  }

  func testGivenDeepLinkTriggerOnly_WhenDeterminingStartAction_ThenReturnsDeepLinkOnly() {
    var start = ProfileStartTriggers()
    start.deepLink = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .deepLinkOnly)
  }

  func testGivenManualAndNFCTriggers_WhenDeterminingStartAction_ThenShowsPicker() {
    var start = ProfileStartTriggers()
    start.manual = true
    start.anyNFC = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .showPicker(options: [.startImmediately, .scanNFC]))
  }

  func testGivenNFCAndQRTriggers_WhenDeterminingStartAction_ThenShowsPicker() {
    var start = ProfileStartTriggers()
    start.anyNFC = true
    start.anyQR = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .showPicker(options: [.scanNFC, .scanQR]))
  }

  func testGivenManualNFCAndQRTriggers_WhenDeterminingStartAction_ThenShowsPickerWithAll() {
    var start = ProfileStartTriggers()
    start.manual = true
    start.anyNFC = true
    start.anyQR = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .showPicker(options: [.startImmediately, .scanNFC, .scanQR]))
  }

  func testGivenNoTriggers_WhenDeterminingStartAction_ThenReturnsCannotStart() {
    let start = ProfileStartTriggers()

    let action = StartStopActionResolver.determineStartAction(for: start)

    if case .cannotStart = action {
      // expected
    } else {
      XCTFail("Expected .cannotStart, got \(action)")
    }
  }

  func testGivenManualStartWithInvalidStop_WhenDeterminingStartAction_ThenReturnsCannotStart() {
    var start = ProfileStartTriggers()
    start.manual = true
    let stop = ProfileStopConditions()  // all false — invalid

    let action = StartStopActionResolver.determineStartAction(for: start, stopConditions: stop)

    if case .cannotStart = action {
      // expected
    } else {
      XCTFail("Expected .cannotStart, got \(action)")
    }
  }

  func testGivenManualStartWithValidStop_WhenDeterminingStartAction_ThenReturnsStartImmediately() {
    var start = ProfileStartTriggers()
    start.manual = true
    var stop = ProfileStopConditions()
    stop.manual = true

    let action = StartStopActionResolver.determineStartAction(for: start, stopConditions: stop)

    XCTAssertEqual(action, .startImmediately)
  }
}
