import XCTest

@testable import FamilyFoqos

@MainActor
final class StartupRecoveryRuntimeTests: XCTestCase {
  func testGivenConsumerAccessBeforeComposition_WhenRuntimeLoads_ThenItIsHeld() {
    let runtime = StartupRecoveryRuntime()

    XCTAssertTrue(runtime.isHeld)

    runtime.release()
    runtime.release()
    XCTAssertFalse(runtime.isHeld)
  }

  func testGivenHeldRuntime_WhenRoutingSilentPush_ThenReleasedWorkDoesNotRun() async {
    var heldCompletions = 0
    var accountCalls = 0
    var membershipCalls = 0
    var syncCalls = 0
    var heartbeatCalls = 0

    await StartupRecoveryPushRouter.route(
      isHeld: true,
      onHeld: { heldCompletions += 1 },
      onReleased: {
        accountCalls += 1
        membershipCalls += 1
        syncCalls += 1
        heartbeatCalls += 1
      })

    XCTAssertEqual(heldCompletions, 1)
    XCTAssertEqual(accountCalls, 0)
    XCTAssertEqual(membershipCalls, 0)
    XCTAssertEqual(syncCalls, 0)
    XCTAssertEqual(heartbeatCalls, 0)
  }

  func testGivenReleasedRuntime_WhenRoutingSilentPush_ThenExistingRouteRuns() async {
    var heldCompletions = 0
    var releasedCalls = 0

    await StartupRecoveryPushRouter.route(
      isHeld: false,
      onHeld: { heldCompletions += 1 },
      onReleased: { releasedCalls += 1 })

    XCTAssertEqual(heldCompletions, 0)
    XCTAssertEqual(releasedCalls, 1)
  }

  func testShareArbitrationSourceMakesMissingCoordinatorObservable() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = repositoryRoot.appendingPathComponent(
      "Foqos/Utils/StartupRecoveryRuntime.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains("assertionFailure("))
    XCTAssertTrue(source.contains("Log.error("))
    XCTAssertFalse(source.contains("coordinator?.beginShareAcceptance()"))
    XCTAssertFalse(source.contains("coordinator?.failShareAcceptance()"))
    XCTAssertFalse(source.contains("coordinator?.completeShareAcceptanceAfterModeApplied()"))
  }
}
