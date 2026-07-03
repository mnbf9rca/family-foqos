> **SUPERSEDED (2026-07-02):** rev 1 of the A1 design, authored by a prior session and never
> committed. Preserved as part of the A1 acceptance corpus for #267 — see
> `2026-07-02-reset-sync-a1-acceptance-corpus.md`. Rev 1 was revised (before any adversarial
> round ran) because re-derivation found three holes: unprotected *location* reconciliation;
> the stateless per-pass A3 flag not surviving the re-push window (manual "Sync Now" or
> crash-relaunch mid-re-push could still wipe); undocumented reliance on CloudKit zone
> atomicity.

# Design: Reset-Sync Safety (SyncResetRequest lifecycle)

- **Bundle:** A1 (epic #263)
- **Issues:** #195 (critical) reset race wipes local profiles; #202 (high) reset consumed by first device / never GC'd
- **Date:** 2026-07-02
- **Files:** `Foqos/CloudKit/ProfileSyncManager.swift`, `Foqos/CloudKit/SyncCoordinator.swift`,
  `Foqos/CloudKit/SyncModels.swift`, `Foqos/CloudKit/SyncEventDelegate.swift`,
  `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift`

## Problem (re-verified against current `main`, 2026-07-02)

Two independent defects in the `SyncResetRequest` lifecycle. Both confirmed by re-tracing
the code, not just the handover.

### #195 — Reset race / partial-failure wipes all local profiles on other devices

1. **Ordering.** `resetSync` (`ProfileSyncManager.swift:823`) calls `deleteAllSyncedData()`
   (line 831) — which deletes `SyncedProfile` records first (record-type order line 859) —
   **before** saving the `SyncResetRequest` (line 839). Zone deletions fire the zone
   subscription (`setupSubscriptions`, line 210) on other devices.
2. **Reconciliation gap.** A device that syncs in that window runs `performFullSync`:
   `pullResetRequests` (line 345) sees no request yet, `pullProfiles` (line 348) sees an
   empty zone, and delivers `([], remoteProfileIds: [])` to
   `SyncCoordinator.handleSyncedProfiles`. The guard at `SyncCoordinator.swift:179`
   (`remoteProfileIds.isEmpty && !syncedProfiles.isEmpty`) only covers the decode-failure
   case; with **both** empty it falls through and deletes every local profile with
   `syncVersion > 0` (line 195) via `BlockedProfiles.deleteProfile`.
3. **Persistent partial-failure variant.** If `deleteAllSyncedData` throws mid-way
   (`modifyRecords` limitExceeded, line 873), `resetSync` aborts before the request is ever
   saved. The zone is left wiped with no reset marker — **any** later sync on **any** device
   deterministically wipes its local profiles. Not a race; a durable landmine.
4. **Intra-pass re-push race.** Even when the reset request *is* seen first,
   `handleSyncReset` (`SyncCoordinator.swift:552`) re-pushes in a detached `Task` while the
   **same** `performFullSync` continues synchronously into `pullProfiles`. The single query
   beats N sequential re-push round-trips, so reconciliation runs against a partial remote
   set and deletes the not-yet-re-pushed remainder. Re-pushed profiles keep `syncVersion > 0`,
   so the `syncVersion` guard does not protect them.

**Impact:** local profiles, app selections, session history destroyed on the innocent
device; profiles later recreated from the origin arrive `needsAppSelection = true`, so
blocking silently stops enforcing apps.

### #202 — Reset consumed by first reader; origin never GCs; no TTL

1. **Consume-on-first-read.** `pullResetRequests` deletes the record immediately after the
   **first** non-origin device processes it (line 402). In a 3+ device family the remaining
   devices never receive the reset.
2. **Origin never cleans up.** The origin skips its own request via `continue` (line 387)
   and never deletes it. On a single-device account the record lingers **forever**.
3. **No TTL.** `requestedAt` is written but never read. A device that enables sync months
   later processes the stale request and executes `handleSyncReset(clearAppSelections: true)`
   (`SyncCoordinator.swift:535`), clearing `selectedActivity` on every profile — blocking
   silently stops.

## Constraints & design forces

- **No CloudKit mock exists.** `ProfileSyncManager` calls `privateDatabase` (a real
  `CKDatabase`) directly; there is no injectable seam. Introducing a CK abstraction is a
  large, risky refactor and out of scope for a "minimal fix" bundle. Therefore: keep the CK
  plumbing as-is, and **extract every decision into pure, injectable-`now` helpers** that are
  unit-testable.
- **The destructive act is testable.** `SyncCoordinator.handleSyncedProfiles` takes plain
  arrays + an in-memory `ModelContext`, reachable through the `didReceiveSyncedProfiles`
  delegate method. This is the last line of defence for #195 and where its fix is proven.
- **CloudKit query indexes are eventually consistent.** A record saved before another can
  still be *read back* after it. We cannot rely on "saved the marker first ⇒ every reader
  sees the marker before the deletions." Defence must not depend on query ordering alone.
- **Safety asymmetry.** Wrongly deleting all local profiles + app selections (silent
  blocking failure) is catastrophic and hard to notice. Wrongly *keeping* a profile that was
  legitimately deleted elsewhere is a minor, recoverable staleness. Every ambiguous case must
  resolve toward "keep."
- **AGENTS.md:** feature branch, TDD, `Log.<level>(_,category:)`, no `print`, pin `now` in
  tests, swift-format, no behaviour change outside the defect scope.

## Approach

Two cooperating mechanisms — **reconciliation gating** (fixes #195, the destructive path)
and **request lifecycle** (fixes #202, delivery + cleanup) — plus an **ordering fix** that
turns a failed reset from a data-wipe into a no-op.

### Part A — Reconciliation gating (#195)

**A1. Order: marker before wipe, and never wipe the current marker.**
In `resetSync`, save the `SyncResetRequest` **first**, capture its `recordID`, then call
`deleteAllSyncedData(excluding: [currentRequestRecordID])`. Consequence: a reset that fails
at the network layer now leaves *all* CloudKit data intact (the wipe never started) instead
of leaving a wiped, marker-less zone. This alone neutralises the persistent partial-failure
landmine (#195.3).

**A2. Empty-pull is never authoritative for deletions.**
Widen the guard in `handleSyncedProfiles`: **skip deletion reconciliation whenever
`remoteProfileIds.isEmpty`**, regardless of how many profiles decoded. An empty remote
profile set is indistinguishable from a reset-in-flight / partial-wipe / index-lag
transient, and the safety asymmetry makes "skip" the only correct choice. (Closes #195.2, the
primary path.)

**A3. A pass that processed a reset does not reconcile deletions.**
`pullResetRequests` returns whether it processed a non-origin reset this pass;
`performFullSync` threads that boolean through `pullProfiles` into
`didReceiveSyncedProfiles(..., resetProcessedThisPass:)`. When true, `handleSyncedProfiles`
skips deletion reconciliation. This is **stateless across passes** (computed fresh each
pass — no flag can leak or get stuck), and it closes #195.4 (intra-pass re-push race) without
depending on re-push timing.

**A4. Await the re-push before the follow-up sync.**
`handleSyncReset` already chains `rePushLocalSyncedData` then `performFullSync` inside one
`Task`; keep that ordering (re-push completes before the follow-up full sync pulls), so the
follow-up pass reconciles against a fully-rebuilt remote. A3 already makes the *triggering*
pass safe; A4 makes the *follow-up* pass accurate.

Normal deletion propagation is preserved: a non-empty, reset-free pull that is missing one
profile still reconciles that profile away (regression-guarded by test).

### Part B — Request lifecycle (#202)

Replace consume-on-first-read with **per-device idempotent processing + TTL + cooperative
garbage collection**. No device roster or per-device ack list (brittle — would need to know
every device that exists).

**B1. Per-device processed watermark.**
Add `SharedData.lastProcessedResetAt: Date` (app-group, per device, default `.distantPast`).
A device processes a request only if `requestedAt > lastProcessedResetAt`; after processing,
it advances the watermark to that `requestedAt`. Idempotent (never reprocesses), O(1)
storage, monotonic (an older reset seen after a newer one is correctly skipped — the newer
one supersedes).

**B2. TTL.**
`SyncResetRequest.isExpired(now:ttl:)` using the existing `requestedAt`. Requests older than
`ttl` are ignored by all devices. `ttl = 7 days` (constant `SyncResetRequest.defaultTTL`):
long enough that all family devices realistically sync within it; short enough that stale
resets don't haunt a device months later. A device offline longer than the TTL still
full-syncs current data on return and merely keeps its app selections — the safe default.
(Closes #202.3, the fresh-device-processes-year-old-reset scenario.)

**B3. Cooperative GC.**
Any device that sees a request past its TTL deletes it (a past-TTL request is globally inert,
so deletion is always safe and self-healing even if the origin is gone). This closes #202.2
(origin/single-device lingering) without needing the origin to be online.

**B4. Do not delete within-TTL requests after processing.**
Deletion of a live request is what breaks 3+ device delivery. Within-TTL requests are left in
place; the per-device watermark (B1) prevents reprocessing. They are removed later by
cooperative TTL-GC (B3). (Closes #202.1.)

**B5. Pure classifier.**
`SyncResetRequest.classify(deviceId:watermark:now:ttl:) -> ResetAction` returning one of
`.skipOwnOrigin`, `.skipAlreadyProcessed`, `.expiredCollect` (skip **and** GC),
`.process`. `pullResetRequests` becomes a thin loop: classify → act. All the #202 logic lives
in this pure, `now`-injected function and is exhaustively unit-tested.

**B6. Watermark advance prevents an infinite reset loop.**
Because within-TTL requests are no longer deleted (B4), the watermark is the *only* thing
stopping re-processing. `pullResetRequests` must advance `lastProcessedResetAt` to the
request's `requestedAt` **synchronously, in the same loop iteration** that classifies it
`.process` — before `handleSyncReset` spawns its re-push + follow-up `performFullSync`. That
follow-up pass re-runs `pullResetRequests`, now sees `.skipAlreadyProcessed`, and does not
re-trigger the reset. Advancing the watermark inside the async re-push `Task` instead would
race the follow-up pass and can loop. This is the single most correctness-critical ordering in
Part B.

## Data flow (post-fix)

```
resetSync(origin):
  save SyncResetRequest  ──► deleteAllSyncedData(excluding: current request)
                             └► didReceiveSyncReset ──► rePush(local) ──► performFullSync

performFullSync(any device):
  resetProcessed = pullResetRequests()          # classify each: skip / process / expire-GC
  pullProfiles(resetProcessed:) ──► didReceiveSyncedProfiles(profiles, remoteIds, resetProcessedThisPass)
      handleSyncedProfiles:
        apply upserts (unchanged)
        reconcile deletions  ONLY IF  !remoteIds.isEmpty  &&  !resetProcessedThisPass
```

## Partial-failure interleaving analysis

Every interleaving considered; the design's response shown. "Converges" = all devices end
with the union of local data, no silent blocking loss.

### resetSync (origin)

| # | Interleaving | Outcome |
|---|---|---|
| 1 | Save request ✓, crash before wipe | Request present (within TTL); no data wiped anywhere. Receivers gated + re-push. Origin re-pushes its local data next sync. **Converges.** |
| 2 | Save ✓, wipe partial, crash | Request present. Receivers gated (A3) / empty-skip (A2). Origin re-pushes all local next full sync (`didRequestLocalDataPush`), restoring purged CK records. **Converges.** |
| 3 | Save request **throws** (network) | Wipe is *after* save, so nothing is wiped. UI shows error. **No data loss** — a failed reset is now a no-op (was: durable wipe). |
| 4 | Save ✓, wipe ✓, app killed before re-push runs | CK holds only the marker, zero profiles. Receivers pull empty → empty-skip (A2). Origin re-pushes local next sync. Origin's SwiftData never touched. **Converges.** |
| 5 | Remote notification fires during resetSync awaits | Concurrent `performFullSync` on origin pulls its own mid-wipe empty zone → empty-skip (A2). Origin's own request skipped (`originDeviceId`). **Safe.** |

### pullResetRequests (receiver)

| # | Interleaving | Outcome |
|---|---|---|
| 6 | Apply ✓, watermark ✓, GC delete of an expired other fails | Harmless; retried next pass. |
| 7 | Apply ✓, crash before watermark advance | Next pass reprocesses the **same** request. `handleSyncReset` is idempotent (re-clear already-cleared selections; re-push overwrites). Wasteful, safe. |
| 8 | Fresh device (watermark `.distantPast`) sees within-TTL reset | Processes once — correct delivery. Sees past-TTL reset → skip + GC (B2/B3). Closes #202.3. |
| 9 | Two receivers process same within-TTL request concurrently | Both apply (idempotent), advance own watermark. Neither deletes (within TTL) → no delete race. |
| 10 | `requestedAt` far in future (clock skew) | Treated within TTL, processed; watermark jumps forward → a legit reset in that window could be skipped. Rare; accepted; noted. |

### handleSyncedProfiles reconciliation

| # | Interleaving | Outcome |
|---|---|---|
| 11 | remoteIds empty, decoded empty (scenario 1) | Skip (A2). Closes #195 primary. |
| 12 | remoteIds empty, decoded non-empty (decode failures) | Skip (existing guard, retained). |
| 13 | remoteIds non-empty partial + resetProcessedThisPass | Skip (A3). Closes #195.4. |
| 14 | remoteIds non-empty partial + reset **not** seen this pass (CloudKit index lag) | **Residual:** reconciles → may delete not-yet-re-pushed profiles. Mitigated: origin re-push makes them reappear next pass and `createLocalProfile` recreates them (self-healing, was permanent). Narrow window; documented accepted risk. Fully closing it needs per-delete tombstones — out of scope (A3-wave conflict semantics). |
| 15 | Non-empty, complete, no reset, one profile deleted remotely | Reconciles + deletes locally — **normal propagation preserved** (regression test). |

## Intentional behaviour changes (documented)

- **Deleting the *last* remaining profile no longer propagates via reconciliation.** With the
  zone empty, other devices skip reconciliation (A2) and re-push their copy, effectively
  resurrecting the last profile. Deleting a *non-last* profile still propagates normally
  (remote non-empty). Accepted: resurrecting one profile is vastly safer than wiping all.
  Explicit deletes still delete the CK record via `deleteProfileFromSync`; only the
  reconciliation *inference* is gated.

## Test plan (TDD)

Pure / in-memory — no CloudKit:

1. **`SyncResetRequest.classify` / `isExpired`** (issue #202, the bulk): own-origin skip;
   already-processed skip (watermark); expired → `.expiredCollect`; fresh within-TTL →
   `.process`; boundary at exactly `ttl`; future `requestedAt`. All with a single injected
   `now`.
2. **`handleSyncedProfiles` gating** (issue #195) via `didReceiveSyncedProfiles`, seeded
   in-memory `ModelContext`, `MockSessionController`:
   - empty remote + empty decoded ⇒ local profiles (syncVersion>0) **retained**;
   - non-empty partial + `resetProcessedThisPass = true` ⇒ **retained**;
   - non-empty complete + no reset, one missing ⇒ that one **deleted** (regression guard);
   - `syncVersion == 0` local ⇒ never deleted (unchanged).
3. **`SharedData.lastProcessedResetAt`** round-trip + `.distantPast` default.

CloudKit-plumbing (`resetSync` ordering, `pullResetRequests` loop) verified by code
inspection; their *decisions* are covered by the pure classifier (1).

## Out of scope

- Per-delete tombstones for the general (non-reset) deletion path (interleaving #14 residual).
- Introducing a CloudKit mock / `CKDatabase` abstraction.
- Any change to session, location, or emergency-settings sync beyond what these two issues
  touch.
