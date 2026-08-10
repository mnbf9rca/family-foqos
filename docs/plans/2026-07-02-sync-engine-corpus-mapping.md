# #267 corpus mapping — every A1 scenario under the CKSyncEngine design (v9)

Normative companion to `2026-07-02-sync-engine-design.md` (v9; § references below).
Verdicts (exactly one per row): **IBC** = impossible by construction (the state/mechanism
producing the scenario does not exist); **SAFE** = attemptable, protected by a named
mechanism; **RESIDUAL** = accepted, honest preconditions stated (pointer into §12 N-table).
v9 tracks design v9 (round-8 fixes, SDK-verified: honest AB-4 bootstrap strip with containment nets; no fetch/send inside handleEvent; gate rationale via zone-CAS/N1; legacy identification routing arm; own-command lastApplied writes). v8 was round 7: total resume-gate case-split observed by direct record fetch; legacyCleanupIds persisted carrier; automaticallySync=false bootstrap strip — no send-timing assumption; provenance/scoping drift fixed). v7 was round 6: T1 strip covers restored database changes — resetIntent is the sole source of truth for zone changes; lastAppliedResetCommandId provenance; own-id resume; legacy flag on confirmation; refuse=remove; scoped rollback context; N12 widened to both sides). v6 was round 5: all restored pending deletes stripped + all recovered tombstones verified; failed-apply supersession + verify-before-replay; §5.2 dequeues the outbound delete; reset-resume command snapshot; abandoned intents dequeue zone changes; context rollback; echo guard cycle-start scoping; AB-3). v5 was round 4: verify-before-delete for recovered intents;
tombstone rollback; §5.6 failed-apply retry; echo guard; T1 seed-intent recovery; N14
added). v4 was round 3: the v3 §5.6 absence-sweep is deleted and replaced
by I12 delete-intent tombstones; `systemFields` is apply-gated and type-scoped; seed
intents clear only on observable signals; the own-origin apply skip is removed;
pending-delete-wins on the fetch path). Residual pointers reference N1–N13 as amended
(N5 corrected: local deletions survive toggle cycles via tombstones; N8 scoped to saves
only).

## Class A — deletion-by-absence vs. reset/wipe races

| ID | Verdict | Why |
|----|---------|-----|
| A-1 | IBC | No absence inference exists (I1, I5); empty/partial fetches mutate nothing (S-2). Reset variants 1-2 use the zone-deletion event and/or command record, neither of which deletes local data (T5, §8.3, S-3/S-8). The §8.6 wipe deletes only on explicit user consent and a higher `SyncEstablishment.generation`, not absence. |
| A-2 | IBC | For reset variants 1-2, the "wiped but unsignalled" state cannot exist server-side: the reset signal is the zone deletion plus command carrier. For §8.6, the durable signal is the fixed-name establishment record; a peer that misses the zone event adopts only after fetching `generation > local`. A reset/wipe failing before the relevant confirmation is a no-op or resumes from `resetIntent` (§8.1/§8.6). |
| A-3 | IBC | No pass structure, no reconciliation; fetched deletions name records explicitly (§5.2). |
| A-4 | IBC | Same — manual sync is `fetchChanges()`, which can only deliver explicit events. |
| A-5 | IBC | Push acks update `systemFields` only (§5.3); no safety decision reads them. Records die with zones (database-level), not as inferable record absences. |
| A-6 | IBC | Nothing compares "what I pushed" with "what a fetch returned"; token fetches are gap-free by the server contract. The one place server state meets local push state — `serverRecordChanged` (§5.3 branch C) — merges by version and re-enqueues; it cannot delete. |
| A-7 | IBC | No decision consumes stale presence — no superset/verification check exists. |
| A-8 | IBC | No decision consumes stale absence — the command is an instruction, not protection; missing it delays selection-clear/re-seed only until the fetch that delivers it (§8.3). |
| A-9 | IBC | The vacuousness dilemma applied to evidence-gated absence deletion; deleted (§9). |
| A-10 | SAFE | One serial main-actor event stream (§2, B-7); shared persisted state is add-only (`processedResetCommandIds`) or internally consistent per-account pairs (§7). No cross-pass flags exist. |
| A-11 | IBC | Sole-copy data can only be deleted by an explicit deletion event for that record. Resets delete zones, not records; T5/§8.3 keep local data and re-seed it (I11). |
| A-12 | SAFE | Newer-schema profiles: never enqueued for save (I2), provider removes any stray pending save (§5.4, S-14), and only an explicit deletion event can remove them locally (I1). |
| A-13 | IBC | Locations ride the identical §5 event paths; no location-specific reconciliation exists. Their merge-rule divergence is N6 (RESIDUAL, non-destructive), stated per round-1 audit. |
| A-14 | SAFE | Last-item deletion propagates as an explicit event (S-1). No empty-remote heuristic blocks it; seeding happens only on I11 transitions (S-19). Deliberate re-seeds can resurrect *lagging* deletions — stated honestly as N9 (any reset) and N5 (rejoin), both RESIDUAL pointers. |

