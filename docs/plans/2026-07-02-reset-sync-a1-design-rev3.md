> **SUPERSEDED (2026-07-02):** rev 3 of the A1 design. Broken by adversarial round 2 (see
> `2026-07-02-reset-sync-a1-interleavings-round2.md`, 20 findings), most importantly:
> (a) the **vacuous-reconciliation proof** — a pass whose read-verification passes has a
> provably empty deletion set, so "verify, then resume deleting" never actually resumes
> propagation; (b) the hold is edge-triggered (cleared by a possibly stale-presence pull,
> not re-armed by a stale-absent marker query) while the danger is level-triggered;
> (c) concurrent passes leak one pass's hold-clear into another pass's stale reconciliation;
> (d) the `now + 1h` watermark cap re-introduces an **infinite reprocessing loop**
> (repeated family-wide selection clearing) for receivers with slow clocks; (e) the 14-day
> gcTTL gives only a 7-day skew margin, not the claimed 14. Preserved as part of the A1
> acceptance corpus for #267 — see `2026-07-02-reset-sync-a1-acceptance-corpus.md`.

# Design: Reset-Sync Safety (SyncResetRequest lifecycle)

- **Bundle:** A1 (epic #263)
- **Issues:** #195 (critical) reset race wipes local profiles; #202 (high) reset consumed by first device / never GC'd
- **Date:** 2026-07-02 (rev 3 — read-verified reconciliation holds; supersedes rev 2's
  push-ack-cleared gate, which adversarial verification broke in three independent ways)
- **Files:** `Foqos/CloudKit/ProfileSyncManager.swift`, `Foqos/CloudKit/SyncCoordinator.swift`,
  `Foqos/CloudKit/SyncModels.swift`,
  `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift`

## Problem

*(identical to rev 2's problem statement — #195.1–.5 and #202.1–.3.)*

## Constraints & design forces

As rev 2, with these sharpened:

- **CloudKit query indexes are eventually consistent, with no cross-record-type ordering.**
  No safety decision may rely on a write being query-visible; only positive query evidence
  counts. *(Rev 3's own failure: it treated positive evidence as trustworthy, but positive
  evidence can be stale-presence.)*
- **A push ack is not durability against a concurrent wipe** (deletes by recordID from a
  fetched snapshot land after the ack). This is what broke rev 2.
- **CloudKit custom zones are atomic per operation, and operations are capped at 400
  records** — `deleteAllSyncedData` must chunk.
- **Device clocks are not trustworthy** — prefer server-assigned `CKRecord.creationDate`;
  clock rules must fail toward "keep data / keep marker."

## Approach

One safety invariant, one delivery mechanism, one ordering fix.

> **Invariant (I): while any reset marker is visible (or a hold persists from one), a device
> may reconcile deletions only in a pass whose own pull proves the zone contains every
> record this device could re-create.** Positive evidence, read in the same pass, decides —
> never push acks, never timers alone, never classification state.

### Part A — Reconciliation holds (#195)

**A1. Order: marker before wipe; never wipe markers; chunked deletes.**
`resetSync`: (1) save the new `SyncResetRequest` (failure aborts with the zone intact);
(2) advance the origin's watermark; (3) set both reconciliation holds; (4)
`deleteAllSyncedData` — **excluding the `SyncResetRequest` type entirely** (fixes rev 2's
mutual-marker-annihilation) and chunked ≤400 recordIDs per op; (5) fire `didReceiveSyncReset`
as today.

**A2. Reconciliation holds, set on sight, cleared only by read-verification.**
Two persisted per-device dates: `profileReconciliationHoldSince` and
`locationReconciliationHoldSince`.

- **Set** (to local `now`, only if nil) by `pullResetRequests` whenever its query result
  contains **any** `SyncResetRequest` record — regardless of classification — and by
  `resetSync` before its wipe. Set before `didReceiveSyncReset` dispatch and before any
  watermark advance.
- **While a hold is set**, the corresponding handler skips deletion reconciliation — unless
  cleared in that same pass by read-verification. Upserts always apply. The hold is read
  fresh inside the reconciliation branch.
- **Read-verification (the only clearing rule):** if the pull's `remoteProfileIds` ⊇
  {local profiles with `syncVersion > 0` and `!isNewerSchemaVersion`}, clear the hold and
  reconcile normally **using that same pulled set**. Locations mirror with
  `remoteLocationIds` ⊇ {local locations with `syncVersion > 0`}. Each hold clears
  independently.
- **Backstop:** a hold older than 14 days is cleared **and that pass still skips
  reconciliation** (the end-of-pass push restores anything missing before the next pass
  reconciles).

*(Round 2 refuted the clearing rule from both directions: stale-presence pulls clear the
hold while the zone is genuinely wiped; stale-absence marker queries then fail to re-arm it;
a concurrent pass's clear leaks into another pass's stale pulled set; and — decisively — a
passing superset check has a provably empty deletion set, so the machinery could only ever
authorize vacuous reconciliation.)*

**A3. Empty-pull is never authoritative for deletions** (profiles and locations).

**A4. Newer-schema profiles are exempt from deletion reconciliation.** They are read-only
holdings this device can never re-push; treat like `syncVersion == 0`.

### Part B — Request lifecycle (#202)

**B1. Per-device processed watermark** `lastProcessedResetAt` (default `.distantPast`);
advance **capped at `now + 1 hour`** to bound skew poisoning. *(Round 2: the cap breaks
idempotency for receivers >1h slow — infinite reprocessing loop with repeated
selection-clearing; idempotency must be by request identity, not time.)*

**B2. Effective date & processing TTL.** `effectiveDate = CKRecord.creationDate ??
requestedAt`; requests older than `processTTL = 7 days` are not processed.

**B3. Cooperative GC with a skew margin.** Any device deletes markers older than
`gcTTL = 14 days` (= 2 × processTTL). *(Round 2: margin arithmetic wrong — a receiver
>7 days fast, not >14, can GC a live marker: it GCs at real age ≥ 14 − F.)*

**B4. Process the newest, once.** Pure classifier
`classify(effectiveDate:originIsSelf:watermark:now:)` →
`.process | .skipOwnOrigin | .skipAlreadyProcessed | .skipExpired | .expiredCollect`;
process only the newest `.process` candidate per pass; within-TTL markers never deleted
after processing.

**B5. Ordering inside `.process`**: holds already set (on sight) → advance watermark
synchronously → dispatch `didReceiveSyncReset`. A kill anywhere leaves holds set.

### Interplay

- A3 protects devices that cannot see the marker **when the zone is fully wiped**.
- A2 protects every device that *can* see the marker (or ever saw one), for exactly as long
  as the zone lacks data that device could restore — and not a pass longer. *(Round 2:
  false — protection can end on a stale-presence read while the zone still lacks the data,
  and does not resume on a stale-absent one.)*
- A4 protects data no push path can restore.
- B1–B5 make delivery reach every syncing device within the processing TTL, exactly once
  per device, with cleanup that needs no particular device to survive.

## Data flow (post-fix)

```
resetSync(origin):
  save SyncResetRequest ─► advance watermark ─► set both holds
    ─► chunked wipe of data types (never SyncResetRequest, ≤400/op)
    ─► didReceiveSyncReset ─► clear own selections (if flag) ─► rePush(local)
                                 ─► performFullSync            [always, success or not]

performFullSync(any device):
  pullResetRequests:
      any marker fetched        ⇒ set holds (if nil)
      classify all; age>14d     ⇒ GC-delete
      newest .process candidate ⇒ advance watermark ─► didReceiveSyncReset (as above)
  pullProfiles ─► handleSyncedProfiles:
      apply upserts (always)
      deletion reconciliation IFF remoteIds nonempty
        AND (hold nil  OR  remoteIds ⊇ local restorable ids → clear hold, reconcile)
        AND skipping isNewerSchemaVersion + syncVersion==0 profiles
  pullLocations ─► handleSyncedLocations: same shape, location hold
  didRequestLocalDataPush ─► pushLocalData   [pushes restorable local data; never clears holds]
```

## Partial-failure interleaving analysis (as claimed — rows 5, 9, 10, 13, 14, 15, 16, 19, 20 were refuted or shown mis-stated in round 2)

### resetSync (origin)

| # | Interleaving | Claimed outcome |
|---|---|---|
| 1 | Marker save **throws** | No data loss — failed reset is a no-op. |
| 2 | Marker ✓, crash before watermark/holds/wipe | Converges (receivers process idempotently; origin re-verifies). |
| 3 | Marker ✓, watermark ✓, holds ✓, wipe partial, crash | Converges (holds + superset proof fails on partial zone). |
| 4 | Wipe ✓, killed before re-push | Converges (A3 + holds; origin's next pass pushes; verification clears). |
| 5 | Concurrent pass on origin mid-reset | Safe. **(Refuted: a manual pass can verify-clear the origin's holds against its pre-wipe pull before the wipe lands.)** |
| 6 | Two devices reset near-simultaneously | Both markers survive (wipes never touch markers); newest processed once; converges. |
| 7 | >400 records of one type | Chunked deletes; mid-chunk failure = row 3. |

### pullResetRequests (receiver)

| # | Interleaving | Claimed outcome |
|---|---|---|
| 8 | Sight ✓, holds ✓, killed before watermark advance | Reprocess idempotently; safe by holds-before-watermark ordering. |
| 9 | Watermark ✓, killed before/during apply or mid-re-push | Converges via persisted holds + re-sight. **(Refuted: re-sight depends on a query that can be stale-absent after a stale-presence verification-clear.)** |
| 10 | Any pass while a re-push is in flight | Superset proof fails exactly while anything is missing. **(Refuted for the cleared-hold case and the concurrent-pass clear leak.)** |
| 11 | Fresh device | Delivery within 7d; 7–14d grace `.skipExpired`; >14d collected. |
| 12 | Two receivers process the same marker concurrently | Both apply; no delete race. |
| 13 | Origin clock skew (future dates) | Bounded by `creationDate` preference + 1h cap. **(Refuted: cap breaks idempotency for slow receivers — infinite loop.)** |
| 14 | Receiver clock 7–14 days fast | `.skipExpired`, not GC'd, sighted ⇒ holds. **(Refuted: GCs at real age ≥ 14 − F, so >7d-fast destroys live markers.)** |
| 15 | Receiver clock >14 days fast | Residual: GCs a live marker. **(Precondition wrong — >7d suffices.)** |
| 16 | Re-push failing persistently | Deferred propagation bounded by 14-day backstop. **(Refuted as stated: loss also occurs when the finally-successful push is not yet query-visible at the first post-backstop reconcile; and gcTTL == backstop removes marker re-sight protection at exactly that moment.)** |

### handleSyncedProfiles / handleSyncedLocations

| # | Interleaving | Claimed outcome |
|---|---|---|
| 17 | remoteIds empty | Skip (A3). |
| 18 | remoteIds non-empty, hold set, superset fails | Skip. |
| 19 | remoteIds non-empty, hold set, superset holds | Clear hold; reconcile same pass. **(Refuted as vacuous: the deletion set in such a pass is provably empty; "same-pass resume" resumes nothing.)** |
| 20 | Partial zone, marker never sighted, no hold | Residual (index lag). **(Precondition wrong: a device that DID sight the marker loses data the same way after a stale-presence clear + stale-absent re-sight.)** |
| 21 | Non-empty, no marker, no hold, one deleted remotely | Normal propagation preserved. |
| 22 | `isNewerSchemaVersion` absent from remote | Never deleted (A4). |

## Test plan / out of scope

As rev 2 amended: classifier boundary tests; newest-only; hold lifecycle (set-if-nil,
independent clears, fresh read); `handleSyncedLocations` mirror; SharedData round-trips.
*(Round 2 additionally showed: test 4.3 "same-pass deletion after verification-clear" is
unsatisfiable — a hint the mechanism was vacuous; location `syncVersion` is pull-confirmed,
not push-optimistic, so "restorable" differs between types; no locking discipline was
specified for the new compound SharedData writes; 7d/14d boundary operators unpinned.)*
