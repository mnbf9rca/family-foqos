> **SUPERSEDED (2026-07-02):** final A1 design (rev 4). Implementation was stopped by maintainer decision in favour of #267 (change-token sync engine). Preserved as part of the A1 acceptance corpus — see `2026-07-02-reset-sync-a1-acceptance-corpus.md`. Round-3 verification found further breaks in THIS design too (see `...-interleavings-round3.md`): born-expired suppression for late sighters; undecodable-marker permanent suppression; forward-clock-roll gate bypass.

# Design: Reset-Sync Safety (SyncResetRequest lifecycle)

- **Bundle:** A1 (epic #263)
- **Issues:** #195 (critical) reset race wipes local profiles; #202 (high) reset consumed by first device / never GC'd
- **Date:** 2026-07-02 (rev 4 — time-boxed deletion-reconciliation suppression + identity-based
  processing. Supersedes rev 3's read-verified holds, which adversarial verification proved
  vacuous-when-passing and racy-when-clearing, and rev 2's push-ack-cleared gate.)
- **Files:** `Foqos/CloudKit/ProfileSyncManager.swift`, `Foqos/CloudKit/SyncCoordinator.swift`,
  `Foqos/CloudKit/SyncModels.swift`,
  `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift`

## Problem (re-verified against current `main`, 2026-07-02, post-PR #264)

Two independent defects in the `SyncResetRequest` lifecycle. Both confirmed by re-tracing
the code, not just the handover.

### #195 — Reset race / partial-failure wipes all local profiles on other devices

1. **Ordering.** `resetSync` (`ProfileSyncManager.swift:823`) calls `deleteAllSyncedData()`
   (line 831) **before** saving the `SyncResetRequest` (line 839). Zone deletions fire the
   zone subscription (line 210) on other devices while no marker exists.
2. **Reconciliation gap.** A device syncing in that window sees no reset request and an
   empty zone; the guard at `SyncCoordinator.swift:179` only covers the decode-failure case
   (`remoteProfileIds.isEmpty && !syncedProfiles.isEmpty`), so a legitimately empty pull
   falls through and deletes every local profile with `syncVersion > 0` (line 195).
3. **Persistent partial-failure variant.** If `deleteAllSyncedData` throws mid-way,
   `resetSync` aborts before the request is ever saved: a wiped, marker-less zone. Any later
   sync on any device deterministically wipes its local profiles. A durable landmine, not a
   race.
4. **Intra-pass re-push race.** Even when the marker *is* seen, `handleSyncReset`
   (`SyncCoordinator.swift:552`) re-pushes in a detached `Task` while the same
   `performFullSync` continues into `pullProfiles`; reconciliation runs against a partial
   remote set and deletes the not-yet-re-pushed remainder.
5. **Same defect for locations.** `handleSyncedLocations` (`SyncCoordinator.swift:479-499`)
   runs identical delete-on-absence reconciliation, and the wipe removes `SyncedLocation`
   records too. (Sessions and emergency settings have no absence-based deletion.)

**Impact:** local profiles, app selections, session history, saved locations destroyed on
the innocent device; recreated profiles arrive `needsAppSelection = true`, so blocking
silently stops enforcing.

### #202 — Reset consumed by first reader; origin never GCs; no TTL

1. **Consume-on-first-read** (`ProfileSyncManager.swift:402`): in a 3+ device family, only
   the first non-origin device ever receives the reset.
2. **Origin never cleans up** (skip via `continue`, line 387): on a single-device account
   the record lingers forever.
3. **No TTL:** `requestedAt` is never read. A device enabling sync months later processes
   the stale request and clears `selectedActivity` on every profile
   (`SyncCoordinator.swift:535`) — blocking silently stops.

## Constraints & design forces

- **No CloudKit mock exists**; keep the CK plumbing as-is and extract every decision into
  pure, injectable-`now` helpers that are unit-testable.
- **CKQuery results may lag ANY write arbitrarily, in both directions** — stale absence of
  existing records and stale presence of deleted ones. **No safety decision may rely on any
  single query observation being fresh**, including this device's own acked writes.
  (General index-lag reconciliation risk is #219; this design must not depend on freshness,
  and must not pretend to more protection than that allows.)
- **A push ack proves nothing about the zone's later contents** (a concurrent wipe deletes
  by recordID from its own snapshot). Broke rev 2.
- **A "verified" pull proves nothing about the next pull**, and a passing superset check
  has a provably empty deletion set — so "verify, then resume deleting" is either vacuous
  or unsafe. Broke rev 3. The consequence is structural, not incidental: **while a reset
  may be in flight, absence-based deletion inference is meaningless and must simply be
  suspended for a time window.** No client-observable evidence ends the window early.
- **CloudKit custom zones are atomic per operation; 400-record cap per op** — bulk deletes
  must be chunked or a large type wedges the reset forever.
- **`pushLocalData` pushes local profiles and locations at the end of every full sync pass**
  (via `didRequestLocalDataPush`), except never-pushable `isNewerSchemaVersion` profiles
  (filtered at `SyncCoordinator.swift:64`, `:567`). Post-failure convergence rides on this.
- **Device clocks are untrustworthy** (users set them wrong; a screen-time app must assume
  children roll clocks back). Server-assigned `CKRecord.creationDate` is preferred where
  available; every clock-dependent rule must fail toward "keep data / keep marker", and no
  date comparison may create an unbounded loop.
- **Concurrent passes exist.** `performFullSync` has no reentrancy guard; manual "Sync Now",
  remote notifications, setup, and the reset follow-up can overlap at await points. Any new
  state must be safe when read/written by interleaved passes (monotonic, no check-then-act
  clears).
- **Safety asymmetry.** Wrongly deleting all local profiles (silent blocking failure) is
  catastrophic; wrongly keeping or resurrecting one is minor and recoverable. Ambiguity
  resolves toward "keep".
- **AGENTS.md:** feature branch, TDD, `Log`, pinned `now` in tests, swift-format, no
  behaviour change outside the defect scope.

## Approach

Three mechanisms, each with one job:

- **Suppression window (A)** — fixes #195's destructive path: absence-based deletion
  reconciliation is suspended, per device, for a bounded time window around any observed
  reset. Monotonic persisted state; nothing ever clears it early; it just expires.
- **Marker lifecycle (B)** — fixes #202: markers persist, every device processes each reset
  exactly once (by request **identity**, not by time), expiry is TTL'd, GC is cooperative
  with an honest skew margin.
- **Ordering & plumbing fixes (C)** — marker-before-wipe, never wipe markers, chunked
  deletes, exempt never-pushable profiles from deletion inference.

### Part A — Time-boxed suppression of deletion reconciliation (#195)

**A1. One persisted date:** `SharedData.syncDeletionSuppressedUntil: Date?` (default nil).
Updated **only** by monotonic max (never cleared, never decreased; expiry is just the clock
passing it):

```
extendSuppression(basis) := suppressedUntil = max(suppressedUntil ?? .distantPast,
                                                  min(basis, now) + suppressionWindow)
```

`suppressionWindow = 8 days` (`processTTL + 1 day` of slack: a device may legitimately
process a 7-day-old marker and start re-pushing; others must stay suppressed while that
convergence completes). The `min(basis, now)` clamp means a future-dated basis can never
suppress for more than `suppressionWindow` from now.

**Extended (basis = marker's effective date, or `now` when unknown) when:**
- `resetSync` runs on the origin — synchronously **before** the wipe starts;
- `pullResetRequests`' fetch returns **any** `SyncResetRequest` recordID — including
  per-record `.failure` results and records that fail to decode (basis `now` for those).
  Sight is judged on raw recordIDs *before* decoding or classification, mirroring how
  `pullProfiles` builds `allRemoteProfileIds`; a corrupt or future-schema marker still
  protects.

**A2. The reconciliation rule** (in `handleSyncedProfiles` *and* `handleSyncedLocations`):
deletion reconciliation runs **iff**
1. the remote ID set is non-empty (empty pulls are never authoritative — subsumes the
   existing decode-failure guard; closes #195.2), **and**
2. `now ≥ syncDeletionSuppressedUntil` (read fresh from `SharedData` inside the
   reconciliation branch; `nil` passes), **and**
3. per record: `syncVersion > 0` (unchanged) and, for profiles, `!isNewerSchemaVersion`
   (**A3**).

Upserts always apply regardless — merging is always safe. There is no per-pass flag, no
clearing write, no verification read: interleaved passes cannot race a monotonic date.

**A3. Newer-schema profiles are exempt from deletion inference.** They are read-only
holdings this device can never re-push; their authoritative copy may be offline for days.
Without this, any suppression scheme is unsound for them (nothing this device does can
restore their zone record). Symmetric with the existing push-side filter.

**A4. Why time, not evidence.** Two adversarial-verification rounds showed every
evidence-based early exit is unsound or empty: push acks race the wipe (rev 2); a passing
superset check *cannot* delete anything the device holds, so it never actually resumes
propagation, while its clearing write races concurrent passes and stale reads in both
directions (rev 3). A monotonic time window is the strongest honest guarantee available on
top of absence-inference. The consequences are stated plainly under *Intentional behaviour
changes*.

### Part B — Marker lifecycle (#202)

**B1. Identity-based idempotency.** `SharedData.processedResetRequestIds: [UUID: Date]`
(requestId → processed-at, pruned when `processed-at` older than `gcTTL`). A request whose
`requestId` is in the map is never processed again — no date arithmetic, no clock
dependence, no reprocessing loop regardless of skew. (Replaces rev 3's date watermark,
whose skew cap created an infinite clear-selections loop for slow-clocked receivers.)

**B2. Effective date & processing TTL.** `effectiveDate = CKRecord.creationDate ??
requestedAt` (server-assigned when available). `age = now − min(effectiveDate, now)`
(future dates clamp to age 0 — fail toward "fresh"). A request is processable **iff
`age ≤ processTTL` (7 days)**; boundary inclusive on the process side. Older requests are
never processed (closes #202.3 — the year-later stale-reset wipe).

**B3. Cooperative GC with an honest margin.** Any device deletes markers with
**`age > gcTTL` (21 days)**. Margin against a fast receiver clock is
`gcTTL − processTTL = 14 days`: a receiver must be *more than 14 days fast* before it can
GC a marker inside another device's processing window. GC is the **only** deletion path
for markers; GC failures are logged and retried next pass, and never affect suppression or
processing state. (Closes #202.2 without needing the origin alive.)

**B4. Classification (pure).**
`SyncResetRequest.classify(effectiveDate:isOwnOrigin:isProcessed:now:)` →
`.expiredCollect` (age > 21d) | `.skipExpired` (7d < age ≤ 21d) | `.skipOwnOrigin` |
`.skipAlreadyProcessed` | `.process`, checked in that order. Exhaustively unit-tested with
pinned `now`, including both boundaries exactly (7d ⇒ `.process`-eligible; 21d ⇒
`.skipExpired`; 21d+1s ⇒ `.expiredCollect`) and future dates (⇒ `.process`-eligible when
unprocessed).

**B5. Process the newest, once; retire the rest.** Per pass: among `.process` candidates,
dispatch **only the newest** (by effectiveDate); mark **all** `.process` candidates'
requestIds as processed (older ones are retired-without-applying — "last reset wins",
selection-clearing intent of a superseded reset is intentionally dropped).
Ordering inside the pass, single most correctness-critical sequence:
1. suppression already extended (A1, on sight, before anything else);
2. dispatch `didReceiveSyncReset(clearAppSelections:)` — its synchronous part clears
   selections; it then chains re-push → follow-up `performFullSync` on the pushTask chain;
3. mark requestIds processed (synchronously, same iteration, before any suspension point).

A kill before (3) re-processes on relaunch — idempotent re-clear/re-push, safe direction. A
follow-up pass after (3) sees `.skipAlreadyProcessed` — no loop. The follow-up sync runs
**unconditionally** after the re-push, success or not (today's behaviour, kept).

**B6. Never delete live markers outside GC.** `deleteAllSyncedData` excludes the
`SyncResetRequest` type **entirely** (rev 2's exclude-only-mine let two concurrent resets
annihilate each other's markers). `resetSync` also inserts its own requestId into
`processedResetRequestIds` at creation (belt) in addition to the `.skipOwnOrigin`
classification (braces).

### Part C — resetSync ordering & plumbing

`resetSync` becomes:
1. Save the new `SyncResetRequest` (failure ⇒ abort with the zone fully intact — a failed
   reset is now a no-op; closes #195.3);
2. `extendSuppression(now)` + mark own requestId processed (persisted before anything
   destructive);
3. `deleteAllSyncedData` — excluding `SyncResetRequest`, deleting in **chunks of ≤ 400
   recordIDs per `modifyRecords`** (a >400-record type otherwise fails `limitExceeded`
   deterministically, wedging every retry after the marker is already live);
4. Fire `didReceiveSyncReset` exactly as today — the origin's local behaviour, including
   clearing its own selections when the flag is set, is intentionally unchanged — which
   chains re-push → follow-up sync.

**Pass-abort commitment:** `performFullSync` must keep `pullResetRequests` as the first
pull, and **any `pullResetRequests` failure must abort the pass** before any pull whose
handler can reconcile deletions (today's `try` chain already does this; the
`zoneNotFound`/`unknownItem` swallow is acceptable only because `pullProfiles` swallows the
same codes without delivering). A future "log and continue" refactor here would silently
reopen #195 — called out for code review.

## Data flow (post-fix)

```
resetSync(origin):
  save SyncResetRequest ─► extendSuppression(now); mark own id processed
    ─► chunked wipe of data types (never SyncResetRequest, ≤400/op)
    ─► didReceiveSyncReset ─► clear own selections (if flag) ─► rePush(local)
                                 ─► performFullSync            [always, success or not]

performFullSync(any device):
  pullResetRequests:                        [failure ⇒ abort pass]
      any recordID fetched (even undecodable) ⇒ extendSuppression(effectiveDate | now)
      classify all decoded; age>21d ⇒ GC-delete (failures ignored)
      newest .process ⇒ didReceiveSyncReset ─► mark ALL .process ids processed
  pullProfiles ─► handleSyncedProfiles:
      apply upserts (always)
      deletion reconciliation IFF remoteIds nonempty
                              AND now ≥ suppressedUntil        [fresh read]
                              AND per-profile: syncVersion>0 ∧ !isNewerSchemaVersion
  pullLocations ─► handleSyncedLocations: same, minus the schema clause
  didRequestLocalDataPush ─► pushLocalData  [unchanged; never touches suppression]
```

## Partial-failure interleaving analysis

"Converges" = all devices end with the union of local data; no deletion or selection loss
outside genuine remote deletions (post-window) and the reset's own opt-in selection
clearing. "Suppressed" = `now < syncDeletionSuppressedUntil` on that device.

### resetSync (origin)

| # | Interleaving | Outcome |
|---|---|---|
| 1 | Marker save **throws** | Nothing wiped, no state changed, UI error. **No data loss** (was: durable landmine). |
| 2 | Marker ✓, crash before step 2 | Zone intact + live marker. Receivers process it (idempotent clear + re-push). Origin relaunch: sights own marker ⇒ suppression extends; own id unprocessed but `.skipOwnOrigin` ⇒ never self-processed via pull. Zone complete; suppression merely delays deletion propagation ≤ 8d. **Converges.** |
| 3 | Steps 1–2 ✓, wipe partial (across types/chunks), crash | Marker live; every device that sights it is suppressed; devices that don't sight it: wiped types pull empty ⇒ A2.1 skips. Origin relaunch: suppressed (persisted); its every-pass push restores its data. **Converges.** |
| 4 | Wipe ✓, killed before re-push | Zone = marker only. All pulls empty ⇒ A2.1 everywhere + suppression. Origin's next pass pushes everything. **Converges.** |
| 5 | Concurrent pass on origin mid-reset | Suppression persisted at step 2 before the wipe; monotonic — no concurrent pass can clear it (nothing clears it). Empty/partial pulls also A2.1-skipped where empty. **Safe.** |
| 6 | Two devices reset near-simultaneously | Wipes never touch markers (B6) ⇒ **both markers survive**. Each origin: own id pre-processed; processes the other's (newer wins per pass). Receivers sight ≥1 marker ⇒ suppressed; process newest; older ids retired (B5). Double re-push idempotent. Older reset's selection-intent superseded — accepted. **Converges.** |
| 7 | >400 records of one type | Chunked ≤400/op; mid-sequence failure ⇒ row 3. No deterministic wedge. Each retry is a new marker ⇒ re-clears selections family-wide when the flag is set — unchanged from intent (each retry is a new reset command); retries now actually succeed. |

### pullResetRequests (receiver)

| # | Interleaving | Outcome |
|---|---|---|
| 8 | Sight ✓ (suppression extended), killed before dispatch or before marking processed | Relaunch: re-sighted ⇒ suppression re-extended; id unprocessed ⇒ `.process` again ⇒ idempotent re-apply. Safe direction by construction (suppress-first, mark-last). |
| 9 | Marked processed ✓, killed mid-re-push | Relaunch: `.skipAlreadyProcessed`, **suppression persists** (monotonic, ~8d) ⇒ no deletion inference while the zone is rebuilt; every-pass push restores this device's data. Selection-clearing already applied (synchronous, step B5.2 precedes B5.3). **Converges.** |
| 10 | Any pass while any re-push (own or others') is in flight | Suppressed — by sight on this device, persisted, un-clearable. Closes rev 1's multi-pass hole, rev 2's ack-race/stale-task holes, rev 3's stale-presence-clear + stale-absence-no-re-arm hole, and the concurrent-pass clear leak. |
| 11 | Fresh device (empty processed map) | Marker age ≤ 7d: processes once — 3+ device delivery (#202.1). 7–21d: `.skipExpired` (no processing, no GC), but sighted ⇒ suppressed — protected while others converge. >21d: `.expiredCollect`. A device with pre-existing local profiles joining sync within 7 days of a clear-selections reset clears its selections — visible via `needsAppSelection` UI; within reset semantics; accepted. |
| 12 | Two receivers process the same marker concurrently | Both apply (idempotent); ids marked on each; marker not deleted. No race. |
| 13 | Origin clock skew (any direction) | `effectiveDate` prefers server `creationDate` (skew-immune). On the `requestedAt` fallback: future dates clamp to age 0 (processed once — id-idempotent, **no loop possible by construction**, unlike rev 3's capped watermark); past-skewed dates age out early (missed delivery — UX miss, no data risk: suppression is sight-based, not classification-based). |
| 14 | Receiver clock fast | ≤14d fast: cannot GC a live (≤7d) marker (B3 margin); may classify it `.skipExpired` (missed selection-clearing — UX), but sight ⇒ suppression still protects its data. >14d fast: can GC a live marker — family delivery broken for devices that never sighted it, and those devices retain only A2.1 (empty-pull) protection. Residual; requires a pathologically wrong clock; accepted & documented honestly (was mis-stated as ">14d" with a 14d gcTTL in rev 3; arithmetic now consistent: margin = gcTTL − processTTL = 14d). |
| 15 | Receiver clock slow | Marker appears future ⇒ age clamps to 0 ⇒ processed once (id-idempotent), suppression extends from `min(basis, now) = now` ⇒ normal 8d window. No loop, no extended suppression. |
| 16 | Marker present but undecodable / per-record fetch failure | Sight counts raw recordIDs ⇒ suppression extends (basis `now`). No processing (nothing decoded), no GC. Protected. (Pinned by test.) |
| 17 | `pullResetRequests` throws (network) | Pass aborts before any reconciling pull (Part C commitment). No sight, but also no reconciliation. Safe. |

### handleSyncedProfiles / handleSyncedLocations

| # | Interleaving | Outcome |
|---|---|---|
| 18 | remoteIds empty (any decode state) | Skip (A2.1). Closes #195.2 for profiles **and** locations. |
| 19 | remoteIds non-empty, suppressed | Skip. Closes #195.4 and every mid-window partial-zone case for devices that ever sighted the marker (or originated the reset). |
| 20 | remoteIds non-empty partial, device **never** sighted any marker and window closed/never opened | **Residual:** reconciles → may delete not-yet-re-pushed profiles, including own-only ones (permanent if no other device holds them). Requires the marker to be query-invisible on every pass this device ran since the reset, while data-record deletions are visible. Same staleness class as #219; accepted, stated honestly: the precondition is *no sight ever*, not "narrow window" — one sight suppresses for 8 days. |
| 21 | Non-empty, no marker sighted ≤8d, suppression expired, one profile deleted remotely | Reconciles + deletes locally — **normal propagation preserved** (regression test). |
| 22 | `isNewerSchemaVersion` local profile absent from remote | Never deleted by inference (A3), suppression state irrelevant. Zone copy reappears when the newer-app device pushes. Stale husks possible if that device never returns — accepted (read-only placeholders). |
| 23 | Suppression expires while one local record's push has failed for 8+ days | Next reconciling pass may delete that record locally (and its zone copy is absent) — genuine residual, bounded: requires ≥8 days of continuous push failure for that record *and* no marker re-sight. Also inherits the generic #219 stale-absence risk on the first post-window pass. Accepted & documented. |

## Intentional behaviour changes (documented)

- **Absence-based deletion propagation is suspended for ~8 days after any reset** (per
  device, from its last marker sighting basis). Deletions made anywhere during a device's
  suppression window are **not applied on that device until its window closes — and because
  every device re-pushes all its local data every pass, such deletions are typically
  resurrected zone-wide** (the deleting user will see the item return; deleting it again
  after the window sticks). This is the honest price of making reset-as-re-seed safe with
  absence-inference; it was already partially true today for any device that hadn't synced
  a deletion before a reset. Explicit record deletes (`deleteProfileFromSync`) still remove
  the CK record immediately; only the *inference* on other devices is windowed.
- **Deleting the last remaining profile (or location) no longer propagates via
  reconciliation** (empty remote ⇒ skip; other devices resurrect it by re-push). Non-last
  deletions propagate normally outside suppression windows.
- **Reset markers persist up to ~21 days** (tiny records; one per reset) instead of being
  consumed; every device syncing within 7 days receives the reset; GC is cooperative.
- **Newer-schema profiles are never deleted by absence-inference** (A3); stale read-only
  husks may linger if the newer-app device disappears — accepted.
- **Unchanged (noted, not changed):** the origin also clears its *own* app selections when
  "Clear App Selections" is chosen, though the alert copy (`SettingsView.swift:417-419`)
  describes only other devices. Pre-existing; follow-up issue candidate.
- **Account switching:** `processedResetRequestIds` are UUIDs (cannot collide across
  accounts — no cross-account suppression of delivery); `syncDeletionSuppressedUntil` may
  carry ≤8 days across an account switch (blocks only deletions — safe direction). Neither
  needs account-scoping.

## Concurrency & storage discipline

- Both new SharedData values are **compound read-modify-write** operations
  (`extendSuppression` = read-max-write; processed-id insert/prune = decode-merge-encode):
  each must be wrapped in a single `SharedData.withLock` block, matching the existing
  convention (`SharedData.swift:69-96`); `withLock` is not reentrant — no nesting.
- `syncDeletionSuppressedUntil` is **monotonic** (max-only). `processedResetRequestIds` is
  insert + prune-by-age only. Neither has a clearing operation; interleaved MainActor passes
  and cross-process readers cannot observe a protection downgrade.
- All comparisons take an injected `now` so tests pin time (AGENTS.md).

## Test plan (TDD)

Pure / in-memory — no CloudKit:

1. **`SyncResetRequest.classify`** (#202): precedence order; `.expiredCollect` iff
   age > 21d (boundary: exactly 21d ⇒ `.skipExpired`); `.skipExpired` iff 7d < age ≤ 21d
   (boundary: exactly 7d ⇒ processable); own-origin; already-processed (by id, regardless
   of dates); future effectiveDate ⇒ age 0 ⇒ `.process` when unprocessed;
   `creationDate`-preferred-over-`requestedAt`. Single pinned `now` per test.
2. **Newest-only + retire-the-rest** (B5): several `.process` candidates ⇒ exactly the
   newest dispatched, **all** their ids marked processed (pure helper).
3. **`extendSuppression`** (A1): monotonic max; `min(basis, now)` clamp for future basis;
   nil start; never decreases.
4. **`handleSyncedProfiles` gating** (#195) via `didReceiveSyncedProfiles`, seeded
   in-memory `ModelContext`, `MockSessionController`, injected suppression state + `now`:
   - empty remote (with and without decoded profiles) ⇒ synced locals **retained**;
   - non-empty remote, suppressed ⇒ missing locals **retained**; upserts still applied;
   - non-empty remote, suppression expired (or nil), one missing ⇒ **deleted** (regression
     for normal propagation, row 21);
   - `syncVersion == 0` ⇒ never deleted; `isNewerSchemaVersion` ⇒ never deleted even
     unsuppressed (A3).
5. **`handleSyncedLocations` gating**: mirror of (4) minus the schema clause. Location
   `syncVersion` is pull-confirmed (set only in `handleSyncedLocations`,
   `SyncCoordinator.swift:441/454`), unlike push-optimistic profile `syncVersion` — seed it
   directly in tests; no push round-trip needed.
6. **Processed-id map**: insert, idempotent re-insert, prune at > 21d, bounded growth.
7. **`SharedData` round-trips**: both new keys, defaults, `withLock`-wrapped compound ops
   (reuse the ephemeral-suite pattern from `SharedDataLockTests`).

Code-inspection commitments (not unit-testable without a CK seam; each called out in the PR
description for review):
- `resetSync` step order (C.1–4), including suppression + own-id persisted before the wipe;
- suppression extended on **raw recordID sight** before decode/classify (B/A1), and
  `didReceiveSyncReset` dispatched before ids are marked (B5 order);
- chunking ≤ 400; wipe excludes `SyncResetRequest`; GC failures ignored;
- pass-abort: `pullResetRequests` failure prevents all reconciling pulls (Part C).

## Out of scope

- Tombstones / change-token (`CKFetchRecordZoneChangesOperation`) sync — the correct
  long-term fix for rows 20/23 and #219.
- Introducing a CloudKit mock / `CKDatabase` abstraction.
- Any change to session or emergency-settings sync.
- The origin self-clear vs. alert-copy mismatch (follow-up issue).
- A reentrancy guard for `performFullSync` (concurrent passes are made safe *for this
  design* by monotonic state; serializing passes generally is a separate improvement).
- CloudKit schema changes: none — no new record fields (`creationDate` is system metadata);
  no new query predicates.
