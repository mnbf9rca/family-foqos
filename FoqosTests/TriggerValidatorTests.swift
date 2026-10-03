import FoqosShared
import XCTest

@testable import FamilyFoqos

final class TriggerValidatorTests: XCTestCase {
  private let validator = TriggerValidator()
  private let c5 = "Choose at least one way to start this profile."
  private let c6 = "Add at least one stop before saving this profile."
  private let c7NFC = "Same NFC tag only works after an NFC start. Add another stop for other starts."
  private let c7QR = "Same QR code only works after a QR start. Add another stop for other starts."
  private let c7Link = "Links can come from NFC tags or QR codes. Add a stop that doesn’t rely on the same tag."
  private let c8NFC = "Choose at least one NFC tag."
  private let c8QR = "Choose at least one QR code."
  private let c9 = "Choose the days and time for this schedule."
  private let c11 = "Choose a timer from 15 minutes to 23 hours 59 minutes."
  private let c12 = "These settings couldn’t be saved. Please check this profile and try again."

  func testSaveRequiresRealWellFormedStop() {
    XCTAssertEqual(validator.validate(start: .init(), stop: .init(manual: true)), [c5])
    for stop in [ProfileStopConditions(), .init(deepLink: true)] {
      XCTAssertEqual(validator.validate(start: .init(manual: true), stop: stop), [c6])
    }
    XCTAssertEqual(validator.validate(start: .init(manual: true), stop: .init(manual: true), settingsReadable: false), [c12])
    for ids in [[], [""], [" \n "]] {
      XCTAssertTrue(validator.validate(start: .init(specificNFC: true), stop: .init(manual: true), startNFCTagIds: ids).contains(c8NFC))
      XCTAssertTrue(validator.validate(start: .init(specificQR: true), stop: .init(manual: true), startQRCodeIds: ids).contains(c8QR))
      XCTAssertTrue(validator.validate(start: .init(manual: true), stop: .init(nfc: .specific), stopNFCTagIds: ids).contains(c8NFC))
      XCTAssertTrue(validator.validate(start: .init(manual: true), stop: .init(qr: .specific), stopQRCodeIds: ids).contains(c8QR))
    }
    XCTAssertTrue(validator.validate(start: .init(specificNFC: true), stop: .init(nfc: .specific), startNFCTagIds: ["A0FF"], stopNFCTagIds: ["B0FF"]).isEmpty)
    XCTAssertTrue(validator.validate(start: .init(manual: true), stop: .init(qr: .specific), stopQRCodeIds: ["qr-digest"]).isEmpty)
  }

  func testManualAndNFCWithSameOnlyNeedsAnotherStop() {
    XCTAssertEqual(validator.validate(start: .init(manual: true, anyNFC: true), stop: .init(sameNFC: true)), [c7NFC])
  }

  func testSameCoverageMatrix() {
    let now = Date()
    let schedule = ProfileScheduleTime(days: [.monday], hour: 9, minute: 0, updatedAt: now)
    XCTAssertTrue(validator.validate(start: .init(anyNFC: true), stop: .init(nfc: .same)).isEmpty)
    XCTAssertTrue(validator.validate(start: .init(anyQR: true), stop: .init(qr: .same)).isEmpty)
    let otherStarts: [ProfileStartTriggers] = [.init(manual: true), .init(shortcuts: true), .init(schedule: true), .init(anyQR: true)]
    for start in otherStarts {
      XCTAssertEqual(validator.validate(start: start, stop: .init(nfc: .same), startSchedule: schedule), [c7NFC])
      XCTAssertTrue(validator.validate(start: start, stop: .init(manual: true, nfc: .same), startSchedule: schedule).isEmpty)
    }
    XCTAssertEqual(validator.validate(start: .init(anyNFC: true), stop: .init(qr: .same)), [c7QR])
    XCTAssertEqual(validator.validate(start: .init(anyNFC: true, anyQR: true), stop: .init(nfc: .same, qr: .same)), [c7NFC])
    XCTAssertEqual(validator.validate(start: .init(anyNFC: true, deepLink: true), stop: .init(nfc: .same)), [c7Link])
    XCTAssertEqual(validator.validate(start: .init(deepLink: true), stop: .init(qr: .same)), [c7Link])
    XCTAssertTrue(validator.validate(start: .init(manual: true), stop: .init(nfc: .same, qr: .specific), stopQRCodeIds: ["digest"]).isEmpty)
    let invalidSpecific = validator.validate(start: .init(manual: true), stop: .init(nfc: .same, qr: .specific))
    XCTAssertTrue(invalidSpecific.contains(c7NFC))
    XCTAssertTrue(invalidSpecific.contains(c8QR))
  }

  func testOwnedScheduleAndTimerValidation() throws {
    let now = Date()
    for schedule in [
      nil, ProfileScheduleTime(days: [], hour: 9, minute: 0, updatedAt: now),
      .init(days: [.monday], hour: -1, minute: 0, updatedAt: now),
      .init(days: [.monday], hour: 24, minute: 0, updatedAt: now),
      .init(days: [.monday], hour: 9, minute: -1, updatedAt: now),
      .init(days: [.monday], hour: 9, minute: 60, updatedAt: now),
    ] {
      XCTAssertTrue(validator.validate(start: .init(schedule: true), stop: .init(manual: true), startSchedule: schedule).contains(c9))
      XCTAssertTrue(validator.validate(start: .init(manual: true), stop: .init(schedule: true), stopSchedule: schedule).contains(c9))
    }
    for minutes in [15, 37, 1439] {
      XCTAssertTrue(validator.validate(start: .init(manual: true), stop: .init(timer: true, timerDurationMinutes: minutes)).isEmpty)
    }
    for minutes: Int? in [nil, 0, -1, 14, 1440] {
      XCTAssertTrue(validator.validate(start: .init(manual: true), stop: .init(manual: true, timer: true, timerDurationMinutes: minutes)).contains(c11))
      if minutes != nil {
        XCTAssertTrue(validator.validate(start: .init(manual: true), stop: .init(manual: true, timer: true, timerDurationMinutes: minutes), forSave: false).contains(c11))
      }
    }
    XCTAssertTrue(validator.validate(start: .init(manual: true), stop: .init(timer: true, nfc: .any), forSave: false).isEmpty)
    XCTAssertEqual(validator.validate(start: .init(manual: true), stop: .init(timer: true), forSave: false), [c6])
    XCTAssertEqual(validator.validate(start: .init(manual: true), stop: .init(manual: true, requiresEditingAfterConversion: true), forSave: false), [c12])
    XCTAssertTrue(validator.validate(start: .init(manual: true), stop: .init(manual: true, requiresEditingAfterConversion: true)).isEmpty)
  }
  func testIndependentScheduleChecksApplyToStoredAndSaveValidation() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let start = ProfileScheduleTime(days: [.monday], hour: 9, minute: 0, updatedAt: now)
    for forSave in [true, false] {
      for stopDays in [[Weekday.monday], [.friday]] {
        for minute in [0, 1, 14, 15] {
          let stop = ProfileScheduleTime(days: stopDays, hour: 9, minute: minute, updatedAt: now)
          let errors = validator.validate(start: .init(schedule: true), stop: .init(schedule: true), startSchedule: start, stopSchedule: stop, forSave: forSave)
          XCTAssertEqual(errors, stopDays == [.monday] && minute == 0 ? ["Choose different moments for scheduled start and stop."] : [])
        }
      }
    }
  }
}
