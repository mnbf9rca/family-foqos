# Issue #442 Establishment Conflict Reconciliation Design

## Goal

Stop a fixed-name `SyncEstablishment` save conflict from recurring on every launch after a device
has already adopted the current establishment generation. A conflict without a live reset intent
must either adopt a newer generation or reconcile CloudKit metadata and finish the pending seed.

## Root cause

`SyncEngineController` routes every establishment save conflict only through `ResetController`.
That controller deliberately ignores the result unless a reset is currently in `.wiping`, so a
post-adoption conflict stores no server system fields and never resolves the pending seed intent.
The next launch purges and seeds again, reproducing the same `serverRecordChanged` failure.

`RecordProvider.establishmentRecord()` also creates a fresh record instead of materializing cached
system fields, so a legitimate retry cannot carry the server change tag.

## Design

Keep reset ownership unchanged, but add controller-owned establishment reconciliation for normal
seeding:

- A higher server generation is authoritative and enters the existing fetched-establishment
  adoption path.
- An equal server generation is the same establishment. Cache its authoritative system fields and
  resolve the establishment seed without another save.
- A lower server generation loses to the local generation. Cache its system fields, re-enqueue the
  establishment with the server change tag, and keep the seed pending until that retry succeeds.
- A successful establishment save outside reset caches system fields and resolves the seed.
- Malformed server records remain pending and are not treated as success.

For a live wiping reset, call the existing reset result handler first. Its higher-generation winner
still enters adoption; equal/lower results retain the reset controller's existing intent cleanup,
then use the same metadata reconciliation rules. Normal seeding must not manufacture reset intent.

`RecordProvider` will materialize the establishment record from cached system fields when present,
then set the current generation and established date. This is narrowly scoped to the fixed-name
record rather than adding it to generic entity conflict behavior.

## Testing

Use only synthetic CloudKit records:

- equal-generation conflict after adoption caches server fields, resolves the seed, and does not
  enqueue establishment again after relaunch;
- lower-generation conflict caches fields and re-enqueues, with a later successful save resolving
  the seed;
- higher-generation conflict without reset routes to adoption exactly once;
- the provider materializes cached establishment system fields; and
- existing live-reset establishment tests remain green.

Run focused controller/provider/reset tests, the full simulator-gated suite, a standalone Debug
build, recursive format lint, project version guards, `git diff --check`, and independent exact-head
review.

## Delivery

Work in `.worktrees/build2-442` on `fix/442-establishment-conflict`, based on main `3410b5d`.
Publish all 12 configurations as version 2.0.43 (62), use new signed commits, open a ready-for-review
PR closing #442, and leave merge ownership with the planner.
