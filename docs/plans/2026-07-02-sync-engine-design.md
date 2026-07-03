# Design: CKSyncEngine sync transport (#267) — implementation contract

- **Issue:** #267 (supersedes bundles A1/A2; absorbs #195, #202, #219, #200, #201)
- **Date:** 2026-07-03 (v9 — incorporates adversarial round 8 (SDK-verified): the
  bootstrap strip is honest — single engine, synchronous strip, named AB-4 with mocked
  test and two containment nets (no 'by construction' claim; Configuration cannot be
  mutated post-init); engine fetch/send never called from within handleEvent (documented
  prohibition) — §5.5 retries are scheduled after the handler returns; gate arm-2
  rationale corrected (zone-CAS + N1, zoneNotFound ⇒ resume); §5.1 legacy-identification
  routing arm; own-command arms set lastAppliedResetCommandId; wording drift fixed.
  v8 was round 7: the .deleting resume
  gate observes the command by direct record fetch and its case-split is total
  (own ⇒ confirmed; prior-or-none ⇒ resume; foreign ⇒ abandon+surface; undecodable ⇒
  abandon+surface); legacyCleanupIds gives the legacy exemption an implementable,
  persisted carrier; bootstrap inits with automatic sync disabled until the strip
  completes (no send-timing assumption); lastAppliedResetCommandId write sites pinned;
  I12 recovery scoped to controller start; table/text drift fixed. v7 was round 6: the T1 strip extends to
  restored pending DATABASE changes (resetIntent is the sole source of truth for zone
  changes, symmetric with tombstones); lastAppliedResetCommandId gives priorCommandId a
  defined provenance; own-id resume case; legacy flag set on confirmed deletion; §5.4
  refuse = remove; sync paths use a dedicated ModelContext so rollback is scoped;
  in-flight async continuations invalidated on T7/T11. v6 was round 5: all restored pending
  deletes stripped at start and every recovered tombstone verified (no fresh/restored
  discretion); failed-apply entries superseded by later successful applies and .delete
  replays verify-by-fetch; §5.2 tombstone-clear also dequeues the outbound delete;
  reset-resume snapshots the known command id; abandoned reset intents dequeue their
  zone changes; context rollback on failed writes; echo guard scoped by cycle start;
  AB-3 fetch-cycle delimiters; T-row/branch cross-references pinned. v5 was round 4: verify-before-delete for
  recovered delete intents (restore-from-backup replay class); tombstone rollback +
  entity-present rule in the funnel delete path; persisted failed-apply retry set;
  confirmed-delete echo guard; T1 recovers a stuck seed intent; legacy cleanup as an
  enumerated exception. v4 was round 3: delete-intent tombstones
  replace the v3 sweep's absence inference; apply-gated + type-scoped `systemFields`;
  observable seed-intent clearing; own-origin apply skip removed; pending-delete-wins
  fetch rule; branch naming disambiguated)
- **Status:** **converged** — adversarial round 9 (2026-07-03) produced no breaking
  interleaving (two independent attackers: sound-with-nits; remaining findings were
  text drift, fixed editorially in this revision). Nine rounds total; full history in
  the PR #268 description and the A1 corpus appendices.
- **Acceptance suite:** `2026-07-02-reset-sync-a1-acceptance-corpus.md`; the mapping in
  `2026-07-02-sync-engine-corpus-mapping.md` is a normative part of this design.
- **Audience:** the implementing session. This is a contract: the state machine,
  invariants, and named test scenarios are requirements. Where the contract is silent,
  follow AGENTS.md and existing SyncCoordinator apply-side semantics.

## 1. Scope and non-goals

**Replace** the CKQuery-based private-database sync transport in
`ProfileSyncManager`/`SyncCoordinator` — profiles (`SyncedProfile`), locations
(`SyncedLocation`), sessions (`ProfileSession` transport only), emergency settings
(`SyncedEmergencySettings`, a single fixed-name record), and the Reset Sync feature — with
**`CKSyncEngine`** (iOS 17+; project targets 18.6).

**Keep unchanged:** all CKRecord schemas (no new record types or fields — the reset
command reuses the `SyncResetRequest` type); the apply-side merge semantics in
`SyncCoordinator` — with two deliberate, named amendments (§5.1: the own-origin apply
skip is removed; §5.1: fetched modifications shadowed by a pending delete are skipped);
`SessionSyncService`'s CAS write path — with one deliberate amendment (§6:
stop-on-absent); the shared-DB FamilyCommand/lock-code channel (out of scope, B2); all UI
except §8.5.

**Non-goals:** implementation (separate session); behavioural redesign of what syncs;
performance tuning beyond what the engine provides.

