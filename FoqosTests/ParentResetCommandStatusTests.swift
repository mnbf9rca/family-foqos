import CloudKit
import XCTest

@testable import FamilyFoqos

@MainActor
final class ParentResetCommandStatusTests: XCTestCase {
  func testLateDeletionUpdatesStatusAfterMoreThanFivePendingProbes() async {
    let now = Date()
    let command = FamilyCommand(
      commandType: .resetEmergencyCount, targetChildId: "child", createdBy: "parent",
      createdAt: now.addingTimeInterval(-120))
    var status = ParentResetCommandStatus.awaitingChild(command)
    for _ in 0..<8 {
      status = await status.refreshed { probed in
        XCTAssertEqual(probed, command)
        return true
      }
    }
    XCTAssertEqual(status.pendingCommand, command)
    XCTAssertEqual(
      status.displayText,
      "Emergency unblock reset sent. Waiting for the child's phone to pick it up.")

    status = await status.refreshed { _ in false }
    XCTAssertNil(status.pendingCommand)
    XCTAssertEqual(status.displayText, "Emergency unblock reset delivered.")
  }

  func testProbeFailureKeepsIdentityAndAllowsLaterRetry() async {
    let now = Date()
    let command = FamilyCommand(
      commandType: .resetEmergencyCount, targetChildId: "child", createdBy: "parent",
      createdAt: now)
    let pending = ParentResetCommandStatus.awaitingChild(command)
    let afterError = await pending.refreshed { _ in throw CKError(.networkUnavailable) }
    XCTAssertEqual(afterError, pending)
    XCTAssertEqual(afterError.pendingCommand?.id, command.id)
    let delivered = await afterError.refreshed { _ in false }
    XCTAssertEqual(delivered.displayText, "Emergency unblock reset delivered.")
    XCTAssertNil(delivered.pendingCommand)
  }

  func testCancellationKeepsPendingInsteadOfClaimingDelivery() async {
    let now = Date()
    let command = FamilyCommand(
      commandType: .resetEmergencyCount, targetChildId: "child", createdBy: "parent",
      createdAt: now)
    let pending = ParentResetCommandStatus.awaitingChild(command)
    let cancelled = await pending.refreshed { _ in throw CancellationError() }
    XCTAssertEqual(cancelled, pending)
  }

  func testEmergencyAndPINAttemptsRemainIndependent() async {
    let now = Date()
    let emergency = FamilyCommand(
      commandType: .resetEmergencyCount, targetChildId: "child", createdBy: "parent",
      createdAt: now)
    let pin = FamilyCommand(
      commandType: .resetLockCodeThrottle, targetChildId: "child", createdBy: "parent",
      createdAt: now.addingTimeInterval(1))
    var states: [FamilyCommandType: ParentResetCommandStatus] = [
      .resetEmergencyCount: .awaitingChild(emergency),
      .resetLockCodeThrottle: .awaitingChild(pin),
    ]
    states[.resetLockCodeThrottle] = await states[.resetLockCodeThrottle]?.refreshed { command in
      XCTAssertEqual(command.commandType, .resetLockCodeThrottle)
      return false
    }
    XCTAssertEqual(states[.resetEmergencyCount]?.pendingCommand, emergency)
    XCTAssertEqual(states[.resetLockCodeThrottle]?.displayText, "PIN attempts reset delivered.")
  }

  func testPINPendingNamesTheOperationRatherThanChangingTheCode() {
    let now = Date()
    let command = FamilyCommand(
      commandType: .resetLockCodeThrottle, targetChildId: "child", createdBy: "parent",
      createdAt: now)
    XCTAssertEqual(
      ParentResetCommandStatus.awaitingChild(command).displayText,
      "PIN attempts reset sent. Waiting for the child's phone to pick it up.")
  }

  func testIdleAndDeliveredDoNotProbeAgain() async {
    for status in [ParentResetCommandStatus.idle, .noLongerPending(.resetEmergencyCount)] {
      let refreshed = await status.refreshed { _ in
        XCTFail("Only pending commands should be checked")
        return true
      }
      XCTAssertEqual(refreshed, status)
    }
    XCTAssertNil(ParentResetCommandStatus.idle.displayText)
  }

