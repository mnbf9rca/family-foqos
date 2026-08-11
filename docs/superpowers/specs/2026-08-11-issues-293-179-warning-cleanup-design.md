# Issues #293 and #179: Swift Warning Cleanup

## Goal

Remove the settled tree's known Swift 6 test/build warning noise without changing app behavior. Close #293 and #179 in one final hygiene PR.

## Settled-tree baseline

The full serialized test run at `50e849a` passes 1,223 tests with zero failures and emits 167 raw `warning:` lines:

- 117 emissions from 13 nested-optional tombstone assertion sites compiled in nine passes;
- 42 XCTest lifecycle actor-isolation warnings across five `@MainActor` test classes;
- four main-actor call warnings in `TimerDurationSnapTests`;
- two StoreKit deprecation warnings in `RatingManager`;
- two Xcode App Intents metadata notices from targets without App Intents dependencies.

The `HeartbeatManager` exhaustiveness warning named in #293 is absent from the settled tree, so no Heartbeat change is justified.

## Root causes and design

### XCTest lifecycle isolation

Five `@MainActor` test classes override synchronous `setUp()` and `tearDown()`. XCTest declares those synchronous overrides nonisolated, so they cannot safely access main-actor state. Convert only those overrides to the established async-throwing lifecycle pattern used by clean neighboring tests:

```swift
override func setUp() async throws {
  try await super.setUp()
  // existing setup, unchanged
}
```

Teardown retains its existing ordering and calls `try await super.tearDown()` last.

### Timer snap tests

`TimerDurationView` is main-actor isolated through SwiftUI, while its tests are not. Mark the test class `@MainActor`; do not change the production function or its isolation contract.

### Nested optional assertions

`deleteTombstones` is `[String: String?]`: dictionary lookup produces `String??` because a present tombstone may intentionally carry a nil change tag. The affected tests intend to assert durable key presence or absence, not inspect the change tag. Replace `XCTAssertNil`/`XCTAssertNotNil` on the nested optional with `deleteTombstones.keys.contains(recordName)`. This removes coercion and makes the assertions match their stated contract.

### StoreKit deprecation

The installed iOS SDK declares `AppStore.requestReview(in:)` as the direct iOS 16+ replacement for `SKStoreReviewController.requestReview(in:)`. The project deploys to iOS 18.6, so replace the call directly while preserving the existing foreground-scene selection.

### Xcode metadata notices

Two targets without App Intents dependencies emit tool-owned metadata-extraction notices. Xcode's installed `AppIntentsMetadata.xcspec` defines `LM_FILTER_WARNINGS = YES` as `--quiet-warnings` for that processor only. Set it in the project's Debug and Release configurations so metadata-extractor notices are quiet while Swift compiler warnings remain visible.

## Verification

- Run focused tests for all edited test classes.
- Run a clean serialized full test and capture the raw stream.
- Require zero `warning:` lines in the captured stream.
- Run a clean serialized Debug build and require zero `warning:` lines.
- Run formatting, diff, C2, sync, strict-version, and privacy gates.
- Obtain independent review of the exact verified head.

The release advances from 2.0.15 (34) to 2.0.16 (35). Privacy baselines remain unchanged.
