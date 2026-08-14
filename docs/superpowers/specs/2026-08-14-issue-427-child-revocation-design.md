# Issue #427 Child Revocation Recovery Design

## Goal

When CloudKit authoritatively reports that a Child-mode device no longer has the family shared
zone, transition the device to Individual mode and erase the obsolete child PIN cache. Preserve
the existing fail-closed PIN cache for every offline, network, or otherwise indeterminate lookup.

## Root cause

`CloudKitNetworkService.findSharedZoneByName()` returns `nil` for two materially different
outcomes:

- `sharedDatabase.allRecordZones()` succeeds and contains no `FamilyPolicies` zone. For a
  persistently Child-mode device, this is confirmed share revocation.
- `allRecordZones()` throws because CloudKit cannot answer. This is an indeterminate transient
  failure.

`verifySelfFamilyMember` consequently returns the same disconnected result for both outcomes,
and `CloudKitManager` has no signal that permits automatic unenrolment. The centralized
`AuthorizationVerifier.handleAuthorizationLoss()` cleanup also clears published CloudKit state,
authorization state, and app mode, but it leaves `LockCodeManager`'s in-memory and persisted child
PIN cache intact.

## Considered approaches

### A. Tri-state verification lookup and centralized cleanup (approved)

Add a verification-local shared-zone lookup with `present`, `confirmedAbsent`, and
`indeterminate` outcomes. Carry confirmed absence through `VerificationResult`; only a Child-mode
caller may turn that signal into authorization-loss cleanup. Extend the existing centralized
cleanup to erase the child PIN cache.

This directly models the CloudKit evidence, recovers immediately after revocation, and leaves the
#197 offline fail-closed path unchanged.

### B. Treat a missing zone as a connected empty lock-code fetch (rejected)

This would clear the PIN when a zone lookup fails for network or service reasons, reopening the
#197 airplane-mode bypass.

### C. Require repeated absence or a time threshold (rejected)

This adds persistent state and delays recovery even though a successful zone-list response is
already authoritative. It does not make transient failures safer than the tri-state result.

## Design

Keep the new lookup in `CloudKitNetworkService+Verification.swift`; do not change the shared
optional helper in `CloudKitNetworkService.swift`. This limits #427 to verification and avoids
broadly changing unrelated shared-zone consumers.

The verification extension will classify a zone-list attempt as:

- `present(zoneID)` when a zone whose name is exactly `FamilyPolicies` is returned;
- `confirmedAbsent` when the request succeeds but no exact-name match exists; or
- `indeterminate` when the request throws.

The classifier will be independently testable from a list of zone IDs plus an explicit lookup
success/failure signal. The positive fixture will include unrelated zones and a mutated
`FamilyPolicies` rename variant so an incidental non-empty list cannot make the test pass. Only an
exact zone-name match is connected.

To honor the ownership boundary without editing `CloudKitNetworkService.swift`, the verification
extension will resolve the tri-state result against `localMode` before constructing the existing
`VerificationResult`. Confirmed absence in Child mode will use the existing `enforcedMode` field
with `.individual`; every other absent or indeterminate result will keep `enforcedMode` nil.
Existing connected verification behavior remains unchanged.
`CloudKitManager.verifySelfFamilyMemberRecord()` will interpret the result as follows:

- connected: update connection state and apply any CloudKit-enforced role as today;
- disconnected with `.individual` enforced while the current local mode is Child: invoke
  centralized authorization-loss cleanup;
- confirmed absent in Parent or Individual mode: report disconnected without changing mode; and
- indeterminate in every mode: preserve local mode and shared authority.

The `CloudKitManager` branch that interprets disconnected plus enforced `.individual` will carry
an inline comment documenting the field's dual meaning and the invariant that only
`CloudKitNetworkService+Verification.swift` may produce this revocation signal.

The Child-only gate is mandatory. A parent owns its policy zone in the private database, so an
empty shared database is not evidence that Parent mode should be removed.

`LockCodeManager` will gain one focused cleanup operation that clears both `cachedLockCodes` and
the persisted `family_foqos_child_lock_codes` value. A distinct confirmed-CloudKit-revocation
cleanup entry point in `AuthorizationVerifier` will call that operation and then compose with the
existing `handleAuthorizationLoss()` cleanup before selecting Individual mode. Existing Family
Controls-driven callers continue to call `handleAuthorizationLoss()` and must not erase either PIN
cache. The cache operation performs no network I/O and does not clear parent/individual lock-code
state.

This separation is also a compatibility boundary for issue #431. Family Controls error code 4 can
currently reach `handleAuthorizationLoss()` after a transient authorization failure. Until #431
corrects that classification, the ordinary authorization-loss path must preserve the fail-closed
PIN cache. Only a successful CloudKit zone-list lookup proving the shared policy zone absent may
call the confirmed-revocation entry point.

No lock-code fetch semantics change. In particular, `LockCodeManager.resolveLockCodes` continues
to preserve the persisted cache whenever `isConnected` is false. Only the separate authoritative
revocation signal may erase it.

## Data flow

1. On foreground activation, the app calls `verifySelfFamilyMemberRecord()` as it does today.
2. Verification lists shared zones and produces one tri-state lookup result, then resolves it
   against the supplied local mode without changing the core result type.
3. A present zone continues through FamilyMember verification.
4. A thrown lookup produces an indeterminate result; no mode or PIN cache changes occur.
5. A successful lookup without the exact policy zone produces confirmed absence.
6. If and only if local mode is Child, the confirmed-revocation cleanup clears the in-memory child
   PIN cache and its persisted copy, composes with the existing cleanup of published shared and
   authorization state, then selects Individual mode.
7. Family Controls-driven authorization loss continues through the existing cleanup path without
   erasing either child PIN cache.

## Error handling and privacy

CloudKit lookup errors remain privacy-safe logs and map to `indeterminate`. No error text, record
identifier, lock code, or personal identifier is persisted or logged. Cleanup is synchronous local
state mutation apart from the existing async wrapper, so a confirmed revocation does not depend on
another network request.

## Testing

Use TDD and first demonstrate failures for:

- a successful empty zone list classifying as confirmed absence;
- a thrown zone lookup classifying as indeterminate;
- an exact `FamilyPolicies` match classifying as present even alongside unrelated zones;
- a non-empty fixture containing a rename/mutation variant such as `FamilyPolicies-Renamed`
  classifying as confirmed absence;
- only Child mode turning confirmed absence into authorization-loss handling;
- Parent and Individual modes preserving their modes for the same shared-database absence;
- child PIN cleanup removing both the in-memory verification cache and persisted value;
- a Family Controls-driven authorization loss preserving both PIN caches while the confirmed
  CloudKit-revocation path erases them; and
- the existing offline `resolveLockCodes` test continuing to preserve the cached PIN.

Run focused tests through
`scripts/xcode-stream.sh --agent build2 --session implement_beta_fixes`, then the full required
test/build/format/guard suite. Do not use a device-name destination.

## Delivery and ownership

Work only in `.worktrees/build2-427` on `fix/427-child-revocation`. The planner granted this stream
temporary ownership of `LockCodeManager.swift` and `CloudKitNetworkService+Verification.swift`;
build1 will defer #428 until #427 merges. Do not edit `CloudKitNetworkService.swift` without a new
planner gate.

If `main` remains at `2.0.31 (50)`, set every configuration of `MARKETING_VERSION` to `2.0.32` and
every configuration of `CURRENT_PROJECT_VERSION` to `51`. If `main` advances before publication,
recompute both values so they remain strictly above main. Deliver one signed commit series and one
ready-for-review PR for #427; the planner merges after independent AMQ review.
