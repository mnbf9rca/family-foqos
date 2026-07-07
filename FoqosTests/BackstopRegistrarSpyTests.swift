import XCTest

@testable import FamilyFoqos

final class BackstopRegistrarSpyTests: XCTestCase {
  func testGivenSpy_WhenReplaceThrowsConfigured_ThenReplaceThrows() {
    let spy = RecordingBackstopRegistrar()
    spy.throwOnReplaceBreak = true
    XCTAssertThrowsError(
      try spy.replaceBreakBackstop(profileId: UUID(), deadline: Date(), now: Date()))
  }

  func testGivenSpyReportsPresent_WhenRegisterIfAbsent_ThenReturnsFalseAndDoesNotRegister() {
    let spy = RecordingBackstopRegistrar()
    spy.hasBreakBackstopReturns = true
    let registered = try! spy.registerBreakBackstopIfAbsent(
      profileId: UUID(), deadline: Date(), now: Date())
    XCTAssertFalse(registered)
    XCTAssertTrue(
      spy.calls.contains {
        if case .registerBreakIfAbsent = $0 { return true }
        return false
      })
    XCTAssertFalse(spy.didStartMonitoringBreak)
  }

  func testGivenRealRegistrar_WhenConstructed_ThenConformsToProtocol() {
    let registrar: BackstopRegistering = DeviceActivityBackstopRegistrar()
    XCTAssertNotNil(registrar)
  }
}
