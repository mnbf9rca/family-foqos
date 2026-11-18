import AppIntents
import SwiftData
import UIKit
import XCTest

@testable import FamilyFoqos

@MainActor
final class ProtectedStoreLaunchTests: XCTestCase {
  private let evidence = StartupRecoveryLocalSnapshot(
    onboardingValuePresent: true, appGroupStatePresent: true, store: .profileCount(1))

  func testUnavailableLaunchDoesNothingUntilUnlockThenReusesTheOpenStore() throws {
    let container = try TestModelContainer.create()
    var isUnlocked = false
    var events: [String] = []
    let launch = ProtectedStoreLaunch(
      isProtectedDataAvailable: { isUnlocked },
      probeStore: { .readFailed },
      capture: {
        events.append("capture")
        return self.evidence
      },
      open: {
        events.append("open")
        return container
      },
      prepare: { _ in events.append("prepare") })

    launch.refresh()
    XCTAssertThrowsError(try launch.readyContainer())
    XCTAssertEqual(events, [])

    isUnlocked = true
    launch.refresh()
    launch.refresh()
    isUnlocked = false
    launch.refresh()

    XCTAssertTrue(try launch.readyContainer() === container)
    XCTAssertEqual(events, ["capture", "open", "prepare"])
  }

  func testColdRelockRequiresAReadableExistingStore() throws {
    let cases: [(StartupRecoveryStoreFinding, Bool)] = [
      (.tableMissing, true), (.profileCount(2), true),
      (.storeAbsent, false), (.readFailed, false),
    ]
    let container = try TestModelContainer.create()
    for (finding, shouldOpen) in cases {
      var opened = false
      let launch = ProtectedStoreLaunch(
        isProtectedDataAvailable: { false },
        probeStore: { finding },
        capture: { self.evidence },
        open: {
          opened = true
          return container
        })

      launch.refresh()

      XCTAssertEqual(opened, shouldOpen, "\(finding)")
      XCTAssertEqual((try? launch.readyContainer()) != nil, shouldOpen, "\(finding)")
    }
  }

  func testOpenFailureRetainsTheOriginalSnapshotForRetry() throws {
    let container = try TestModelContainer.create()
    var isUnlocked = true
    var captures = 0
    var opens = 0
    var preparations = 0
    let launch = ProtectedStoreLaunch(
      isProtectedDataAvailable: { isUnlocked },
      probeStore: { .readFailed },
      capture: {
        captures += 1
        return self.evidence
      },
      open: {
        opens += 1
        if opens == 1 { throw TestFailure.open }
        return container
      },
      prepare: { _ in preparations += 1 })

    launch.refresh()
    guard case .failed = launch.state else { return XCTFail("Expected an open failure") }
    XCTAssertEqual(opens, 1)
    XCTAssertEqual(preparations, 0)

    isUnlocked = false
    XCTAssertThrowsError(try launch.readyContainer())
    launch.refresh()
    XCTAssertEqual(opens, 1)

    isUnlocked = true
    launch.refresh()
    guard case .ready(let readyContainer, let snapshot) = launch.state else {
      return XCTFail("Expected an open store")
    }
    XCTAssertTrue(readyContainer === container)
    XCTAssertEqual(snapshot, evidence)
    XCTAssertEqual(captures, 1)
    XCTAssertEqual(opens, 2)
    XCTAssertEqual(preparations, 1)
  }

  func testUnlockIsObservedWithoutASceneAndReleasesQueuedEventsOnce() async throws {
    let container = try TestModelContainer.create()
    let center = NotificationCenter()
    let ready = expectation(description: "Opened after unlock")
    var isUnlocked = false
    var prepared = false
    var deliveries = 0
    let launch = ProtectedStoreLaunch(
      isProtectedDataAvailable: { isUnlocked },
      probeStore: { .readFailed },
      capture: { self.evidence },
      open: { container },
      prepare: { _ in prepared = true })

    launch.startObserving(center: center)
    launch.refresh()
    launch.afterOpen {
      XCTAssertTrue(prepared)
      XCTAssertTrue((try? launch.readyContainer()) === container)
      deliveries += 1
      ready.fulfill()
    }
    XCTAssertEqual(deliveries, 0)

    isUnlocked = true
    center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
    center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    await fulfillment(of: [ready], timeout: 2)

    XCTAssertEqual(deliveries, 1)
  }

