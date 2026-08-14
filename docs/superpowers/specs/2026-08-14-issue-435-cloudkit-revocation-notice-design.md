# Issue #435 CloudKit Revocation Notice Design

## Goal

Explain a confirmed CloudKit family removal after the app safely clears Child state and switches
to Individual mode. The explanation must work whether foreground activation or a silent shared-
database push discovers the removal, and it must remain separate from share-acceptance errors.

## Root cause

`CloudKitManager.verifySelfFamilyMemberRecord()` discards the string returned by the destructive
revocation cleanup. Foreground activation therefore silently changes modes. The #437 background
push path refreshes shared child data without first running the membership verifier, so it cannot
publish the same explanation when the push is the first evidence of removal. The existing
`shareAcceptedMessage` alert is semantically wrong for a device leaving a family.

`ChildRevocationCacheTests` also changes the process-global `AppModeManager` in setup and teardown.
That mode change launches the manager's asynchronous writer even though the cache test does not
depend on mode, allowing work to escape the test boundary.

## Approved design

Add dedicated one-shot `CloudKitManager.familyRevocationMessage` state. A single confirmed-
revocation transition clears authorization/shared/PIN state, selects Individual, and only then
publishes this exact message:

> This device is no longer connected to its Family Foqos family in iCloud, so it switched to
> Individual mode. To reconnect, ask a parent to send a new invitation.

The root view presents that state in its own alert titled **Family Connection Removed**, with an
OK action that clears the optional message. Do not reuse `shareAcceptedMessage` or
`shareAcceptanceIsError`.

Foreground activation continues to refresh account status and call
`verifySelfFamilyMemberRecord()`. For a child shared-database notification, the background handler
first refreshes account status, then calls that same verifier before refreshing shared lock codes
and commands. This ordering prevents a cold-launched singleton's default `isSignedIn == false`
from suppressing confirmed revocation. A confirmed removal reports new data and skips the
now-inapplicable child refresh; an ambiguous/offline lookup remains non-destructive under #431 and
proceeds with the existing fail-closed refresh.

Make the confirmation predicate a named `Bool` (`isConfirmedRevocation`) rather than a single-case
optional enum. Make `AuthorizationVerifier.handleConfirmedCloudKitRevocation()` return `Void`, and
remove the redundant iOS 26.4 equality check while retaining the exhaustive typed
`FamilyControlsError` switch, its `.unauthorized` case, and `@unknown default`.

## Testing

Use TDD to cover:

- the exact title and message, including `iCloud`, `Individual`, and reconnection guidance;
- the CloudKit message excludes `Screen Time` and `Family Sharing`;
- confirmed cleanup publishes the one-shot message after its cleanup dependency runs;
- both foreground's common verifier and the child shared-database background route reach that
  same transition, while the push skips child refresh after revocation and reports new data;
- non-revocation background refresh behavior remains unchanged;
- the renamed Bool predicate preserves every positive and negative fixture;
- typed Family Controls mapping remains exhaustive without the redundant pre-check; and
- `ChildRevocationCacheTests` erases the PIN cache without reading or mutating global app mode.

Run focused revocation, cache, background-refresh, and Family Controls tests before the complete
simulator-gated suite, standalone Debug build, changed-file format lint, `git diff --check`, project
guards, and independent exact-head review.

## Delivery

Work in `.worktrees/build1-435` on `fix/435-revocation-notice`, based on main `3410b5d` at version
2.0.42 (61). Set every target configuration to the planner-reserved version 2.0.44 (63). Use only
new signed commits, publish a ready-for-review PR closing #435, and leave merge ownership with the
planner.
