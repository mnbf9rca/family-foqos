# A1 acceptance corpus — reset-sync failure scenarios for the #267 sync-engine replacement

- **Status:** authoritative acceptance suite for issue #267 (change-token sync engine).
- **Provenance:** bundle A1 (#195/#202) went through four design revisions and three
  independent adversarial verification rounds (65 findings). Maintainer decision
  (2026-07-02, recorded on #267): no live users exist, so the query-based sync layer is
  replaced, not patched. This corpus preserves everything learned; **every scenario below
  must be shown safe or impossible-by-construction under the #267 design** (corpus-mapping
  table is a required deliverable of that design).
- **Files in this corpus:**
  - `2026-07-02-reset-sync-a1-design-rev1.md` … `rev4.md` — the four design revisions,
    each annotated with why it fell.
  - `2026-07-02-reset-sync-a1-interleavings-round1.md` (27 findings, vs rev 2),
    `…-round2.md` (20 findings, vs rev 3), `…-round3.md` (18 findings, vs rev 4) —
    verbatim, machine-extracted verifier output. The canonical scenarios below cite these
    as `rN/<lens>-<i>`.

## 1. The structural result

Three rounds converged on one root cause: **the sync layer infers deletions from absence in
eventually-consistent CKQuery results.** Under that model:

- *Absence is not evidence of deletion* — it is indistinguishable from mid-wipe, mid-re-push,
  index lag, or a failed push.
- *Presence is not evidence of durability* — a pull can show stale presence of wiped records,
  and a push ack can be undone by a concurrent snapshot-based wipe.
- Therefore **no client-observable event can safely end a protection window early**, and any
  time-boxed window is either born-expired for stragglers (anchored to the reset) or
  clock-defeatable (anchored to local time).

**The vacuous-reconciliation proof (r2/crashChurn-2, r2/readVerification-3).** Rev 3 tried
"resume deletions once a pass proves the zone contains everything this device could
re-create" (`remoteIds ⊇ {local: syncVersion > 0 ∧ ¬isNewerSchemaVersion}`). But
reconciliation's deletable set is `{local: syncVersion > 0 ∧ ¬isNewerSchemaVersion ∧
id ∉ remoteIds}` — a subset of the restorable set, hence **empty whenever the proof
passes**. Evidence-based early exit either authorizes nothing (proof passes ⇒ nothing to
delete) or is unsafe (proof fails ⇒ any deletion may be a not-yet-re-pushed record). This is
why deletions must arrive as **explicit events** (tombstones / `recordWithIDWasDeleted`),
which is the core of #267.

## 2. Canonical acceptance scenarios

Grouped by root-cause class. Sources cite the verbatim appendix findings; several scenarios
were independently discovered by multiple lenses. The #267 design's corpus-mapping table
must give each ID a verdict: **impossible-by-construction** (preferred), **safe** (with the
protecting mechanism named), or **accepted-residual** (with honest preconditions — "narrow"
is not a verdict).

### Class A — deletion-by-absence vs. reset/wipe races

| ID | Scenario | Sources |
|----|----------|---------|
| A-1 | Wipe runs before any marker exists; another device pulls an empty/partial zone with no marker and mass-deletes local profiles (original #195; also the guard at `SyncCoordinator.swift:179` covering only decode failures) | handover #195; r1 problem stmt |
| A-2 | Wipe throws mid-way before the marker is saved: durable marker-less wiped zone; every later sync on every device wipes local data | handover #195.3 |
| A-3 | Marker seen, re-push dispatched async, the *same* pass continues into pullProfiles and reconciles against the partial zone | handover #195.4 |
| A-4 | A *subsequent* pass (manual "Sync Now", crash-relaunch, follow-up sync) reconciles against the still-partial zone after per-device processing state has already advanced | r1/interleavings-3, r1/crashRecovery-4, r2/cloudkitOps-1 |
| A-5 | Push ack ≠ durability: records acked by device B are deleted moments later by the origin's snapshot-based wipe; B's "clean re-push" evidence is false | r1/interleavings-1, r1/cloudkit-1 |
| A-6 | Not read-your-writes: the pass right after a clean re-push pulls a set missing the just-pushed records and self-deletes them locally | r1/crashRecovery-1 |
| A-7 | Stale **presence**: a pull shows the pre-wipe zone, clearing/satisfying protection while the zone is genuinely wiped; the next truthful pull deletes | r2/crashChurn-1, r2/cloudkitOps-5 |
| A-8 | Stale **absence** of the marker: the marker exists but a pass's marker query misses it while the same pass's data query already reflects the wipe (includes the partial-chunk variant r3/stateMachine-6) | r1 row 14 class; r2/readVerification-1; r3/stateMachine-6 |
| A-9 | Vacuous reconciliation: any evidence gate that passes has an empty deletion set (see §1); "verify then resume" resumes nothing and its clearing write is a new race surface | r2/crashChurn-2, r2/readVerification-3 |
| A-10 | Concurrent passes (no reentrancy guard on `performFullSync`): one pass's protection-clear is consumed by another in-flight pass holding a stale pulled set | r2/cloudkitOps-1, r2/specReview-1 |
| A-11 | Sole-copy data: reconciliation deletes local records **before** the end-of-pass push runs; if no other device holds them, loss is permanent (not "self-healing with selection loss") | r1/crashRecovery-2, r1/cloudkit-4, r3/temporal-1 |
| A-12 | `isNewerSchemaVersion` profiles: never pushable by this device (filtered at `SyncCoordinator.swift:64/:567`) yet deletion-eligible; no re-push can ever restore them | r1/interleavings-4, r1/crashRecovery-7 |
| A-13 | Locations mirror every scenario above (`handleSyncedLocations`, `SyncCoordinator.swift:479-499`); note location `syncVersion` is **pull-confirmed** (set only on receipt, incl. the `max(syncVersion,1)` "seen from remote" path at `:454`), unlike push-optimistic profile `syncVersion` (`pushProfile` increments before network) | rev 2 §#195.5; r2/specReview-3 |
| A-14 | Deleting the *last* remaining profile/location: an empty-remote guard blocks propagation and blanket re-push resurrects it; conversely, no guard means an empty pull is a mass-delete. Any design must state which side it takes and why | rev 2 A2 discussion; r4 intentional changes |

### Class B — reset-command (marker) lifecycle (#202)

| ID | Scenario | Sources |
|----|----------|---------|
| B-1 | Consume-on-first-read: first non-origin device deletes the command; devices 3..N never receive it | handover #202.1 |
| B-2 | Origin never cleans up; single-device account: command lingers forever; a device enabling sync a year later processes it and wipes app selections | handover #202.2/.3 |
| B-3 | Two near-simultaneous resets mutually delete each other's markers (each wipe excludes only its own); third devices lose both delivery and protection | r1/interleavings-2, r1/crashRecovery-3, r1/cloudkit-2 |
| B-4 | >400 records of one type: single `modifyRecords` fails `limitExceeded` deterministically **after** the marker broadcast; reset can never complete while every retry re-clears selections family-wide | r1/cloudkit-3 |
| B-5 | Undecodable / future-schema / per-record-`.failure` marker records: protection and GC must both be defined for them; rev 4 protected on raw-recordID sight but had **no GC path**, making one corrupt record suppress deletion propagation family-wide **forever** (profiles become undeletable) | r2/readVerification-4, r2/cloudkitOps-4, r3/temporal-2 |
| B-6 | Background cold-launch (`content-available` push) processes the command with `modelContext == nil`: `handleSyncReset` silently no-ops, yet the command is marked processed — consumed without ever being applied | r3/stateMachine-2 |
| B-7 | Same-device double-dispatch: classify-then-mark spans an await (e.g. a GC network call); two concurrent passes both dispatch the same command | r3/stateMachine-4, r3/specReview-2 |
| B-8 | Command supersession: multiple pending resets — newest must win; a superseded older command must not be applied after a newer one; tie-break at equal timestamps must be defined | rev 4 B5; r3/specReview-3 |

### Class C — clocks (a screen-time app must assume children manipulate device clocks)

| ID | Scenario | Sources |
|----|----------|---------|
| C-1 | Origin clock skew: client-written timestamps (e.g. `requestedAt`) poison any date-ordered processing; server-assigned metadata (`CKRecord.creationDate`) is the only skew-immune ordinal | r1/interleavings-5, r2 B2 |
| C-2 | Receiver clock **fast** by more than (gcTTL − processTTL): GCs a live command inside other devices' delivery window (rev 3 claimed a 14d margin but had 7d: GC fires at real age ≥ gcTTL − F) | r2/cloudkitOps-3 |
| C-3 | Receiver clock **slow**: any date-comparison idempotency (watermark, even capped at now+slack) re-processes the same command every pass — infinite loop of selection-clearing + full re-push, self-sustaining past every throttle. Idempotency must be by **identity**, never by time | r2/readVerification-2, r2/crashChurn-3, r2/cloudkitOps-2 |
| C-4 | Protection window anchored to the *event's* date is **born expired** for a device that first syncs ≥ window after the event — exactly the straggler whose data nobody re-pushed; anchoring to *local receipt* time instead is defeated by C-5 | r3/temporal-1, r3/stateMachine-1 |
| C-5 | Forward clock roll during an active local-time window silently ends it (fails toward delete, violating fail-toward-keep) | r3/temporal-3 |
| C-6 | Pruning local idempotency memory by local clock while the remote command outlives it: a ≥(prune-window)-slow clock re-processes an expired command after the prune | r3/stateMachine-3 |

### Class D — process & state hygiene

| ID | Scenario | Sources |
|----|----------|---------|
| D-1 | SIGKILL between any two statements: the order of persisted writes must fail toward "re-process idempotently *with* protection", never "skip *without* protection" | r1/interleavings-6, r1/crashRecovery-5, r2/crashChurn (ordering) |
| D-2 | Pass-abort coupling: if fetching sync-commands fails, no later step of the same pass may act destructively; today this holds only via an incidental `try` chain — it must be an explicit invariant | r2/crashChurn-4, r3/specReview-1 |
| D-3 | iCloud account switch: per-device persisted sync state (tokens, processed-command ids, windows) must be account-scoped or provably harmless across accounts (precedent: `legacyCleanupKey(for: userRecordName)`) | r2/cloudkitOps-7, r3/specReview-4 |
| D-4 | Sync disable → re-enable mid-operation (the `$isEnabled` sink calls `setupSync` → full sync immediately) | r1/crashRecovery (8a); rev 4 constraints |
| D-5 | The 5-minute notification throttle (`ProfileSyncManager.swift:882-900`): missed notifications must degrade to latency, never to lost state transitions (#200 is absorbed by #267 for this reason) | r3/stateMachine (throttle lens); #267 scope |
| D-6 | Zone deleted externally (iCloud settings) and recreated: subscriptions, tokens, and local state must all survive or re-bootstrap deliberately (today: `zoneNotFound` early-returns mask this) | r3 brief (§zone), #267 req 3 |
| D-7 | All compound persisted state updates must follow the `SharedData.withLock` convention (non-reentrant flock) or document why MainActor serialization suffices | r2/specReview-4 |

### Class E — product semantics to preserve or consciously re-decide

| ID | Item | Sources |
|----|------|---------|
| E-1 | `FamilyActivitySelection` never syncs (device-local tokens); recreated profiles arrive `needsAppSelection = true` and enforce nothing until re-selected — this is why "husk resurrection" is *silent blocking failure*, the top-severity outcome | handovers; deviation-report |
| E-2 | Reset Sync UI contract (`SettingsView.swift:389-419`): copy describes effects on *other* devices only, yet the origin also clears its own selections via the direct `didReceiveSyncReset` call (`ProfileSyncManager.swift:848`) — pre-existing mismatch, follow-up issue; #267's reset re-design should resolve it deliberately | r1 context sweep |
| E-3 | Safety asymmetry (maintainer-endorsed): wrongly deleting profiles/selections is catastrophic and silent; wrongly keeping/resurrecting one is minor and visible. Ambiguity resolves toward "keep" | rev 1–4 |
| E-4 | Normal deletion propagation must keep working: with no reset in flight, deleting a profile on one device removes it on others (the regression tests of every rev) | rev 1–4 test plans |

## 3. Rev 4 residual table — what the best query-based design still could not close

Rev 4 (monotonic ~8-day suppression window + identity-based processed-ids) was the
strongest patch found. Round 3 still produced `has-holes` on all lenses. Its residuals,
with **real** preconditions — these are the specific items #267 must close (or accept with
eyes open):

| # | Residual | Real precondition | Round-3 source |
|---|----------|-------------------|----------------|
| R1 | Born-expired window: device first sighting a ≥8d-old marker gets zero suppression, `.skipExpired` skips the re-push, and the same pass reconcile-deletes its sole-copy data before its own push runs | An 8-day sync gap (vacation iPad) — no failures, no skew needed | temporal-1, stateMachine-1 |
| R2 | One undecodable marker ⇒ suppression extended from `now` on every sight, and no GC path (GC needs decode) ⇒ deletion propagation dead family-wide, forever; profiles undeletable | One corrupt/future-schema marker record | temporal-2 |
| R3 | Forward clock roll ≥ remaining window re-opens the wipe for that device | Clock set forward once, mid-window | temporal-3 |
| R4 | Reset consumed-but-never-applied on background cold-launch (`modelContext == nil` no-op, id still marked processed) | A content-available push before first foreground | stateMachine-2 |
| R5 | ≥14d-slow clock + 21d local prune re-processes an expired reset (selection re-clear) | Constant slow clock + dormant origin | stateMachine-3 |
| R6 | No-sight-ever + partial non-empty zone ⇒ reconcile-deletes not-yet-re-pushed data (permanent for sole copies) | Marker query-invisible on *every* pass the device ran since the reset | carried from r1 row 14 / r2 row 20 |
| R7 | Intentional cost: deletion propagation suspended ~8 days after every reset; deletions made in the window are resurrected by blanket re-push | Any reset (by design) | rev 4 intentional changes |
| R8 | >14d-fast receiver clock GCs a live marker: delivery broken for devices that never sighted it | Pathological clock | rev 4 row 14/15 (corrected arithmetic) |

#267's change-token model should make R1–R3, R6, R7 **impossible by construction**
(deletions are explicit events; no windows, no absence inference). R4, R5, D-* remain real
design obligations for the new engine (they are about command processing and state hygiene,
not about absence inference).

## 4. Obligations this corpus places on the #267 design

1. A **corpus-mapping table**: every ID above → *impossible-by-construction* / *safe
   (mechanism named)* / *accepted-residual (honest preconditions)*. No "narrow window"
   verdicts.
2. The design must pass the same adversarial process that produced this corpus: independent
   skeptic rounds until a full round yields no breaking interleaving.
3. Token lifecycle is in scope of the mapping: bootstrap (no token), `changeTokenExpired`,
   zone deleted/recreated (D-6), account switch (D-3) — each is an opportunity to
   reintroduce a full-requery path, which is where Class A comes back from the dead.
4. Reset Sync re-designed on the new transport must be mapped against **all of Class B**,
   and E-2 resolved deliberately.
