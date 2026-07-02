> **SUPERSEDED (2026-07-02):** rev 2 of the A1 design. Broken by adversarial round 1 (see
> `2026-07-02-reset-sync-a1-interleavings-round1.md`, 27 findings): the "clear gate on
> zero-failure push" rule is unsound (push acks race the origin's snapshot wipe; the
> follow-up pull is not read-your-writes; stale/pre-reset push tasks clear a newer reset's
> gate; never-pushable newer-schema profiles make "zero failures" a lie), and two concurrent
> resets mutually annihilate each other's markers. Preserved as part of the A1 acceptance
> corpus for #267 — see `2026-07-02-reset-sync-a1-acceptance-corpus.md`.

# Design: Reset-Sync Safety (SyncResetRequest lifecycle)

- **Bundle:** A1 (epic #263)
- **Issues:** #195 (critical) reset race wipes local profiles; #202 (high) reset consumed by first device / never GC'd
- **Date:** 2026-07-02 (rev 2 — adds persistent re-push gate, location gating; supersedes the per-pass flag of rev 1)
- **Files:** `Foqos/CloudKit/ProfileSyncManager.swift`, `Foqos/CloudKit/SyncCoordinator.swift`,
  `Foqos/CloudKit/SyncModels.swift`,
  `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift`

## Problem (re-verified against current `main`, 2026-07-02, post-PR #264)

*(identical to rev 1's problem statement, with one addition:)*

**#195.5 — Same defect for locations.** `handleSyncedLocations` (`SyncCoordinator.swift:479-499`)
runs the identical delete-on-absence reconciliation for `SavedLocation`, and
`deleteAllSyncedData` wipes `SyncedLocation` records too. Every #195 scenario also destroys
local saved locations. (Sessions and emergency settings have no absence-based deletion, so
they are not exposed.)

## Constraints & design forces

As rev 1, plus:

- **CloudKit custom zones are atomic per operation.** `deleteAllSyncedData` issues one
  `modifyRecords` per record type, so within a type the deletion is all-or-nothing (a
  `limitExceeded` failure deletes nothing). Partial wipes are therefore partial *across
  types*, never within `SyncedProfile`. This bounds — but must not carry — the failure
  analysis; the gates below hold even if a within-type partial state somehow occurred.
- **`pushLocalData` re-pushes all local profiles and locations at the end of every full
  sync pass** (`SyncCoordinator.swift:45-100`, via `didRequestLocalDataPush`). Convergence
  after any failure therefore does not depend on a special retry path; it only requires that
  reconciliation not destroy local data before a re-push has happened.

## Approach

Two cooperating mechanisms — **reconciliation gating** (fixes #195, the destructive path)
and **request lifecycle** (fixes #202, delivery + cleanup) — plus an **ordering fix** that
turns a failed reset from a data-wipe into a no-op.

### Part A — Reconciliation gating (#195)

**A1. Order: marker before wipe, and never wipe the current marker.**
In `resetSync`, save the `SyncResetRequest` **first**, capture its `recordID`, then call
`deleteAllSyncedData(excluding: currentRequestRecordID)`. A reset that fails at the network
layer now leaves *all* CloudKit data intact instead of a wiped, marker-less zone (closes
#195.3). Excluding only the current request means older `SyncResetRequest` records are still
wiped by the reset itself (part of #202 cleanup). *(Round 1 showed this exclusion rule is
itself a hole: two concurrent resets delete each other's markers.)*

**A2. Empty-pull is never authoritative for deletions.**
Skip deletion reconciliation whenever `remoteProfileIds.isEmpty`, regardless of how many
profiles decoded; same for `remoteLocationIds.isEmpty`. (Closes #195.2.)

**A3. Persistent re-push gate: no deletion reconciliation until this device's post-reset
re-push has completed.**
A per-device, *persisted* marker `SharedData.resetRePushPendingSince: Date?`:

- **Set** (to the request's `requestedAt`) synchronously *before* the reset is applied:
  by `pullResetRequests` when it classifies a request `.process`, before invoking
  `didReceiveSyncReset`; and by `resetSync` on the origin, before `deleteAllSyncedData`.
- **While set (and within TTL)**: `handleSyncedProfiles` and `handleSyncedLocations` skip
  deletion reconciliation (upserts still apply).
- **Cleared** when a complete local re-push finishes with **zero per-record failures** —
  both `rePushLocalSyncedData` (the reset path) and `pushLocalData` (every full sync pass)
  report success/failure counts and clear the flag on a clean run. If some pushes failed,
  the flag stays set and the next pass's push retries.
- **TTL backstop:** a pending flag older than `SyncResetRequest.defaultTTL` (7 days) is
  ignored (reconciliation resumes) and cleared.

Rationale vs rev 1's per-pass boolean: the destructive window is not one pass wide. After a
device processes a reset, its watermark (B1/B6) has already advanced, so a *subsequent*
pass — a manual "Sync Now" seconds later, or an app relaunch after a crash mid-re-push —
would classify the request `.skipAlreadyProcessed`, reconcile against the still-partial
zone, and delete local data that was never re-pushed. A persisted gate closes
process-crash-relaunch, concurrent manual sync, and the origin's own crash-after-wipe.
*(Round 1 proved the CLEARING rule wrong, not the persistence idea: "zero per-record
failures" is push-ack evidence, which proves nothing about the zone under a concurrent
snapshot wipe, is not read-your-writes for the follow-up pull, can be produced by a
pre-reset stale task, and silently excludes never-pushable `isNewerSchemaVersion` profiles.)*

**A4. Re-push before the follow-up sync.**
`handleSyncReset` already chains `rePushLocalSyncedData` then `performFullSync` inside one
`Task`; keep that ordering.

### Part B — Request lifecycle (#202)

As rev 1 (B1 watermark, B2 TTL = 7 days, B3 cooperative GC, B4 no-delete-within-TTL,
B5 pure classifier with `.expiredCollect` checked first, B6 synchronous watermark advance),
with the addition that the gate (A3) covers the crash window B6 leaves open: a crash between
watermark advance and re-push completion is covered by the persisted gate.

### Interplay

- A2 protects devices that **cannot see** the marker yet (mid-wipe, index lag, marker save
  in flight): an empty pull deletes nothing.
- A3 protects devices that **have seen** the marker, across the entire re-push window,
  including crashes and concurrent passes.
- B1–B6 make delivery reach every device exactly once and make cleanup independent of any
  single device's survival.

## Data flow (post-fix)

```
resetSync(origin):
  save SyncResetRequest ──► set resetRePushPendingSince ──► deleteAllSyncedData(excluding: current)
      └► didReceiveSyncReset ──► clear selections (if flag) ──► rePush(local)
                                     └► on zero failures: clear gate ──► performFullSync

performFullSync(any device):
  pullResetRequests()                    # classify each: expiredCollect / skip / process
      .process ⇒ advance watermark; set gate; didReceiveSyncReset (as above)
  pullProfiles ──► didReceiveSyncedProfiles(profiles, remoteIds)
      handleSyncedProfiles:
        apply upserts (unchanged)
        reconcile deletions ONLY IF !remoteIds.isEmpty && gate not set/expired
  pullLocations ──► (same gating)
  didRequestLocalDataPush ──► pushLocalData ──► on zero failures: clear gate
```

## Partial-failure interleaving analysis (as claimed at the time — several rows were REFUTED in round 1)

### resetSync (origin)

| # | Interleaving | Claimed outcome (annotations from round 1) |
|---|---|---|
| 1 | Save request **throws** | No data loss — a failed reset is a no-op. *(Held.)* |
| 2 | Save ✓, crash before gate set / before wipe | Converges. *(Held.)* |
| 3 | Save ✓, gate ✓, wipe partial, crash | Converges via gate + re-push. *(Held, modulo the clearing-rule holes.)* |
| 4 | Save ✓, gate ✓, wipe ✓, killed before re-push | Converges via A2 + gate. *(Held.)* |
| 5 | Concurrent pass on origin mid-reset | Safe. *(Held.)* |
| 6 | Two devices reset near-simultaneously | "At least the later wipe's marker survives … **Converges**." **REFUTED (round 1):** each wipe's `SyncResetRequest` snapshot can include the other origin's marker (the type is wiped last), so BOTH markers are deleted; a third device then reconciles a partially re-seeded zone with zero protection. |

### pullResetRequests (receiver)

| # | Interleaving | Claimed outcome (annotations from round 1) |
|---|---|---|
| 7 | Gate ✓, watermark ✓, apply ✓, re-push ✓, GC delete fails | Harmless. *(Held.)* |
| 8 | Gate ✓, watermark ✓, crash before/during apply or mid-re-push | Converges via persisted gate. *(Partially held — but see clearing-rule holes.)* |
| 9 | Manual "Sync Now" while another pass's re-push is in flight | "Gate still set ⇒ skip. Closes the rev-1 hole." **REFUTED (round 1):** a pre-reset `pushLocalData` task straddling the wipe completes "clean" and clears the gate a later reset set (no CAS/attribution); also a receiver's clean re-push racing the origin's still-in-flight wipe clears the gate while the zone is about to lose the re-pushed records. |
| 10 | Fresh device sees within-TTL reset | Delivery correct; stale (>TTL) skipped + GC'd. *(Held.)* |
| 11 | Two receivers process the same request concurrently | Both apply; no delete race. *(Held.)* |
| 12 | `requestedAt` far in future (clock skew) | "Watermark jumps forward → a legit reset could be skipped. Rare; accepted." **REFUTED as under-stated (round 1):** a poisoned watermark disarms the gate for a later legitimate reset — data loss, not just a skipped selection-clear. |
| 13 | Re-push permanently failing | Gate suppression bounded by 7-day backstop. **REFUTED as mis-anchored (round 1):** the gate stores the request's `requestedAt`, so a device processing a 6.9-day-old reset gets a gate that expires in ~2 hours; and on expiry the same pass reconciles BEFORE its push, deleting own-only data permanently. |

### handleSyncedProfiles / handleSyncedLocations reconciliation

| # | Interleaving | Claimed outcome (annotations from round 1) |
|---|---|---|
| 14 | remoteIds empty, decoded empty | Skip (A2). *(Held.)* |
| 15 | remoteIds empty, decoded non-empty | Skip (A2 subsumes old guard). *(Held.)* |
| 16 | remoteIds non-empty partial + gate set | "Skip (A3). Closes #195.4 and the multi-pass window." **REFUTED (round 1):** the design's own zero-failure clear rule removes the gate while the origin's wipe is still in flight (ack-race); `isNewerSchemaVersion` profiles are never re-pushed yet remain deletion-eligible, so a "clean" re-push clears the gate without their data in the zone and reconciliation then deletes them. |
| 17 | remoteIds non-empty partial, no marker visible (index lag), no gate | Residual, "narrow". **Round 1: mischaracterised** — marker and data-record indexes are independent; and own-only profiles deleted before the end-of-pass push are lost permanently, not "self-healed with selection loss". |
| 18 | Non-empty, complete, no reset/gate, one deleted remotely | Normal propagation preserved. *(Held.)* |

## Intentional behaviour changes / test plan / out of scope

As rev 1, plus: reset requests persist (within TTL) instead of being consumed; gate-lifecycle
tests (set-before-dispatch; cleared on zero-failure push; retained on partial failure;
TTL-expiry) — *round 1 additionally showed "zero per-record failures" is ambiguous (zero-attempt
early-return paths count as clean) and the gate/watermark write order was unspecified.*