  func testSendFailuresNameTheOperationWithoutRawErrorText() {
    XCTAssertEqual(
      ParentResetCommandStatus.sendFailureMessage(for: .resetEmergencyCount),
      "Couldn't send the emergency unblock reset. Check your connection and try again.")
    XCTAssertEqual(
      ParentResetCommandStatus.sendFailureMessage(for: .resetLockCodeThrottle),
      "Couldn't send the PIN attempts reset. Check your connection and try again.")
  }

  func testAutomaticPollingSurvivesErrorAndFiveProbesThenUsesBackoffUntilDelivery() async {
    let now = Date()
    let command = FamilyCommand(
      commandType: .resetEmergencyCount, targetChildId: "child", createdBy: "parent", createdAt: now)
    var status = ParentResetCommandStatus.awaitingChild(command)
    var clock = now
    var probeCount = 0
    var delays: [Duration] = []
    await ParentResetCommandStatus.poll(
      pendingCommands: { status.pendingCommand.map { [$0] } ?? [] },
      probe: { probed in
        XCTAssertEqual(probed.id, command.id)
        probeCount += 1
        if probeCount == 2 { throw CKError(.networkUnavailable) }
        return clock < now.addingTimeInterval(60)
      },
      apply: { _, next in status = next },
      sleep: { delay in
        delays.append(delay)
        guard delays.count < 10 else {
          XCTFail("Polling did not stop after delivery")
          throw CancellationError()
        }
        clock = clock.addingTimeInterval(delay == .seconds(3) ? 3 : 30)
      })
    XCTAssertEqual(status.displayText, "Emergency unblock reset delivered.")
    XCTAssertNil(status.pendingCommand)
    XCTAssertEqual(probeCount, 8)
    XCTAssertEqual(delays, [.seconds(3), .seconds(3), .seconds(3), .seconds(3), .seconds(3), .seconds(30), .seconds(30)])
  }

  func testAutomaticPollingDiscardsProbeForReplacedCommand() async {
    let now = Date()
    let old = FamilyCommand(
      commandType: .resetEmergencyCount, targetChildId: "child", createdBy: "parent", createdAt: now)
    let replacement = FamilyCommand(
      commandType: .resetEmergencyCount, targetChildId: "child", createdBy: "parent",
      createdAt: now.addingTimeInterval(1))
    var status = ParentResetCommandStatus.awaitingChild(old)
    var probeCount = 0
    await ParentResetCommandStatus.poll(
      pendingCommands: { status.pendingCommand.map { [$0] } ?? [] },
      probe: { _ in
        probeCount += 1
        status = .awaitingChild(replacement)
        return false
      },
      apply: { _, _ in XCTFail("An old probe must not mark the replacement delivered") },
      sleep: { _ in throw CancellationError() })
    XCTAssertEqual(status.pendingCommand, replacement)
    XCTAssertEqual(probeCount, 1)
  }

  func testAutomaticPollingDiscardsCancelledProbeAndDoesNotSleepOrProbeAgain() async {
    let now = Date()
    let command = FamilyCommand(
      commandType: .resetEmergencyCount, targetChildId: "child", createdBy: "parent", createdAt: now)
    var status = ParentResetCommandStatus.awaitingChild(command)
    var probeCount = 0
    let task = Task { @MainActor in
      await ParentResetCommandStatus.poll(
        pendingCommands: { status.pendingCommand.map { [$0] } ?? [] },
        probe: { _ in
          probeCount += 1
          withUnsafeCurrentTask { $0?.cancel() }
          return false
        },
        apply: { _, next in status = next },
        sleep: { _ in
          XCTFail("A cancelled task must not sleep")
          throw CancellationError()
        })
    }
    await task.value
    XCTAssertEqual(status.pendingCommand, command)
    XCTAssertEqual(probeCount, 1)
  }

}