**V1→V2 migration independence (maintainer clarification, #267 2026-07-02):** the local
migrator (`ProfileMigrationUtil` / `migrateToV2IfNeeded`) is a local schema transform with
no ordering dependency in either direction on this rewrite. Explicit invariants:
(a) **CKRecord payload shape is unchanged** — `SyncedProfile` records keep carrying both
V1 fields (`blockingStrategyId`/`strategyData`) and the V2 trigger fields plus
`profileSchemaVersion`; transport only, never record shape; (b) the **schema-version gate
is I9** and must survive the swap intact. Migration-time mutations flow through the
`MutationFunnel` (I2). #266 stays in bundle D4.

### 1.1 Why CKSyncEngine (decision record)

| Requirement (#267) | CKSyncEngine | Manual `CKFetchRecordZoneChangesOperation` |
|---|---|---|
| Deletions as explicit events | `fetchedRecordZoneChanges.deletions` (with `recordType`) | same, hand-rolled |
| Token lifecycle incl. expiry | engine-internal | persisted tokens + `changeTokenExpired` by hand |
| Push queue, scheduling, backoff | `state.pendingRecordZoneChanges`, persisted | hand-rolled queue (the #201 class, again) |
| Push notifications | engine-owned database subscription | hand-rolled subscription + throttle (#200 class) |
| Zone lifecycle events | `fetchedDatabaseChanges.deletions` with reasons | infer from `zoneNotFound` (the ambiguity that hid A-2) |
| Account changes | `accountChange` event | `accountStatus` polling |

The fallback would re-implement, by hand, the four subsystems whose hand-rolled versions
produced this corpus. CKSyncEngine is chosen; the fallback is rejected unless
implementation discovers a hard blocker (stop, document, return to design).

**Assumption boundary (normative).** The engine is relied on for scheduling, tokens,
subscriptions, event delivery shape, **and**:

- **AB-1:** pending **database** changes are sent before pending **record** changes
  (documented; §5.3 branch Z / §8.1 depend on it; mocked test S-25).
- **AB-2:** a `stateUpdate` serialization reflects only fetch progress whose events have
  already been delivered and handled (makes persist-on-`stateUpdate` safe for **fetch
  tokens**; mocked test S-26).
- **AB-3:** fetch cycles are delimited by `willFetchChanges`/`didFetchChanges`, and a
  `didFetchChanges` implies that cycle's `fetchedRecordZoneChanges` events were all
  delivered (T2 and the echo guard's cycle-start scoping depend on it; mocked test S-37).
- **AB-4:** the engine initiates no send of restored pending changes between its init
  and the end of the same synchronous main-actor region (the T1 strip window; mocked
  test in S-38). This is the strip's one real timing assumption — `automaticallySync`
  is an init-time `Configuration` value that cannot be flipped on a live engine, so the
  window cannot be closed by construction. Two containment nets hold even if AB-4 is
  violated: record deletes cannot materialize without §5.4's tombstone-membership
  approval (a delegate chokepoint), and a zone-delete confirmation arriving with
  `resetIntent == nil` is handled as T5 (purge + re-seed).
- The delegate contract prohibits calling `fetchChanges()`/`sendChanges()` from within
  `handleEvent` (documented; doing so deadlocks the serial event stream). All explicit
  fetch/send requests are scheduled in a `Task` after the handler returns (§5.0).
- Serial main-actor delegate delivery (B-7) additionally implies: a synchronous
  main-actor region containing no suspension point cannot be interleaved by any engine
  event — the T1 start-up strip (I12) relies on exactly this, nothing more.

Explicitly **not** assumed: that a `stateUpdate` serialization captures `state.add` calls
made before its *delivery* (its snapshot may predate them — which is why seed/delete
intents clear only on *observable* signals, I11/I12); that failed changes remain queued
(the app re-adds them, §5.3); that zone-deletion events reach every device across
delete→recreate or token expiry (the command record is the redundant carrier, §8.3); that
`handleEvent` returning implies durable consumption (applies are durable in-event, §5.0);
that the engine redelivers self-originated changes (§5.3 branch U-save; residual N12);
or any engine-side coalescing of same-id save+delete pairs (§5.4 removes shadowed saves
itself).

Consequences: manual "Sync Now" becomes `fetchChanges()`/`sendChanges()`; the old
`CKRecordZoneSubscription("device-sync-zone-changes")` and the 5-minute throttle are
deleted (D-5).

## 2. Architecture

```
                    ┌───────────────────────────────────────────────┐
                    │ SyncEngineController (@MainActor, owns engine) │
 CKSyncEngine ─────►│  handleEvent(_:)  nextRecordZoneChangeBatch    │
   (private DB,     │  persists: engine state, system-fields cache,  │
    DeviceSync zone)│  processed ids, reset/seed/delete intents      │
                    └───────┬───────────────────────────┬───────────┘
                            │ apply (upserts/deletes)    │ record materialization
                            ▼                            ▼
                    SyncCoordinator (apply-side,   RecordProvider
                    amended merge semantics)       (SwiftData / EmergencyUnblockManager
                            │                       → CKRecord, system-fields cache)
                            ▼
                    SwiftData (ModelContext)
   Locally-originated mutations ──► MutationFunnel ──► bump / tombstone ──► state.add [I2]
```

- **`SyncEngineController`** — new type; sole owner of `CKSyncEngine`; conforms to
  `CKSyncEngineDelegate`; main-actor; events applied serially (B-7). **Construction is
  gated on the `ModelContext` (I10):** created with the context in its initializer, from
  the app entry point where the `ModelContainer` already exists (`FoqosApp` init /
  `didFinishLaunching`; `fatalError`-on-failure, so it exists for background launches
  too). No event can be observed without a context; no buffering machinery exists.
- **`MutationFunnel`** — the one API for every **locally-originated** create/update/delete
  of a synced entity (user action, migration, auto-heal; absorbs #210/#233). Per call:
  - **save path:** (1) bump the entity's version *inside the same persisted write*
    (profiles `syncVersion += 1`, replacing `SyncCoordinator.pushProfile`'s increment;
    locations advance `updatedAt`; emergency settings `emergencySettingsVersion += 1`);
    (2) require the write to succeed; (3) `state.add(.saveRecord(id))`. Saves of
    `isNewerSchemaVersion` profiles are never enqueued.
  - **delete path:** (1) persist a **delete-intent tombstone** (`deleteTombstones[user]`,
    §2.1: id → last-known server change tag from `systemFields`, nil if never synced) *in
    the same `withLock` scope as* — and before returning from — the operation that
    deletes the entity; (2) require the entity delete to succeed — **if it fails, remove
    the tombstone in the same `withLock` scope AND `context.rollback()` the pending
    entity deletion before returning** (round-4/5: a lingering tombstone would later kill
    the live record family-wide; a poisoned context would commit the un-bookkept
    deletion on the next unrelated save). The same rollback rule applies to any thrown
    apply (§5.1/S-30) — a failed write never leaves dirty state to piggyback on a later
    save. **Funnel and apply writes run on the sync paths' own `ModelContext`** (not a shared UI
    context; the funnel receives the already-saved user mutation via its id and re-reads
    it on the sync context — the version bump is part of the funnel's own persisted
    write), so a rollback can never discard unrelated uncommitted user edits (round-6); (3) `state.add(.deleteRecord(id))`. The tombstone carries the user's
    intent; cleared only per I12.
- **`RecordProvider`** — materializes `CKRecord`s for `nextRecordZoneChangeBatch`:
  profiles/locations from SwiftData, emergency settings from `EmergencyUnblockManager`,
  on cached system fields (fresh if none); reuses `toCKRecord`/`updateCKRecord`.
- **Payload equality (§5.1/§5.3):** two synced representations are *payload-equal* iff
  all synced fields match **excluding sync metadata** (`lastModified`, `originDeviceId`,
  system fields). Encoded-`Data` fields (`strategyData`, trigger/schedule blobs) compare
  by **decoded semantic value** where a decoder exists, else by bytes — byte-comparison
  across mixed app builds can demote branch-0 no-ops to branch-E conflict noise (bounded,
  non-destructive; noted). Metadata never participates in conflict decisions
  (materialization stamps `lastModified = Date()`, `originDeviceId = self` —
  `SyncModels.swift:276-277`).
- **Deleted:** `pullProfiles`, `pullLocations`, `pullResetRequests`,
  `pullProfileSessionRecords`, `pullEmergencySettings`, `performFullSync`,
  `deleteAllSyncedData`, `handleRemoteNotification` + throttle, `pushLocalData`,
  `didRequestLocalDataPush`, deletion reconciliation (both handlers), the
  `SyncResetRequest` consume/GC logic, `resetSync`'s wipe, `handleSessionSync`'s
  `.notFound → stopRemoteSession` branch (§6), and the **own-origin apply skip**
  (`if syncedProfile.originDeviceId == deviceId { continue }`,
  `SyncCoordinator.swift:117`) — under version-ruled applies an own echo is an
  equal-version payload-equal no-op, while keeping the skip silently breaks
  restore-from-backup healing (round-3 finding; test S-31). The session-side
  `lastModifiedBy` filter in `applySessionState` stays (it prevents acting on own session
  writes — different mechanism, not absence-based). **No CKQuery remains in the
  private-DB sync path** (I5).

### 2.1 Persisted state

All keys per-`userRecordID` (§7), new unless marked, compound updates under
`SharedData.withLock`:

| Key | Type | Provenance | Written by | Purpose |
|---|---|---|---|---|
| `engineState[user]` | `Data` (`State.Serialization`) | new | `stateUpdate` (§5.0) | engine tokens + pending queues |
| `systemFields[user]` | `[recordName: Data]`, **`SyncedProfile`/`SyncedLocation`/`SyncedEmergencySettings` records only, written only on successful apply/sent-save** (§5.1/§5.3) | new | sent saves; fetched modifications *after* durable apply | change-tag-correct saves. Never stores `ProfileSession` (SessionSyncService owns its CAS cache) or `SyncResetRequest` (never re-sent after supersession) — round-3 finding |
| `processedResetCommandIds[user]` | `Set<UUID>` | new | §8.3 / §8.1 step 1 | identity idempotency; never pruned |
| `resetIntent[user]` | `{id, clear, stage ∈ .deleting/.recreating/.seeding, priorCommandId?}` | new | origin reset machine (§8.1); cleared by completion, T6, T11 (abandonment also dequeues its zone changes) | crash-resumable origin reset |
| `lastAppliedResetCommandId[user]` | `UUID?` | new | §8.3 step 3 (every applied or self-marked command); §8.1 step 1 (own id) | defined provenance for `priorCommandId` snapshots |
| `pendingSeedIntent[user]` | `Bool` | new | every I11 entry point | crash-durable seeding; cleared only per I11's observable rule |
| `deleteTombstones[user]` | `[recordName: changeTag?]` | new | funnel delete path (§2) | crash-durable local deletion intent + verify tag; cleared per I12; **survives T11** |
| `failedApplies[user]` | `Set<{recordName, recordType, op}>` | new | §5.1/§5.2 apply-failure catch | retry carrier for thrown applies (the engine never redelivers); replayed at launch and after each fetch (§5.6) |
| `legacyCleanupDone[user]` | `Bool` | new (pattern: `legacyCleanupKey(for:)`) | §11 one-shot, set when `legacyCleanupIds` empties | idempotency flag for the legacy-cleanup exception |
| `legacyCleanupIds[user]` | `Set<recordName>` | new | §11 one-shot: written durably in the handler that identifies legacy records from the first-bootstrap fetch (§5.0); per-id cleared on §5.3 confirmation (deletedRecordIDs / U-delete / branch F) | implementable carrier for the strip/§5.4 exemptions (pending changes carry no recordType) and for re-enqueueing after a kill |
| `syncEnabled` | `Bool` | existing | UI toggle | engine start/stop |

## 3. Invariants (normative)

- **I1 — No inferred destruction.** Local synced entities are deleted, selections
  cleared, or sessions stopped only by (a) explicit fetched events naming them, (b) a
  current-incarnation command with the flag (§8.3), or (c) direct user action. Zone
  deletions, empty fetches, account changes, token resets, and record absence never
  destroy anything. **Corollary (round-3): no *outbound* delete is ever enqueued from
  inferred state either — only the funnel (user intent), I12 tombstone recovery, and the
  §11 legacy-cleanup one-shot (scoped to `recordType == LegacySyncedSession`) produce
  `.deleteRecord` changes. (§5.6's `.delete` path is a *local* apply of an explicit
  fetched event; it never enqueues an outbound delete.)**
- **I2 — Single funnel for locally-originated mutations.** Every locally-originated
  mutation flows through `MutationFunnel` (bump/tombstone + enqueue in one operation).
  Remote applies write versions verbatim and never bump/enqueue, **except** the
  enumerated conflict sites: the I9 auto-heal re-push, the §5.1 equal-version
  payload-differing rule, and the §5.3 branch-E re-add. Exclusivity: CI/grep — for data
  entities, `state.add(pendingRecordZoneChanges:` appears only in `MutationFunnel`, the
  §5.3 re-add sites, the §5.1 conflict-bump site, I11/I12 recovery, §8.1 step 4 (command
  record), and the §11 legacy-cleanup one-shot (§5.6 never enqueues — its `.delete` path
  is a local apply). Tests S-15, S-27.
- **I3 — Command idempotency by identity** (no date arithmetic in idempotency/safety).
- **I4 — Apply-before-mark** for command application (§8.3); origin pre-mark carve-out
  (§8.1 step 1) is safe via §8.3's independent `originDeviceId == self` check.
- **I5 — No queries** in the private-DB sync path; CI/grep + review.
- **I6 — Zone events reset bookkeeping, not data:** purge `systemFields[user]`, flush
  `SessionSyncService`'s cache. Local entities, tombstones, processed ids untouched.
  Account changes purge nothing (§7).
- **I7 — Engine state is authoritative for the queue.** Seeding only on I11 transitions;
  ordinary relaunch enqueues nothing except I11/I12 *recovery* of persisted intents
  (S-19 scoped accordingly).
- **I8 — Conflicts merge, never drop silently.** Every failed save-or-delete outcome
  lands in exactly one §5.3 branch: adopt (branch 0, or branch C's server-wins merge) /
  re-enqueue (local-wins, Z, U-save, R) / re-enqueue-with-bump-and-surface (branch E) /
  skip-for-pending-delete (branch C, tombstoned id) / remove (F: surfaced; U-delete:
  silent, already satisfied). Payload-equal collisions are silent by design. Tests S-10,
  S-17, S-23.
- **I9 — Schema-version gate preserved** (fetch-apply and `serverRecordChanged`): newer
  schema ⇒ mark-read-only, never clobber; older ⇒ reject + auto-heal via I2. Test S-18.
- **I10 — Context-gated engine.**
- **I11 — (Re)creating the zone implies re-seeding, crash-durably.** Entry points: T1
  first bootstrap; T5; §8.1 step 4; §8.3; §5.3 branch Z. Each **first persists
  `pendingSeedIntent`** (same `withLock` scope as whatever consumes its trigger), then
  enqueues `saveZone` + save-all-restorable (profiles excluding `isNewerSchemaVersion`;
  locations; the emergency-settings record; not sessions — §6/N13). **Clearing is an
  optimization and uses only observable signals:** clear after (a) every seed-batch
  change has been observed sent (§5.3/§5.5 saved) or terminally resolved (§5.3 branches
  F/U, §5.4 removal) **and** (b) at least one `stateUpdate` has been persisted after (a).
  A kill at any point leaves the intent set; launch with it set re-runs purge + seed
  (idempotent — the engine deduplicates pending changes; collisions no-op via §5.3
  branch 0). Never cleared on an assumption about serialization capture (round-3: that
  property is not granted — see §1.1). Tests S-8, S-19, S-28.
- **I12 — Delete tombstones carry deletion intent to completion.** Written (with the
  record's last-known server change tag) by the funnel delete path (§2). **Recovery** at
  controller start (mid-session I6 events need none: a live process's pending deletes
  survive the purge — I6 touches `systemFields`/session cache only), for each tombstoned
  id with no pending `.deleteRecord`:
  - entity still present locally ⇒ the local delete never completed — **abort**: clear
    the tombstone, enqueue nothing, log (fail-toward-keep, E-3; the UI reported the
    delete failed and the entity is still the user's);
  - entity absent, **fresh intent** (tombstone written by the current process instance)
    ⇒ enqueue the delete;
  - entity absent, **recovered intent** (any tombstone found at controller start) ⇒
    **verify-before-delete**: fetch the record by `CKRecord.ID` (a record fetch, not a
    query — I5-compatible): absent ⇒ intent already complete, clear; present with
    matching stored change tag ⇒ enqueue the delete; present with a different tag or no
    stored tag ⇒ re-adopted since this device's state was snapshotted (e.g. an N9/N5
    re-seed) — clear the tombstone, surface a conflict entry, **do not delete**;
    `zoneNotFound` or transient fetch error ⇒ keep the tombstone; the retry re-runs on the
    §5.6 cadence within the session (recovery is *initiated* at controller start; its
    retries are not start-only) — never silently drop a genuine intent. Change tags are
    server-assigned — clock-immune. The verify is advisory (CloudKit deletes are
    unconditional by recordID): its residual window equals the ordinary fresh-intent
    delete-vs-edit race, because a *true re-adoption* requires the prior deletion to
    have completed, which forces absent-or-different-tag at verify time.
  **Cleared when:** confirmed (§5.3 `deletedRecordIDs`); terminally resolved (U-delete);
  a fetched deletion for the id arrives first (§5.2 — intent satisfied); permanently
  abandoned (branch F, surfaced); or recovery aborts it (entity-present / re-adopted).
  **At controller start, in the same synchronous main-actor region as engine init
  (AB-4; containment nets per §1.1 if it ever fails), the strip removes ALL pending
  `.deleteRecord`s (except `legacyCleanupIds` members) AND all pending database changes
  (`deleteZone`/`saveZone`) from the restored engine state** — a
  restored serialization may be a backup-consistent stale pair, and database changes
  have no delegate chokepoint gating their send (round-6: an orphaned restored
  `deleteZone` would replay a zone reset with no command ever published). Record deletes
  are then re-enqueued only via the recovery case-split above; zone changes only via
  `resetIntent` stage resume (§8.1) after its gate passes or via I11 seeding's
  `saveZone` (a zone *save* is idempotent and harmless to replay; only `deleteZone` is
  intent-gated) — `resetIntent` is the sole source of truth for **zone** changes, tombstones for record
  **deletes**, and `pendingSeedIntent`/funnel state for record **saves** (each intent
  class re-derives exactly its own stripped changes). Tombstones are the sole source of truth for deletes; §5.4
  additionally refuses to materialize any `.deleteRecord` without a live tombstone
  (exempting §11 legacy cleanup). Tombstones survive
  T11 and account switches (per-user). The v3 §5.6 absence-sweep is **deleted** — it was
  inference. Tests S-29, S-32, S-33.

## 4. State machine

States: `Disabled` → `Bootstrapping` → `Steady`; `OriginReset(stage)`; `Purged`.

| # | From | Event | To | Actions |
|---|------|-------|----|---------|
| T1 | Disabled | sync enabled (toggle or launch with `syncEnabled`) | Bootstrapping | create controller (I10); **init engine with `engineState[user]`, then in the same synchronous main-actor region strip all restored pending `.deleteRecord`s (except `legacyCleanupIds`) AND all pending database changes (I12, AB-4)**; then: I12 verify-and-re-enqueue recovery; §5.6 retry; re-enqueue remaining `legacyCleanupIds` if flag unset (§11); **at most one of**: `engineState[user] == nil` ⇒ set `pendingSeedIntent` then I11 seed, else `pendingSeedIntent[user]` set ⇒ re-run I6 purge + I11 seed (crash recovery), else no seed (ordinary relaunch, S-19); iff `resetIntent[user]` set ⇒ resume per §8.1 from `stage` (`.deleting` runs the gate first); `fetchChanges()` (scheduled outside any handler) |
| T2 | Bootstrapping | `didFetchChanges` | Steady | none |
| T3 | any enabled | `fetchedRecordZoneChanges` | same | §5.1/§5.2 |
| T4 | any enabled | `sentRecordZoneChanges` | same | §5.3 |
| T4b | any enabled | `sentDatabaseChanges` | same | §5.5 |
| T5 | any enabled | **DeviceSync**-zone deletion `.deleted`/`.encryptedDataReset` | same | I6 purge; I11 seed (intent-first). No dedicated resume state; `pendingSeedIntent` + §8.3 cover kills |
| T6 | any enabled | **DeviceSync**-zone deletion `.purged` | Purged | I6 purge; discard `engineState[user]`; clear `resetIntent` + `pendingSeedIntent` (tombstones survive — deletion intent is not consent-scoped); `syncEnabled = false`; one-time notice. Explicit re-enable = fresh consent → T1 |
| T7 | any | `accountChange` | Disabled → T1 for new user if enabled | stop engine; **invalidate in-flight async continuations** (I12 verifies, §5.6 refetches — each re-checks the active namespace + enabled flag before acting); purge nothing; switch namespace (N11) |
| T8 | Steady | user taps Reset Sync | OriginReset(.deleting) | §8.1 |
| T9 | OriginReset(*) | per-stage confirmation | next stage / Steady | §8.1; resume from `stage` at relaunch |
| T10 | any | `stateUpdate` | same | persist serialization (safe for fetch tokens per AB-2; seed/tombstone intents do **not** key off this — I11/I12) |
| T11 | any enabled | sync disabled | Disabled | clear `resetIntent` + dequeue its zone changes **first**, and clear `pendingSeedIntent`; then best-effort final `sendChanges()` (an N5 mitigation for pending record saves, never for mid-reset zone ops); stop engine; invalidate in-flight async continuations (as T7); discard `engineState[user]` (pending unsent **saves** lost — N5); **`deleteTombstones` survive** — local deletions re-propagate at re-enable via I12 |

Notes: `didFetchChanges` after T2 recurs on every fetch cycle — it drives the §5.6
retry sweep and the echo-guard drain check (no dedicated T-row; handled in §5.1/§5.6
prose). T3/T4/T4b's "same" refers to the top-level state only — `resetIntent.stage`
progression (T9/§8.1) is an orthogonal dimension evaluated inside the same handlers.
T5 *may* fire on the origin too (its own zone deletion echoing back — engine behaviour
not in the AB list and deliberately not relied on either way): if it does, it is a safe
duplicate of the in-flight §8.1 sequence — purge is idempotent, seed collisions no-op
via branch 0; if it does not, §8.1's own steps perform the same actions.
`syncEnabled` is deliberately **global** (pre-existing single key, not per-account): T7's
"if enabled" reads it; a user who enabled sync keeps it enabled across account switches.

## 5. Event handling contract

### 5.0 Durability ordering

Within `handleEvent`, applies (SwiftData saves, `systemFields` writes conditional on
those saves, processed-id marks, intent writes) complete before the handler returns.
`stateUpdate` serializations are persisted in their handler (safe for fetch progress per
AB-2). Seed/tombstone intents never rely on serialization capture (I11/I12).

### 5.1 Fetched modifications

Route by `recordType`: `SyncedProfile` → profile upsert (incl. `needsAppSelection =
true` on create — E-1 semantics preserved verbatim); `SyncedLocation` → location
upsert (client-clock merge kept verbatim; N6); `ProfileSession` → `applySessionState`;
`SyncedEmergencySettings` → versioned apply; `SyncResetRequest` → §8.3;
`LegacySyncedSession` (while `legacyCleanupDone` unset — state-independent, any fetch
cycle) → record its id into `legacyCleanupIds` + enqueue its delete (§11) — never
applied locally.
Other unknown types **or undecodable payloads**: log, ignore (a known-type record whose payload cannot decode
— including a command with no readable `requestId` — is inert; it dies with its zone).

Per-type meaning of "version" and "bump" throughout §5.1/§5.3: profiles —
`syncVersion` / `+= 1`; locations — `updatedAt` ordering / advance-to-now (client clock;
N6); emergency settings — `emergencySettingsVersion` / `+= 1`. Branch 0/E apply to all
three.

Amendments and rules (each deliberate, each tested):

- **Own-origin records are applied**, not skipped (§2 deletion list; S-31). Version rules
  make own echoes no-ops and let a restored-from-backup device heal forward.
- **Pending-delete-wins:** a modification whose id has a pending `.deleteRecord`, a live
  tombstone, **or an entry in the in-memory confirmed-delete echo guard** is skipped.
  The echo guard (`recentlyConfirmedDeletes`, in-memory only) is populated when §5.3
  `deletedRecordIDs` confirms a delete; a guarded id is skipped **only when the
  delivering fetch cycle started before the confirmation** (AB-3 delimiters), and the
  guard drains at the *start* of the first cycle beginning after the confirmation — such
  a cycle reads post-delete server state, so a modification it delivers is a genuine
  branch U-save recreation and must apply (round-5: draining at cycle *completion*
  swallowed exactly those recreations). In-memory suffices: across a relaunch, any fetch
  re-runs against post-delete state. (S-32, S-34.)
- **Equal-version divergence:** incoming version == local, not payload-equal ⇒ conflict
  now: bump (`syncVersion += 1`), enqueue, surface a conflict entry (I2 exception).
  Payload-equal ⇒ no-op.
- **`systemFields` are stored only after the entity's durable local apply succeeds**, and
  only for `SyncedProfile`/`SyncedLocation`/`SyncedEmergencySettings` (§2.1; round-3:
  unconditional storage armed the deleted sweep's false positives). Test S-30.
- **Apply failures roll back their context** (no dirty state survives a thrown apply;
  §2) **and are persisted for retry (§5.6):** if an apply throws, record
  `{recordName, recordType, .upsert}` into `failedApplies[user]` in the same handler —
  the engine never redelivers, so "heals via a later fetch" is false for a record that
  never changes again (round-4). Same rule in §5.2 for thrown deletion applies
  (`.delete`).

### 5.2 Fetched deletions

The only remote-driven local deletion path (I1). By `recordType`: profile → delete
local; location → delete local; `ProfileSession` → stop matching remote-started session
(#203); command/legacy/unknown → no-op. Absent locally → no-op. Drop the `systemFields`
entry; clear a matching tombstone **and `state.remove` any pending `.deleteRecord(id)`**
(the deletion happened — intent satisfied; an orphaned outbound delete would later kill
a branch U-save recreation; round-5); if a pending save exists with no local entity,
`state.remove` it (§5.4).

### 5.3 Sent record changes

`savedRecords` → update `systemFields` (scoped types only). `deletedRecordIDs` → drop
`systemFields` entries **and clear matching tombstones** (I12).

The engine does not retain failed changes; the app re-adds them. Branches (named to
avoid ordinal collisions — round-3 nit):

- **Branch C (`.serverRecordChanged`):** `SyncResetRequest` conflicts are handled
  entirely by §8.1 step 5, never here (commands have no version field). For data
  records: unless the tombstoned sub-branch applies (then store nothing), store
  `error.serverRecord`'s system fields first (scoped types); merge via §5.1 rules
  (no-op on local fields when local is strictly newer; I9 applies); then exactly one of:
  - **branch 0** — equal version, payload-equal: adopt server tag; no re-add; silent;
  - server strictly newer: merged; no re-add;
  - local strictly newer: re-add `.saveRecord(id)`;
  - **branch E** — equal version, payload-differing: bump (per-type, §5.1), re-add,
    surface a conflict entry. One loser per server round; converges;
  - **tombstoned / pending-delete id:** skip the merge (§5.1 pending-delete-wins), store
    nothing, re-add nothing — the pending `.deleteRecord` carries the intent.
- **Branch Z (`.zoneNotFound`):** enqueue `saveZone`; I11 seed (intent-first); re-add
  the failed change — saves and deletes alike (a re-added delete resolves via branch
  U-delete after recreation, clearing its tombstone). (`zoneNotFound` is authoritative;
  transient errors surface as branch R codes.)
- **Branch U-save (`.unknownItem` on save):** drop the `systemFields` entry; re-add as
  create. A fetched deletion arriving first wins (§5.2/§5.4). Reverse ordering: N12.
- **Branch U-delete (`.unknownItem` on delete):** done; drop the `systemFields` entry
  **and clear the tombstone** (round-3: otherwise the id re-enqueues every launch).
- **Branch R (retriable):** re-add once per failure event (honour `retryAfterSeconds`).
- **Branch F (non-retriable):** remove permanently; log; surface a conflict entry (I8).
  For a tombstoned delete, also clear the tombstone (surfaced, not looping).

### 5.4 `nextRecordZoneChangeBatch`

Materialize on cached system fields (fresh if none), filtered by
`context.options.scope`. Pending save with entity absent locally: **remove it** (a
pending or tombstoned delete carries the intent; an unmaterializable save must never be
skip-and-retained). Same removal for pending saves of `isNewerSchemaVersion` profiles.
**Any `.deleteRecord` without a live tombstone is removed from the pending queue, not
materialized** (defence in depth for I12's source-of-truth rule; refuse = remove, never
skip-and-retain; §11 legacy-cleanup deletes exempt).

### 5.5 Sent database changes

`savedZones` → confirmed. `failedZoneSaves`: zone-already-exists class → counts as
confirmed; retriable → re-add and rely on the engine's own scheduling/backoff for the re-send
(no explicit `sendChanges()` — it would need `retryAfterSeconds` handling and is a
latency optimization at best; any explicit request elsewhere is always scheduled in a
`Task` after the handler returns, never from within `handleEvent` — §1.1 prohibition);
non-retriable → surface, keep `resetIntent`. `deletedZoneIDs` → confirmed; `failedZoneDeletes` `.zoneNotFound` →
confirmed; retriable → re-add.

### 5.6 Failed-apply retry

At controller start and after each completed fetch cycle, for each `failedApplies[user]`
entry, **verify then re-apply** (a persisted failed event is stale evidence and gets the
same treatment as every other replayed intent):
- `.delete` ⇒ fetch by `CKRecord.ID`: absent/`.unknownItem` ⇒ apply the local deletion,
  clear; **present ⇒ the record was re-created since (branch U-save) — drop the entry,
  do not delete** (round-5);
- `.upsert` ⇒ fetch by `CKRecord.ID` and re-run the §5.1 apply; clear on success or
  `.unknownItem`; a retry skipped by pending-delete-wins or the echo guard retains its
  entry and drains on a later cycle (bounded: the delete confirms → `.unknownItem`, or
  the guard drains → the apply runs).
**Supersession rule:** any *successful* §5.1 apply (modification or deletion) for a
recordName clears that record's `failedApplies` entry — a later explicit event always
supersedes an older failed one. Entries per-user, `withLock`-updated, bounded by
distinct failing records. Tests S-35.

## 6. Sessions (CAS coexistence)

Session writes stay on `SessionSyncService`, with one amendment: `stopSession`'s
`.notFound` branch, when this device believes a session for that profile is (or was)
active, **writes a stopped record** (create-if-absent, `isActive = false`, fresh
sequence). **On `serverRecordChanged` during that create** (a concurrent fresh start won
the race): do not blind-overwrite — refetch; a newer active session supersedes the stale
stop (treat as `.alreadyStopped`); test S-24 covers both orderings. Session propagation
is §5.1/§5.2 events only; the `.notFound → stopRemoteSession` polling branch is deleted
(I1). `SessionSyncService` must (a) flush its cache on I6 (S-20) and (b) treat its first
CAS save after zone recreation as create-if-absent (S-21). Session records are not in
the I11 seed set and **never enter `systemFields`** (§2.1); the post-reset
session-discovery gap is N13.

## 7. Account scoping (D-3)

All §2.1 keys namespaced by `userRecordID.recordName`. `accountChange` stops the engine
and switches namespace, purging nothing. Tombstones are per-user: a deletion applied
under account B's namespace clears only B's state, and account A's I12 tombstone
recovery can only re-enqueue deletes A's *own funnel* recorded — the round-3
cross-account manufactured delete is impossible (no tombstone, no delete). UUID command ids are
cross-account-collision-proof. The local data store is account-agnostic — union residual
N11.

## 8. Reset Sync, re-designed

Reset means: *this device's data becomes the new seed; other devices keep local data,
optionally clear app selections, and re-upload.* Two redundant carriers: the
zone-deletion event (T5, fast path) and the command record (§8.3, guaranteed path,
crash-durable via `pendingSeedIntent`).

### 8.1 Origin sequence (crash-resumable via `resetIntent.stage`)

1. Persist `resetIntent = {id: UUID(), clear: flag, stage: .deleting,
   priorCommandId: lastAppliedResetCommandId[user]}` (§2.1 — written by §8.3 whenever a
   command is applied or marked, and by this step for the own id; nil on a family with
   no reset history known to this device); mark `id` into
   `processedResetCommandIds` and set `lastAppliedResetCommandId = id` (I4 carve-out).
2. Enqueue `deleteZone(DeviceSync)`; `sendChanges()`.
3. On delete confirmed (§5.5; `.zoneNotFound` counts): I6 purge; `stage = .recreating`;
   enqueue `saveZone`.
4. On zone-save confirmed (§5.5): `stage = .seeding`; enqueue the command record + I11
   seed (intent-first).
5. On the command save confirmed (§5.3 `savedRecords` — the command's tag is **not**
   stored, §2.1): clear `resetIntent`. On `.serverRecordChanged` for the command save,
   read `error.serverRecord`: foreign `requestId` ⇒ superseded — drop the pending save,
   clear `resetIntent`, **surface a conflict entry** (the user's reset did not run —
   same surfacing as the resume gate's abandon arm); own `requestId` ⇒ the earlier save
   succeeded — confirmed, clear `resetIntent`; undecodable ⇒ treat as foreign (incl.
   the surfacing).

Crash at any stage resumes from `stage` (resume re-enqueues; the engine deduplicates) —
**except**: a resume of stage `.deleting` found at controller start first **fetches the
command record directly by `CKRecord.ID("sync-reset-command")`** (a record fetch, not a
query — I5-compatible, and independent of §8.3's processed-guard, so every outcome is
observable). Total case-split:
- `requestId == resetIntent.id` ⇒ our command already published — treat as step-5
  confirmed, clear the intent;
- `requestId == priorCommandId`, **or no command exists (any snapshot), or the gate
  fetch returns `zoneNotFound`** ⇒ prior incarnation's state, or a zone that
  died/was T5-reseeded without a command — ⇒ resume normally (a genuinely newer reset
  either published a command, hitting the next arm, or is itself mid-`.deleting`, in
  which case the racing resets serialize at the zone delete/recreate CAS and the command
  CAS — whichever command publishes last wins, N1/N3);
- foreign and different from both ⇒ superseded (or a concurrent reset won) ⇒ abandon
  **and surface to the user** (the requested reset did not run);
- undecodable ⇒ abandon + surface (mirrors step 5; conservative, and the undecodable
  command is inert everywhere per B-5);
- transient fetch error ⇒ keep the intent, retry at next start/§5.6 cadence.
Zone changes for a resumed stage are re-enqueued only after this gate passes (the T1
strip removed the restored ones).
**Abandoning `resetIntent` without completion — here, at step 5 supersession, or at
T6/T11 — also `state.remove`s any `deleteZone`/`saveZone` database changes it enqueued**
(round-5: an orphaned restored `deleteZone` otherwise fires with no command ever
published). A zone-delete confirmation arriving with `resetIntent == nil` is handled as
T5 (purge + intent-first seed). The residual backup replay when the current command
matches the snapshot (or none exists) is N14. Failure before step 3 confirms is a no-op.

### 8.2 The command record (fixed name)

One per zone incarnation: `recordType = SyncResetRequest`,
`recordName = "sync-reset-command"`, fields as today. Supersession is a
server-serialized CAS; no multi-command ordering exists; never stored in `systemFields`.

### 8.3 Command application (any device)

On a fetched modification of the command record: **always set
`lastAppliedResetCommandId = requestId` first** (the fetched fixed-name record is by
definition the current incarnation's command; stale redelivery is unreachable under the
engine's token model). Then: `requestId ∈ processed` → ignore; `originDeviceId == self`
→ mark, ignore; else, in order:
1. persist `pendingSeedIntent`;
2. if `clearRemoteAppSelections`, clear selections on all local profiles and save;
   regardless of the flag, I6 purge + I11 seed (the redundant re-seed carrier);
3. mark `requestId` processed and set `lastAppliedResetCommandId[user] = requestId`
   (I4; §2.1 provenance).
A kill anywhere is recovered: before step 3, the command redelivers and re-applies
idempotently; after step 3, `pendingSeedIntent` re-runs purge + seed at launch.
Re-seeding after T5 already ran is idempotent (branch 0).

### 8.4 Non-origin zone-deletion handling (T5)

Keep all local data (I1); I6 purge; I11 seed (intent-first). No dedicated resume state.
If the origin died at `.deleting` and no command exists: the first T5 observer's seed
recreates the zone; devices that saw neither signal self-heal via §5.3 branch Z on their
next local edit — residual N7.

### 8.5 Product decisions (deliberate, no live users)

- The origin no longer clears its own selections (resolves E-2 per shipped alert copy).
- `.purged` disables sync instead of re-seeding (T6).

## 9. What replaces the old guards

| Old mechanism | Fate |
|---|---|
| Deletion reconciliation (profiles + locations) | deleted; §5.2 explicit events |
| `remoteIds.isEmpty` guard | deleted |
| `syncVersion > 0` deletion eligibility | deleted; `syncVersion` = merge ordering only, funnel-bumped |
| `pushProfile` version increment | moved into `MutationFunnel` (I2) |
| Own-origin apply skip (`SyncCoordinator.swift:117`) | deleted (§2, S-31); version rules subsume it |
| 5-min notification throttle | deleted (#200) |
| `SyncResetRequest` consume/skip/GC | fixed-name command + identity application (§8.2/8.3) |
| Blanket every-pass `pushLocalData` | deleted; I11 transitions only (S-19) |
| `handleSessionSync` `.notFound→stop` | deleted (§6); `stopSession` `.notFound` writes a stopped record |
| v3 §5.6 absence sweep | deleted; replaced by I12 delete-intent tombstones |
| Legacy subscription + `LegacySyncedSession` cleanup | one-shot at first bootstrap |

## 10. Named test scenarios (implementation must ship these)

Mocked engine protocol + `TestModelContainer`; pinned `now` where dates appear.

- **S-1** fetched deletion deletes exactly that local profile; clears tombstone if one
  matches (E-4, I12).
- **S-2** empty fetch ⇒ zero local mutations.
- **S-3** zone deletion `.deleted` ⇒ data intact; purge; intent-first seed (T5).
- **S-4** `.purged` ⇒ data intact; sync disabled; engine state discarded;
  `resetIntent == nil ∧ pendingSeedIntent == nil`; tombstones intact; nothing enqueued.
- **S-5** command applied once; same-id redelivery no-op (I3).
- **S-6** kill between apply and mark ⇒ idempotent re-apply (I4).
- **S-7** controller cannot exist without a context (I10); applies durable in-event.
- **S-8** command application: purge + seed regardless of clear flag; order
  intent → apply → mark (§8.3).
- **S-9** own-origin command ⇒ marked, never applied; origin pre-mark (§8.1 step 1).
- **S-10** branch C (I8): tag stored first (scoped types); branch 0 adopt-silent;
  server-wins; local-wins re-add; branch E bump + re-add + conflict entry; re-sent save
  carries the fresh tag; I9 through this path (with S-18).
- **S-11** branch Z ⇒ saveZone + intent-first seed + change re-added.
- **S-12** account switch ⇒ neither namespace purged; switch-back resumes (T7/§7).
- **S-13** origin resume from each stage; command-save `serverRecordChanged` with
  foreign / own / undecodable `serverRecord` (§8.1 step 5).
- **S-14** newer-schema profile: never enqueued; stray pending save removed; fetched
  deletion still applies.
- **S-15** funnel save path bumps version in the same write, enqueues exactly once;
  failed write ⇒ no bump, no enqueue. Funnel delete path writes the tombstone (with
  change tag) in the same `withLock` scope, enqueues exactly once; **failed entity
  delete ⇒ tombstone removed before returning, nothing enqueued** (I2, I12).
- **S-16** edit round-trip: funnel-bumped edit on A applies on B; an edit bypassing the
  funnel (no bump) must not propagate — the locked-in regression.
- **S-17** branch R re-added exactly once per failure event; branch F removed + conflict
  entry (+ tombstone cleared for deletes); no loop (I8).
- **S-18** schema-version gate (I9): fetch-apply and branch C.
- **S-19** relaunch with existing `engineState`, `resetIntent == nil`,
  `pendingSeedIntent == nil`, no tombstones ⇒ zero enqueues (I7/I11/I12).
- **S-20** I6 flushes session cache. **S-21** first CAS save post-recreation is
  create-if-absent.
- **S-22** session stop propagates via fetched modification; session-record absence
  never stops anything (I1).
- **S-23** branch U-save ⇒ tag dropped, re-added as create; interleaved fetched deletion
  wins.
- **S-24** stop-on-absent creates a stopped record and the mirror stops; on
  `serverRecordChanged` vs a concurrent fresh start, the stop yields (§6).
- **S-25** AB-1: `saveZone` sends before seeded record saves.
- **S-26** AB-2: kill after a `stateUpdate` interleaved between two fetch events ⇒ the
  second event's changes re-delivered on relaunch.
- **S-27** fetched modification applied ⇒ zero pending changes, version verbatim (I2);
  §5.1 equal-version payload-differing ⇒ bump + enqueue + conflict entry; payload-equal
  ⇒ pure no-op.
- **S-28** kill after `pendingSeedIntent` persisted, before the observable clear
  condition ⇒ launch re-runs purge + seed; the intent clears only after every seed change
  is observed sent/resolved plus one subsequent persisted `stateUpdate` (I11).
- **S-29** tombstone lifecycle (I12): funnel delete ⇒ tombstone + enqueue; kill before
  enqueue capture ⇒ launch re-enqueues (fresh-intent path); confirmed delete / U-delete /
  §5.2 fetched deletion / branch F ⇒ tombstone cleared (no every-launch loop);
  **negative cases:** session records, the command record, and failed-apply records
  never produce outbound deletes; tombstone-present + entity-present ⇒ recovery aborts;
  restored pending deletes stripped at start; §5.4 refuses tombstone-less
  `.deleteRecord`s (legacy cleanup exempt); recovered-verify transient error ⇒ tombstone
  kept and retried.
- **S-30** fetched create whose `context.save()` throws ⇒ no `systemFields` entry, no
  tombstone, no outbound effect (§5.1).
- **S-31** own-origin fetched record: newer version applies (restore-from-backup heals);
  equal-version payload-equal echo is a no-op; branch C with own-origin `serverRecord`
  merges normally (§2).
- **S-32** fetched modification for a tombstoned/pending-delete id is skipped
  (pending-delete-wins, §5.1); the delete then propagates.
- **S-33** verify-before-delete (I12 recovered intents): recovered tombstone, record
  absent ⇒ cleared; matching tag ⇒ delete enqueued; different/missing tag ⇒ cleared +
  conflict entry, no delete (restored-backup replay guard).
- **S-34** confirmed-delete echo guard: a modification delivered by a cycle that
  *started before* the confirmation is skipped; one delivered by a cycle started *after*
  it applies (genuine recreation); the guard drains at that cycle's start (§5.1, AB-3).
- **S-35** failed-apply retry (§5.6): thrown upsert ⇒ entry ⇒ refetch + re-apply;
  thrown deletion ⇒ verify-by-fetch — absent ⇒ applied + cleared, **present ⇒ dropped,
  never deleted**; a later successful apply for the id clears the entry (supersession).
- **S-36** `.deleting`-stage resume gate (direct record fetch), all five arms: own id ⇒
  confirmed; == `priorCommandId`, **no command (any snapshot)**, or `zoneNotFound` ⇒
  resume; foreign ⇒
  abandoned + surfaced + zone changes dequeued; undecodable ⇒ abandoned + surfaced;
  transient error ⇒ intent kept, retried. Zone-delete confirmation with
  `resetIntent == nil` handled as T5 (§8.1).
- **S-37** AB-3: cycle delimiters observable; `didFetchChanges` implies that cycle's
  record events were delivered (mocked).
- **S-38** T1 strip + AB-4 (mocked): no send of restored pending changes occurs between
  engine init and the end of the strip's synchronous main-actor region; a restored
  `deleteZone` with `resetIntent == nil` is removed and never sent; zone changes
  re-enqueue only after the stage gate; `legacyCleanupIds` members survive the strip and
  re-enqueue while the flag is unset; kill mid-legacy-cleanup ⇒ ids persist and complete
  on relaunch (§11).
- **Manual two-device checklist** (in the PR): reset with/without clear-selections;
  concurrent edit; delete-vs-edit race both orderings; device offline across a reset;
  token-expired device across a reset; active session across a reset incl.
  stop-on-absent both orderings; purge; account switch and back; toggle off → local
  delete → on (delete propagates via tombstone, N5); toggle off → remote delete → on
  (resurrects, N5); restore-from-backup then edit (S-31 path).

## 11. Migration & rollout

No live users: no compatibility shims. First launch: T1 first bootstrap seeds and
full-fetches; a legacy random-name `SyncResetRequest` record applies at most once by id
(§8.3). The **legacy-cleanup one-shot** (gated by `legacyCleanupDone[user]`, §2.1, **set only
when `legacyCleanupIds` empties** (per-id removal on §5.3 `deletedRecordIDs`/U-delete
confirmation or a surfaced branch-F abandonment — resolved, not necessarily deleted) —
so a kill
before the sends cannot strand the cleanup behind the flag; its pending deletes are
exempt from the T1 strip and §5.4 **by membership in `legacyCleanupIds`** — pending
changes carry no recordType, so the persisted id set is the only implementable carrier;
T1 re-enqueues any remaining ids after the strip while the flag is unset) removes the old
`device-sync-zone-changes` subscription and deletes `LegacySyncedSession` records — an
**explicitly enumerated exception** to I1's corollary and I2's grep whitelist, scoped to
`recordType == LegacySyncedSession`; it identifies the records from the first
bootstrap's full fetch (no CKQuery — I5 holds). Mixed old/new
builds unsupported (noted in the PR).

## 12. Honest residuals

- **N1** — a device offline across two back-to-back resets applies only the surviving
  command (last reset wins).
- **N2** — `.purged` is observed device-by-device.
- **N3** — concurrent resets: bounded re-seed churn until the CAS-surviving command
  settles; branch-0 no-ops; converges. Mixed-build byte-unequal blobs can demote some
  branch-0 no-ops to branch-E noise (§2 payload equality) — bounded, non-destructive.
- **N4** — engine scheduler latency is unbounded; nothing lost, immediacy not promised.
- **N5** — toggle-off/on is union-merge rejoin **for saves**: T11 discards pending
  unsent *saves* (recovered by the T1 rejoin seed at re-enable), and records deleted
  *remotely* during the disabled window are re-uploaded by the rejoin seed. Local
  *deletions* are **not** lost: tombstones survive T11 and re-propagate via I12 at
  re-enable — as recovered intents they are verify-before-delete'd, so they propagate
  iff the record was not remotely modified during the disabled window (else: cleared +
  surfaced, keep-biased). Deliberate keep-biased change from the old rejoin
  (which pull-reconciled deletions before pushing).
- **N6** — location merge is client-clock-ordered (inherited; non-destructive; #218/#221).
- **N7** — origin dead at `.deleting` + nobody observes the deletion + nobody edits ⇒
  dormant, data intact, until any of those occurs.
- **N8** — a kill between a funnel **save**-enqueue and its send orphans that enqueue;
  recovered by the next edit of that entity. **Deletes are exempt** (I12 tombstones).
- **N9** — any reset resurrects deletions not yet fetched by every device at zone-death
  (husk family-wide). Precondition: any device lagging a deletion when a reset lands.
- **N10** — record deletions are unrecoverable across change-token expiry (nil-token
  refetch cannot express deletions; I1 keeps stale local copies; later seeds can
  resurrect them as husks). Tombstones do not help — they cover *this device's own*
  deletions, not un-received foreign ones. Practical bound: token lifetime vs. dormancy.
- **N11** — the local store is account-agnostic: switching accounts unions data across
  private DBs over time (pre-existing class; product follow-up if isolation is wanted).
- **N12** — delete-vs-edit recreation races, both sides: (a) a branch U-save re-created
  record landing before the deletion event is fetched leaves transient divergence on the
  re-creating device; (b) on the *deleting* device, a recreation landing between the
  server-side delete and its confirmation can be delivered by a cycle the echo
  guard/tombstone still covers and be skipped. Both transient, keep-biased server-side,
  healed by any later edit/seed of the record (engine self-change redelivery not
  assumed).
- **N13** — ongoing sessions' records die with the zone at a reset; mirrors keep running
  (I1); stops propagate via §6; a device coming online mid-window cannot discover a
  still-active session until the owner's next CAS write.
- **N14** — a device restored from a backup taken while an origin `resetIntent` was
  live can replay that reset: `.deleting` replays iff the gate's fetched command matches
  `priorCommandId` or none exists (an own-id match is treated as already-completed — no
  replay); `.recreating`/`.seeding` replay their remaining steps unconditionally,
  bounded by the command CAS. I.e. replay requires that no newer reset intervened
  (§8.1 resume rule). Effects are within reset semantics (data survives, N9/N13 apply;
  selection-clear per the restored flag) but unrequested by any current user.
  Precondition: backup captured in the intent-live window ∧ restore ∧ no intervening
  reset. Delete-intent replay from restored backups is, by contrast, **guarded**
  (verify-before-delete, I12/S-33).

## 13. Out of scope / follow-ups

- Shared-DB FamilyCommand/lock-code channel (B2).
- #218/#221 merge-policy refinements (incl. N6).
- `cloudkit-schema.ckdb` drift (pre-existing).
- Settings sync-section UI beyond §8.5.
- Account-scoped local data (N11).
