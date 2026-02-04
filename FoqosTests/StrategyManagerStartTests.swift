// FoqosTests/StrategyManagerStartTests.swift
import XCTest

@testable import FamilyFoqos

@MainActor
final class StrategyManagerStartTests: XCTestCase {

  func testDetermineStartActionForManualOnly() {
    var start = ProfileStartTriggers()
    start.manual = true

    let action = StrategyManager.determineStartAction(for: start)

    XCTAssertEqual(action, .startImmediately)
  }

  func testDetermineStartActionForNFCOnly() {
    var start = ProfileStartTriggers()
    start.anyNFC = true

    let action = StrategyManager.determineStartAction(for: start)

    XCTAssertEqual(action, .scanNFC)
  }

  func testDetermineStartActionForQROnly() {
    var start = ProfileStartTriggers()
    start.anyQR = true

    let action = StrategyManager.determineStartAction(for: start)

    XCTAssertEqual(action, .scanQR)
  }

  func testDetermineStartActionForScheduleOnly() {
    var start = ProfileStartTriggers()
    start.schedule = true

    let action = StrategyManager.determineStartAction(for: start)

    XCTAssertEqual(action, .waitForSchedule)
  }

  func testDetermineStartActionForManualPlusNFC() {
    var start = ProfileStartTriggers()
    start.manual = true
    start.anyNFC = true

    let action = StrategyManager.determineStartAction(for: start)

    XCTAssertEqual(action, .showPicker(options: [.startImmediately, .scanNFC]))
  }

  func testDetermineStartActionForNFCPlusQR() {
    var start = ProfileStartTriggers()
    start.anyNFC = true
    start.anyQR = true

    let action = StrategyManager.determineStartAction(for: start)

    XCTAssertEqual(action, .showPicker(options: [.scanNFC, .scanQR]))
  }

  func testDetermineStartActionForAllManualOptions() {
    var start = ProfileStartTriggers()
    start.manual = true
    start.anyNFC = true
    start.anyQR = true

    let action = StrategyManager.determineStartAction(for: start)

    XCTAssertEqual(action, .showPicker(options: [.startImmediately, .scanNFC, .scanQR]))
  }
}