  func testHeldBackgroundEntriesCompleteOnceAndSceneDeliveryWaitsUntilUnlock() async throws {
    let container = try TestModelContainer.create()
    let profileID = UUID()

    var isUnlocked = false
    var preparations = 0
    var recoveryReads = 0
    var backgroundRuns = 0
    var retryDates: [Date] = []
    let now = Date()
    let expectedRetry = now.addingTimeInterval(15 * 60)
    let launch = ProtectedStoreLaunch(
      isProtectedDataAvailable: { isUnlocked },
      probeStore: { .readFailed },
      capture: { self.evidence },
      open: { container },
      prepare: { _ in preparations += 1 })

    let navigation = NavigationManager()
    let delegate = SceneDelegate(navigation: navigation, launch: launch)
    let url = try XCTUnwrap(URL(string: "https://family-foqos.app/profile/\(profileID)"))
    let warmID = UUID()
    let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    activity.webpageURL = try XCTUnwrap(URL(string: "https://family-foqos.app/profile/\(warmID)"))

    launch.refresh()
    delegate.receiveConnection(activities: [], urls: [url])
    launch.afterOpen { navigation.receiveSwiftUI(url) }
    delegate.receiveActivity(activity)
    delegate.receiveActivity(activity)
    XCTAssertTrue(navigation.deliveries.isEmpty)

    func isRecoveryHeld() -> Bool {
      recoveryReads += 1
      return false
    }

    var pushCompletions: [UIBackgroundFetchResult] = []
    await AppDelegate.routeProtectedPush(
      launch: launch, isRecoveryHeld: isRecoveryHeld(),
      onHeld: { pushCompletions.append(.noData) },
      onReleased: { pushCompletions.append(.newData) })
    let processed = TimersUtil.processBackgroundTaskIfReady(
      launch: launch,
      now: now,
      process: {
        backgroundRuns += 1
        return true
      },
      reschedule: { retryDates.append($0) })
    XCTAssertEqual(pushCompletions, [.noData])
    XCTAssertFalse(processed)
    XCTAssertEqual(recoveryReads, 0)
    XCTAssertEqual(backgroundRuns, 0)
    XCTAssertEqual(retryDates, [expectedRetry])
    XCTAssertEqual(preparations, 0)

    isUnlocked = true
    launch.refresh()

    XCTAssertEqual(preparations, 1)
    XCTAssertEqual(retryDates, [expectedRetry])
    XCTAssertEqual(navigation.deliveries, [.link(profileId: profileID), .link(profileId: warmID)])
    let laterID = UUID()
    delegate.receiveURL(try XCTUnwrap(URL(string: "https://family-foqos.app/profile/\(laterID)")))
    XCTAssertEqual(navigation.deliveries.last, .link(profileId: laterID))
  }

  func testQueriesAndIntentsWaitForUnlockThenUseTheSameStoreOnRelock() async throws {
    let container = try TestModelContainer.create()
    let profile = BlockedProfiles(name: "Before Reboot")
    container.mainContext.insert(profile)
    try container.mainContext.save()
    let entity = BlockedProfileEntity(profile: profile)
    var isUnlocked = false
    var opens = 0
    let launch = ProtectedStoreLaunch(
      isProtectedDataAvailable: { isUnlocked },
      probeStore: { .readFailed },
      capture: { self.evidence },
      open: {
        opens += 1
        return container
      })

    let query = BlockedProfilesQuery(launch: launch)
    let sessionStatus = CheckSessionActiveIntent(launch: launch)
    let profileStatus = CheckProfileStatusIntent(launch: launch)
    profileStatus.profile = entity
    let start = StartProfileIntent(launch: launch)
    start.profile = entity
    let stop = StopProfileIntent(launch: launch)
    stop.profile = entity
    launch.refresh()

    let lockedCalls: [() async throws -> Void] = [
      { _ = try await query.suggestedEntities() },
      { _ = try await sessionStatus.perform() },
      { _ = try await profileStatus.perform() },
      { _ = try await start.perform() },
      { _ = try await stop.perform() },
    ]
    for call in lockedCalls {
      do {
        try await call()
        XCTFail("Expected locked store access to throw")
      } catch ProtectedStoreLaunch.Unavailable.waitingForUnlock {
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertEqual(opens, 0)

    isUnlocked = true
    launch.refresh()
    isUnlocked = false
    launch.refresh()

    let suggestions = try await query.suggestedEntities()
    XCTAssertEqual(suggestions.map(\.id), [entity.id])
    let sessionResult = try await sessionStatus.perform()
    let profileResult = try await profileStatus.perform()
    XCTAssertEqual(sessionResult.value, false)
    XCTAssertEqual(profileResult.value, false)

    var startedProfileID: UUID?
    _ = try start.perform { id, context, duration in
      XCTAssertTrue(context === container.mainContext)
      XCTAssertNil(duration)
      startedProfileID = id
      return "Before Reboot"
    }
    XCTAssertEqual(startedProfileID, entity.id)
    XCTAssertEqual(opens, 1)
  }

  func testEachBackgroundEntryCanOpenAfterUnlockWithoutASceneOrNotification() async throws {
    let container = try TestModelContainer.create()
    let profile = BlockedProfiles(name: "Persisted profile")
    container.mainContext.insert(profile)
    try container.mainContext.save()

    var isUnlocked = false
    var opens = 0
    func makeLaunch() -> ProtectedStoreLaunch {
      isUnlocked = false
      let launch = ProtectedStoreLaunch(
        isProtectedDataAvailable: { isUnlocked },
        probeStore: { .readFailed },
        capture: { self.evidence },
        open: {
          opens += 1
          return container
        })
      launch.refresh()
      XCTAssertFalse(launch.isReady)
      isUnlocked = true
      return launch
    }

    let intentLaunch = makeLaunch()
    let query = BlockedProfilesQuery(launch: intentLaunch)
    let suggestions = try await query.suggestedEntities()
    XCTAssertEqual(suggestions.map(\.name), ["Persisted profile"])
    XCTAssertEqual(opens, 1)

    let pushLaunch = makeLaunch()
    var pushCompletions: [UIBackgroundFetchResult] = []
    await AppDelegate.routeProtectedPush(
      launch: pushLaunch, isRecoveryHeld: false,
      onHeld: { pushCompletions.append(.noData) },
      onReleased: { pushCompletions.append(.newData) })
    XCTAssertEqual(pushCompletions, [.newData])
    XCTAssertEqual(opens, 2)

    let processingLaunch = makeLaunch()
    let processed = TimersUtil.processBackgroundTaskIfReady(
      launch: processingLaunch, process: { true },
      reschedule: { _ in XCTFail("Ready task should be processed immediately") })
    XCTAssertTrue(processed)
    XCTAssertEqual(opens, 3)
  }

  private enum TestFailure: Error { case open }
}
