# Family Revocation Notice Persistence Design

## Goal

Preserve the existing confirmed-family-revocation explanation across process termination. If a
silent push demotes a Child device and the app terminates before foregrounding, the next launch
must present the same **Family Connection Removed** alert with no new UX or copy.

## Root cause

`CloudKitManager.familyRevocationMessage` is only in memory. Background verification correctly
cleans family state and selects Individual before publishing that message, but termination loses
the message while the persisted mode remains Individual. The next launch therefore cannot explain
why the mode changed.

The revocation cache test also checks only the persisted lock-code key. It no longer proves that
`LockCodeManager.cachedLockCodes` is emptied because the public verification probe reads that cache
only in Child mode and would reintroduce process-global mode mutation.

## Approved design

Add a small `UserDefaults`-backed pending-notice store. Confirmed revocation performs cleanup and
persists the mode first, marks the notice pending second, and publishes the existing in-memory
message last. This ordering never claims a demotion that did not happen. On construction,
`CloudKitManager` maps a pending flag to the existing exact alert message. Dismissing the alert
clears both the persisted flag and in-memory message.

Keep the store independently constructible with an injected defaults suite so tests can simulate
termination by discarding one instance and creating another. Keep production on
`UserDefaults.standard`; do not persist the message text or introduce another presentation path.

Under `#if DEBUG`, expose only the child lock-code cache count from `LockCodeManager`. The cache
test uses that mode-independent assertion seam to pin both persisted-key removal and in-memory
cache clearing without touching `AppModeManager`.

## Testing and delivery

Use TDD for pending-flag survival across store reconstruction, startup message restoration,
cleanup-before-persistence-before-publication ordering, dismissal clearing, and both lock-code
cache representations. Run focused tests, all tests, a standalone Debug build, recursive format
lint, project guards, version/sync/privacy checks, and independent exact-head review.

Work from main `312a773` on `fix/revocation-notice-persistence`. Set every target configuration to
the planner-reserved version 2.0.45 (64), publish a ready PR as the immediate follow-up to #445,
and leave merge ownership with the planner.
