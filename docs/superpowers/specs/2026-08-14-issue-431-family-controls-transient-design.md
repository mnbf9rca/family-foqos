# Issue #431 Family Controls Transient-Failure Design

## Goal

Keep an existing Child enrolled when Family Controls cannot answer temporarily, especially for
`FamilyControlsError.authorizationConflict` (raw code 4), and recover on the next foreground
verification without mode oscillation or a false invitation prompt. Only independently confirmed
CloudKit revocation may clear family state or select Individual mode.

## Root cause

`AuthorizationVerifier.verifyChildAuthorization()` currently catches every error as `NSError` and
maps the entire `FamilyControls` domain to `.notChildDevice`. The #437 disposition layer then maps
`.notChildDevice` to `.confirmedLoss`, so code 4 reaches `handleAuthorizationLoss()`, clears local
shared state, and selects Individual even though `verifySelfFamilyMemberRecord()` just confirmed
the Child's CloudKit membership. The same over-broad result can drive the background refresh loss
path and the Child dashboard's destructive authorization-lost alert.

## Considered approaches

### A. Typed Family Controls mapping with CloudKit-only revocation (approved)

Decode `FamilyControlsError` and classify every SDK case explicitly. Preserve
`invalidAccountType` as a pre-share account-role result, classify code 4 and every other failure as
recoverable for an enrolled Child, and make the destructive cleanup API callable only for a
confirmed CloudKit revocation.

This closes the failure class, gives code 4 accurate retry guidance, and reuses the authoritative
CloudKit revocation machinery from #433 without another network query.

### B. Special-case raw code 4 (rejected)

This is smaller, but every other transient Family Controls error would retain the same destructive
misclassification.

### C. Re-query CloudKit after every Family Controls error (rejected)

This duplicates #433's confirmation path, couples two independent services, and adds latency when
the foreground flow has already verified CloudKit first.

## Two-layer classification

The typed mapping layer preserves information needed by pre-share role detection:

| `FamilyControlsError` | `VerificationResult` | Meaning |
| --- | --- | --- |
| `invalidAccountType` | `notChildDevice` | Definitive account-type result used only before share acceptance |
| `authorizationConflict` | `authorizationConflict` | Another authorization flow is active; could not check, retry |
| `networkError` | `networkError` | Network prevented the check; retry |
| `authorizationCanceled` | `authorizationCanceled` | The check was canceled; retry |
| `unauthorized` (availability-gated) | `notAuthorized` | Authorization is not currently granted; do not infer CloudKit revocation |
| `restricted`, `unavailable`, `invalidArgument`, `authenticationMethodUnavailable` | `unknownError` | The check could not establish membership; retry or use SDK guidance |
| future SDK cases via `@unknown default` | `unknownError` | Fail closed and non-destructively |

Unknown non-Family-Controls errors also remain `unknownError`; URL errors remain `networkError`.
The switch is over typed `FamilyControlsError`, never a domain-wide string comparison.

At the enrolled-Child disposition layer, `.authorized` is authorized and every other result in
the table is indeterminate. No Family Controls result can become confirmed family loss. The same
domain's `invalidAccountType` and `authorizationConflict` raw codes must produce distinct typed
results, while both remain non-destructive for an existing Child.

Pre-share role detection deliberately trusts only `invalidAccountType` to propose Parent role.
The existing human confirmation dialog remains between that proposal and enrollment, mitigating
the risk of an erroneous role inference. Every other failure, including `notAuthorized`, shows
recoverable guidance and does not infer Parent.

## Destructive transition boundary

Rename/narrow the centralized destructive operation to a confirmed-CloudKit-revocation entry
point. `CloudKitManager.confirmedRevocationTrigger` remains the sole producer of that authority.
Family Controls verification, shared-lock-code refresh, and Child dashboard code must not call the
destructive operation.

`verifyIfNeeded()` preserves Child mode and shared state for every indeterminate Family Controls
result. Foreground verification can retry later; a delayed `.authorized` result refreshes the
persisted child authorization without a leave/rejoin cycle. `LockCodeManager` returns a failed
refresh with truthful retry text when bootstrap verification is indeterminate, while retaining the
cached PIN and mode.

## Recoverable user guidance

Code 4 copy states that Screen Time authorization could not be checked because another
authorization flow is active, and asks the user to close that flow and retry. It never states that
the Child was removed, needs a new invitation, or is definitively unauthorized.

Repurpose the Child dashboard's authorization alert into a recoverable verification alert. It
shows the result's retry guidance and offers retry/cancel actions only; remove the destructive
"Switch to Individual Mode" action. CloudKit-confirmed revocation already changes the mode and
dismisses Child UI, so the old Family-Controls-driven destructive alert would otherwise be dead and
incorrect.

Foreground app verification must not route recoverable Family Controls copy through the
"Unable to Join Family" share-acceptance alert. The normal dashboard surface provides the guidance,
and privacy-safe logs record that the foreground check was indeterminate.

## Testing

Use TDD with these failing fixtures before production edits:

- same-domain mutated twins: raw `invalidAccountType` maps to `notChildDevice`, while raw
  `authorizationConflict` (4) maps to `authorizationConflict`;
- every current Family Controls error case maps explicitly, with future/unknown cases falling back
  non-destructively;
- every non-authorized Family Controls result is indeterminate for an enrolled Child;
- `authorizationConflict` guidance says the check could not complete and to retry, without revoked,
  removed, invitation, or leave language;
- sequence: start Child, receive conflict, remain Child with shared state intact, then receive
  delayed authorized on foreground retry and remain Child without invitation state;
- pre-share role detection chooses Parent only for `notChildDevice`, never for `notAuthorized`,
  conflict, canceled, network, or unknown outcomes;
- shared-refresh bootstrap treats conflict as failed but non-destructive and keeps cached PIN data;
  and
- confirmed CloudKit revocation still clears the child PIN cache, shared state, and selects
  Individual through the narrowed destructive API.

Run focused authorization/revocation/refresh tests and then the complete simulator-gated test
suite, standalone Debug build, changed-file `swift-format lint`, `git diff --check`, project guards,
and independent exact-head review.

## Delivery

Work in `.worktrees/build1-431` on `fix/431-family-controls-transients`, based on current main
`2f707c1` at version 2.0.37 (56). Set every target configuration to reserved version 2.0.38 (57).
Use only new signed commits, publish a ready-for-review PR closing #431, and leave merge ownership
with the planner.
