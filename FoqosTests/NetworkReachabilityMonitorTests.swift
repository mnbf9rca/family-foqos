import XCTest

@testable import FamilyFoqos

@MainActor
final class NetworkReachabilityMonitorTests: XCTestCase {
  func testReconnectFiresOnlyOnUnsatisfiedToSatisfiedEdge() {
    let monitor = NetworkReachabilityMonitor()
    var reconnects = 0
    monitor.onReconnect = { reconnects += 1 }

    monitor.handlePathUpdate(isSatisfied: true)
    XCTAssertTrue(monitor.isOnline)
    XCTAssertEqual(reconnects, 0)

    monitor.handlePathUpdate(isSatisfied: false)
    XCTAssertFalse(monitor.isOnline)
    XCTAssertEqual(reconnects, 0)

    monitor.handlePathUpdate(isSatisfied: true)
    XCTAssertTrue(monitor.isOnline)
    XCTAssertEqual(reconnects, 1)

    monitor.handlePathUpdate(isSatisfied: true)
    XCTAssertEqual(reconnects, 1)
  }
}