## Class B — reset-command lifecycle

| ID | Verdict | Why |
|----|---------|-----|
| B-1 | IBC | Commands are never consumed by readers; the fixed-name record persists for its zone incarnation (§8.2), is never stored in `systemFields`, and no outbound-delete mechanism can touch it (I12 tombstones cover funnel deletes only — the v3 sweep that could destroy it is deleted); every device that fetches sees it. |
| B-2 | SAFE | Lifecycle GC: the next reset's zone deletion removes the command; the origin pre-marks its own id (§8.1 step 1). A device syncing a year later applies the *current* incarnation's command — correct by definition; a *superseded* command cannot survive (CAS overwrite or zone death, §8.2). Clear-selections on a very late joiner is within reset semantics (corpus B-2/#202.3 acceptance carried over). |
| B-3 | SAFE | Concurrent resets serialize at two CAS points: zone delete/recreate (server-side) and the fixed-name command record (§8.2). A superseded origin's queued command save fails `serverRecordChanged` and is dropped (§8.1 step 5, S-13) — the round-1 zombie-command interleaving is closed by construction of the fixed name. Churn bounded (N3). |
| B-4 | IBC | No hand-rolled bulk delete; the only mass operation is `deleteZone` (one database change); the engine batches record sends internally; per-record failures follow §5.3 (S-17). |
| B-5 | IBC (safety) | An undecodable command cannot suppress anything (commands are not protection) and dies with its zone; unknown types and undecodable payloads are logged and ignored (§5.1, stated explicitly in v5). Delivery of that reset's *selection-clear* is lost — equivalent to N1's last-reset-wins acceptance. |
| B-6 | SAFE | I10: no engine exists before the context does — the nil-context state is unreachable, background cold launches included (S-7); applies are durable in-event (§5.0). |
| B-7 | SAFE | One serial event stream; apply-then-mark is synchronous within the handler (I4); redelivery is idempotent anyway (S-5). |
| B-8 | IBC | There is no multi-command ordering: one fixed-name record per incarnation; supersession is a server-serialized CAS overwrite (§8.2). No date ordering, no tie-break needed. |

## Class C — clocks

| ID | Verdict | Why |
|----|---------|-----|
| C-1 | SAFE | No date participates in any *safety or idempotency* decision (I3): command identity is UUID-keyed; supersession is CAS, not date-ordered. The one inherited client-clock comparison (location field merge) is N6 — non-destructive, named, with a fix vehicle. |
| C-2 | IBC | No clock-based GC exists; command lifetime = zone lifetime. |
| C-3 | IBC | No date-based idempotency exists to loop (I3, S-5). |
| C-4 | IBC | No protection window exists to be born expired. |
| C-5 | IBC | No local-time window exists for a forward roll to end. |
| C-6 | IBC | `processedResetCommandIds` is never pruned (§2.1). |

## Class D — process & state hygiene

| ID | Verdict | Why |
|----|---------|-----|
| D-1 | SAFE | Ordering-sensitive persisted writes, each stated: apply-before-mark (I4, S-6); intent-before-consume for every seed entry point (I11, S-28); tombstone-with-delete (I12, S-29); funnel bump-inside-the-save (I2, S-15); §8.6 wipe/adoption deletes local synced entities before bumping `establishmentGeneration`; AB-2 for fetch tokens only (S-26 — seed/tombstone intents never key off serialization capture). Kill windows fail toward idempotent re-apply, intent-driven recovery, or an empty local world that re-adopts the higher establishment generation — never toward unprotected skips, orphaned seeds, or orphaned deletes. |
| D-2 | IBC | No pass exists whose early step gates a later destructive step; events are self-contained; a failed fetch delivers no events and therefore no mutations. |
| D-3 | SAFE | All *sync state* per-`userRecordID`, nothing purged on switch (T7, §7, S-12); UUID ids cross-account-collision-proof; the round-1 switch-back resurrection is closed by pair consistency. The *data store* is account-agnostic — cross-account data union is N11 (honest residual, pre-existing class), not claimed harmless. |
| D-4 | SAFE | Toggle-off discards engine state; toggle-on is an explicit fresh bootstrap with rejoin semantics (T11/T1, N5 — stated, not hidden). Ordinary relaunch resumes the queue with zero re-derivation (S-19). |
| D-5 | IBC | Throttle deleted; engine scheduler + tokens make a missed push pure latency (§1.1, N4). |
| D-6 | SAFE | Zone deleted/recreated is first-class (T5/T6 + §5.5 confirmations + §5.3 `zoneNotFound` recovery); tokens engine-internal; bookkeeping resets via I6; re-seed crash-durable via `pendingSeedIntent` (I11, S-28) plus the §8.3 redundant carrier — modulo N7 (fully-quiet family) and N8 (save-enqueue kill window). |
| D-7 | SAFE | §2.1 enumerates every persisted key with provenance; compound ops under `withLock`; the engine state file has a single writer. (v1's missing `pendingCommandApplication` key was deleted along with the buffering machinery, I10.) |

## Class E — product semantics

| ID | Verdict | Why |
|----|---------|-----|
| E-1 | SAFE | `needsAppSelection` semantics unchanged (§5.1); the husk mass-producers are IBC above. |
| E-2 | SAFE | Deliberate decision §8.5: origin no longer clears its own selections; matches shipped copy. |
| E-3 | SAFE | Keep-by-default is structural (I1); no ambiguity-resolving heuristics remain. §8.6 is the single deliberate inversion: a user-confirmed "totally delete" wipe discards older generations only when an explicit higher establishment marker is fetched. |
| E-4 | SAFE | Propagation is event-carried with app-managed re-adds on failure (§5.3, S-1, S-16, S-17, I8); version-bump ownership by I2/S-15/S-16; equal-version divergence by branch 0 + branch E + the §5.1 fetch-path rule (S-10, S-27); killed delete-enqueues by I12 tombstones (S-29 — recorded intent, never absence inference); own-origin echoes apply correctly (S-31, restore-from-backup heals); pending-delete-wins prevents self-resurrection (S-32). §8.6 additionally prevents wipe resurrection by stamping restorable records and skipping dead-world generations (S-W1...S-W8). Deletion propagation to token-expired dormant devices is N10; session stops post-reset propagate via §6 stop-on-absent (S-24). |

## #310/#328 wipe amendment

The totally-delete variant is SAFE under §8.6:

| Scenario | Verdict | Why |
|---|---|---|
| Offline peer with pending pre-wipe saves | SAFE | Pending records are stamped with the peer's old `establishmentGeneration`; after adoption they are skipped as `.skippedDeadWorld` (S-W1). |
| Concurrent wipe/reset tap while a reset intent exists | SAFE | `beginReset(wipe:)` is ignored while `resetIntent != nil`; the original stage/id remain authoritative (S-W2). |
| Mid-fetch record from a newer generation arrives before the establishment marker | SAFE | The record is skipped as `.skippedNewerGeneration`; adoption clears `engineState` so the next attach is a token-less full refetch and the record redelivers at `==` (S-W3). |
| Tombstone/failed apply from an older generation shadows a recreated id | SAFE | Adoption clears generation-scoped tombstones, watermarks, system fields, and failed applies; `processedResetCommandIds` survives (S-W4). |
| Live V1 peer re-pushes generationless data after a wipe | RESIDUAL | V2 devices at generation >= 1 skip generation-0 records as dead-world, but the server record can persist while V1 keeps writing. Settings copy tells users old app versions must update (S-W5). |
| V1-upgraded device with local profiles first sees a higher establishment generation | SAFE | Maintainer decision MD2: adopt-and-discard. Local synced profiles/locations are deleted and the device joins the higher generation without seeding (S-W6). |
| Emergency unblock epoch resurrection | SAFE | `SyncedEmergencyEpoch` and `SyncedEmergencyUnblockEvent` are stamped/gated; adoption clears the ledger but preserves settings lock/period, so a lagging gen-0 epoch cannot max-merge back (S-W7). |
| Origin crash at `.wiping` | SAFE | Resume re-enqueues only `SyncEstablishment`, never command/seed; confirmation clears `resetIntent` (S-W8). |

## Residual table (R1–R8, from the A1 rev-4 design)

| ID | Verdict | Why |
|----|---------|-----|
| R1 | IBC | No suppression window exists (C-4). The vacation device fetches explicit events only; a reset in the interim reaches it via T5 *or* the §8.3 command (redundant carriers — the v1 claim that the zone event alone always arrives was retracted per round 1); its sole-copy data survives (I1) and re-uploads (I11). |
| R2 | IBC | No suppression to extend; undecodable records inert (B-5). |
| R3 | IBC | No local-time gate (C-5). |
| R4 | SAFE | I10 context-gated engine (no nil-context processing exists) + §5.0 durable in-event applies (S-7). |
| R5 | IBC | No prune (C-6). |
| R6 | IBC | Required absence inference during marker invisibility; both halves gone (A-8). |
| R7 | SAFE | Deletion propagation is never suspended (no windows), and seeding is restricted to I11 transitions (S-19) — the launch-time blanket re-push does not exist. Deliberate re-seeds can resurrect deletions not yet fetched by every device: N9 (reset), N5 (rejoin), N10 (token-expired dormancy) — honest residuals, not hidden. |
| R8 | IBC | No clock GC of commands (C-2). |

## Honest residuals of the new design

N1–N14 as defined in design §12 (v9, editorial pass post-round-9; N14 split by stage). Round-3 corrections: N5's delete direction fixed —
local deletions survive toggle cycles and re-propagate via I12 tombstones (the v3 claim
that they "silently un-happen" was both dishonest and worse-behaved); N8 scoped to
save-enqueues only (deletes recover via I12, recorded intent — the v3 §5.6 absence-sweep
is deleted); N3 notes mixed-build payload-equality noise. N9–N13 unchanged from v3; N14 (restore-replayed reset intent, supersession-checked) added in v5; restored delete intents are guarded, not residual (I12 verify-before-delete, S-33).
