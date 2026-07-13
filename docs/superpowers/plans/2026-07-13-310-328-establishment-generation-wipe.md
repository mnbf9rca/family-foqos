# Establishment-Generation "Totally Delete All Synced Data" — #310 / #328 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This is a plan-only deliverable produced by a separate planning session; **implementation is a separate session.** Do **Task 0 (citation refresh) first** — every `file:line` below is anchored at `origin/main = 1219027` and will drift.

**Goal:** Add a third Reset Sync variant — *"Totally delete all synced data and settings"* — that makes a wipe **stick** across reinstall / re-seed / union-rejoin / a live V1 peer, by introducing a monotonic **establishment generation** (the A3′ emergency-epoch pattern, generalized to the whole dataset). Closes #310 and the convergence half of #328.

**Architecture:** A new fixed-name `SyncedEstablishment` record (modeled verbatim on `SyncedEmergencyEpoch`) carries a monotonic `generation: Int` written **first** into a (re)created zone. Every device persists `establishmentGeneration` in `SyncEngineStore`. The restorable, resurrection-prone synced records (`SyncedProfile`, `SyncedLocation`, `SyncedEmergencyEpoch`, `SyncedEmergencyUnblockEvent`) are stamped with the generation they were authored under. **One gate** at the fetched-record dispatch (`SyncApplyService.applyFetchedModification`) makes every re-seed path — reset command, `zoneNotFound` recovery, union rejoin, and V1 re-push — **inert across generations**. On fetching a higher generation, a device **discards-and-adopts** (serialized): stops sessions, deletes local synced entities, clears per-generation bookkeeping, **nulls `engineState` to force a real full re-fetch**, adopts the new generation via `reattachEngine`, and re-seeds nothing. The wipe origin drives the existing §8.1 reset state machine, branching to a dedicated `.wiping` stage that writes only the establishment record.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, CloudKit `CKSyncEngine` (private DB, `DeviceSync` zone), `FamilyControls`. All new durable state in `SyncEngineStore` (per-user namespaced UserDefaults). No new dependencies.

## Global Constraints

- **Plan-only:** produce no implementation in the planning session. Line numbers anchor at `origin/main = 1219027`.
- **V1 is live in the App Store and frozen** — no further V1 release. V1 peers keep re-pushing schema-1 profiles and cannot be changed. Never chase *server* convergence against a live V1 writer; design generation adoption so no V2 device *materializes* dead-world data, and self-resolves when V1 upgrades (#329 accepted-residual reasoning).
- **This is a ratified S0 contract amendment** (#310 is filed as one). Amend `docs/plans/2026-07-02-sync-engine-design.md` §8 and its corpus-mapping companion as a plan deliverable (Task 10). Do **not** silently redesign variants 1–2.
- **§1.1 delegate rule:** never call `sendChanges()`/`fetchChanges()` synchronously (or via a task-local-inheriting `Task {}`) from inside a `CKSyncEngine` delegate callback — schedule via the existing hook→`Task {}` pattern; the task-local-clearing `Task.detached` lives inside `CKSyncEngineDriver` (#286).
- **Lock-gating:** the wipe action is destructive → gate the button in Child mode with `appModeManager.currentMode == .child` (B1 pattern, `== .child` **never** `!= .parent`).
- **Naming:** the durable, peer-visible generation is **`establishmentGeneration`** (in `SyncEngineStore`). Do **not** call it `generation`/`namespaceGeneration` — `namespaceGeneration` (`SyncEngineController.swift:57`) is an unrelated in-memory task-cancellation epoch.
- **Schema:** the per-record `generation` field is a **new CKRecord field**, additive and V1-ignored. It **must not** bump `profileSchemaVersion` (that would make every profile V1-unreadable through the bridge).
- **Pin time in tests:** one `let now = Date()` per test; inject via `now:`.
- **Test destination:** simulator **UUID**, never device name.

---

## 1. Background & the mechanism

### 1.1 Why a wipe does not stick today

Before sync, delete-and-reinstall fixed any bad app state. With sync that escape hatch is gone (reinstall re-pulls; Reset Sync re-seeds from peers — reset **is** re-seed, `handleZoneSaveConfirmed` → `seeder.seedAll()`; toggle-off/on union-rejoins). The motivating instance: an exhausted emergency-unblock ledger cannot be cleared by any user action (reinstall re-syncs it), which blocked device testing 2026-07-11. The class is broader than any one record type: **there is no user-accessible way to make the synced world start over.** With a live V1 peer it is worse — V1 sees the deleted zone as "nothing to sync" and re-pushes its schema-1 profiles, recreating the zone and resurrecting exactly the unmigrated profiles V2 defers migrating (#328).

### 1.2 The generation, precisely

- **`SyncedEstablishment`** — a fixed-name record `{ generation: Int, establishedAt: Date }` (`recordName = "sync-establishment"`), the exact shape of `SyncedEmergencyEpoch`. One per zone incarnation. Merged by `max(generation)` on fetch and on save-conflict.
- **`establishmentGeneration: Int`** — persisted per-user in `SyncEngineStore` (default `0`). "The generation I belong to."
- **Per-record generation stamp** — the **restorable, resurrection-prone synced records** gain a `generation: Int` CKRecord field: `SyncedProfile`, `SyncedLocation`, **`SyncedEmergencyEpoch`, and `SyncedEmergencyUnblockEvent`** (the last two because the emergency ledger — the motivating #310 case — otherwise bypasses the gate; see MD4 and §3.1 I7). `RecordProvider` stamps `store.establishmentGeneration` at materialization. **A record with no generation field decodes as generation `0`** — exactly what a frozen V1 peer, and any pre-wipe record, produces. The field is **excluded from `SyncPayloadEquality`** so a generation bump never spuriously marks a record "changed" (no push storm).
- **The gate** — placed **once at the `SyncApplyService.applyFetchedModification` dispatch** (`:61-81`), the single point every fetched record of every stamped type flows through (subsuming the per-type apply functions). For any record carrying a `generation` field:

  | fetched record generation vs `store.establishmentGeneration` | action |
  |---|---|
  | `==` | materialize (normal) |
  | `<` (incl. V1's implicit `0` after any wipe) | **discard — dead world** (`.skippedDeadWorld`) |
  | `>` | **skip this pass** (`.skippedNewerGeneration`); the establishment record in this or a later batch triggers adoption, which **discards the fetch token (`engineState = nil`)** and re-bootstraps → a genuine full re-fetch redelivers the skipped record at the adopted generation |

  Records with no `generation` field (e.g. `SyncedEmergencySettings`) pass through ungated. Pre-wipe, everyone is at generation `0` and every record (including all V1) is `0` → `==` → **behaviour is unchanged and V1 interop is preserved.** The first wipe bumps the zone to `1`; from then on everything at generation `0` is dead-world.

- **Wipe (variant 3)** = delete zone → recreate → write `SyncedEstablishment(generation: N+1)` → seed **nothing** else; on the origin, **delete local synced entities first (session-safe, local-only), then** set `establishmentGeneration = N+1`, clear per-generation bookkeeping.
- **Adoption** (any device, on fetching `generation > mine`) = **stop active sessions + delete local synced entities first (commit), then** set `establishmentGeneration = fetched` + clear per-generation bookkeeping + **`store.engineState = nil`**, **then** `reattachEngine(userRecordName: sameUser, forceSeed: false)`. Nulling `engineState` is what makes the rebuild a **real** #286-style full re-fetch (reattach alone restores the change token and would silently lose the skipped `>` records — see §1.4 correction 5). Entities-before-generation ordering makes a mid-adoption crash **fail toward wipe** (§3.2 D-1). Adoption is **serialized** (one in-flight at a time, coalescing to the max generation seen) since it is dispatched off the delegate via `Task {}` and suspends at `await reattachEngine`.
- **Concurrent wipes from the same base collapse into one generation** — monotonic-max convergence, the same argument as the shared emergency budget (#221). Correct, not a conflict.

### 1.3 One gate, every re-seed path

The design's leverage is that **every** way old data could re-enter the world flows through the same fetched-record create branch:

- A superseded **reset command** (variant 1/2) that re-seeds → its re-seeded records carry the seeder's *current* generation; a lagging peer stamps `N`, adopters at `N+1` discard.
- A **`zoneNotFound` recovery** re-seed (`handleFailedSave`/`handleFailedDelete` branch Z → `seedZoneAndRecords`) racing the wipe → same: stamped at the recovering peer's generation, discarded by adopters.
- A **union rejoin** (`forceSeed` on account change) → stamped at current generation.
- A **V1 re-push** → generation-less → `0` → dead-world after any wipe.

We therefore gate **once** at the `applyFetchedModification` dispatch, not N times at each re-seed site. This is the concrete reading of the seed's "re-seed decisions everywhere become generation-gated." **The gate must cover every stamped restorable type, not just profiles/locations** — the emergency epoch/unblock-event records are re-pushed by `restorableEmergencyRecordNames` on any `zoneNotFound` recovery/seed, and a max-merged epoch record left ungated would drag an adopter's `currentResetEpoch` back up and re-exhaust the ledger #310 exists to clear (§3.1 I7). Records with no generation field (settings) legitimately pass through.

### 1.4 Corrections to the seed the grounding forced (read before implementing)

1. **There is no physical establishment record today** — the `saveZone` database change is the current *implicit* establishment; `seedZoneMarkerName` is a virtual placeholder never written to CloudKit. #310 **introduces** the first real one (`SyncedEstablishment`), a fetchable record like `SyncedEmergencyEpoch`. Do not try to gate on zone-save confirmation.
2. **The create branch is already `#315` watermark-gated**, not "version-blind." The generation gate **layers on top** of the watermark; it does not replace it.
3. **V1 records are not literally "generation-less"** — they carry `profileSchemaVersion=1`, `version`, `originDeviceId`. The distinguishing fact is only that V1 **cannot write the new `generation` field**, so it decodes as `0`. Key the gate on that, never on schema version (unmigrated V2 profiles are also schema-1).
4. **#310's `SyncEngineController.swift:303-304` citation is stale post-#341** — the stop/purge lifecycle now lives at `handleAccountChange` (`:361-369`) → `prepareForAccountSwitch` (`:94-103`) / facade `resolveAccountChange` (`ProfileSyncManager.swift:305-356`). Re-anchor in Task 0.
5. **`performStrip` strips deletes + DB changes, not saves — and reattach does not discard the token.** Two consequences the adversarial pass proved against the real code: (a) an offline peer's pending gen-`N` *saves* are dropped only by an **explicit `engineState = nil`** (the strip leaves saves; and `reattachEngine`→`buildEngine`→`start()` restores `engineState` because the #286 discard fires only when `resetIntent != nil` or a pending `.deleteZone` is present — neither holds for an adopter). Adoption **must** null `engineState` itself. (b) Because the restored change token would otherwise skip already-delivered records, adoption's "full re-fetch redelivers the skipped `>` records" is **only** true once `engineState` is nulled — without it, a `.skippedNewerGeneration` profile is lost forever. Both are folded into Task 6.

### 1.5 STOP-boundary check (required by the brief)

The brief mandates: *if the §8.1 reset protocol itself is wrong (not just its implementation), STOP and return to contract review.* **It is not wrong — no STOP.** §8.1's reset-as-re-seed is correct for variants 1–2 and stays unchanged. This plan is entirely additive:

- new record type (`SyncedEstablishment`);
- variant 3 = a `wipe` flag on `ResetIntent` that branches only the `.seeding` arm;
- a per-record generation field + one materialization gate;
- one **scoped** amendment to an existing invariant — "tombstones survive resets" — narrowed so that a **generation flip** (and only a generation flip) clears them (variants 1–2 still preserve them).

`§8.5` already houses deliberate reset product-decisions; this extends that section. The generation mechanism composes with §8.1 rather than contradicting it. The one place the wipe would have *broken* a §8.1 arm — `resume()`'s `.seeding` arm re-publishing a command + re-seed on crash — is avoided by giving the wipe its **own `.wiping` stage** with a dedicated resume arm (Task 7); variants 1–2's `.seeding` arm is untouched. Confirmed against the A1 corpus in §3.

### 1.6 Adversarial pass (folded)

A four-lens skeptic pass (A1-corpus regression, interleaving holes, contract/one-gate/STOP, mechanism feasibility), each grounded in the real code, ran against the first draft and found **five real defects**, all folded above:

1. **[blocker] Adoption never forced a full re-fetch** — `reattachEngine` restores the change token, so skipped `>` records were lost forever. Fix: adoption nulls `store.engineState` (§1.2, §1.4-5, Task 6).
2. **[blocker] SIGKILL mid-adoption failed toward resurrection** — bump-before-wipe across two non-atomic stores. Fix: delete entities & commit first, bump last (§3.2 D-1, Task 6/7).
3. **[blocker] Origin crash at `.seeding` re-published a command + re-seed** — inverting the wipe. Fix: dedicated `.wiping` stage + resume arm (Task 7).
4. **[blocker] Emergency ledger bypassed the gate** — the motivating exhausted-ledger case resurrected multi-device. Fix: stamp+gate the epoch/unblock-event records; gate at the `applyFetchedModification` dispatch; narrow ledger-clear seam (MD4, Tasks 4/5/6).
5. **[major] Adoption's bulk delete didn't stop active sessions** (zombie `@Model`) and **could funnel deletes into the fresh zone**; **double-adoption** could orphan a driver. Fixes: session-safe local-only delete + serialized adoption (Task 6/7).

Confirmed non-issues by the pass: the adoption trigger is genuinely presence-based (no Class-A regression); E-4 is preserved; the V1 bridge is safe (V1 ignores the new field; `SyncPayloadEquality` excludes it); the one-gate claim holds for all materialization paths **once** emergency records are stamped; concurrent same-base wipes converge with no `serverRecordChanged` loop; keeping `processedResetCommandIds` is sound (I3).

---

## 2. Maintainer decisions

Two are genuine maintainer calls (recommendation given, must be confirmed before/at implementation). Two I settle in-plan with rationale.

### MD1 (maintainer — headline): adoption UX — silent vs surfaced

When a **peer** device discovers it is in a dead world and deletes its local synced data, does it tell the user or wipe silently?

- **Recommend: surfaced, minimal.** Reuse the existing one-time `.syncEnginePurged`-style `NotificationCenter` notice (the T6 `.purged` path already posts one) with copy like *"Synced data was reset from another device."* Rationale: E-3 (visible > silent); silently deleting a user's local profiles is alarming and indistinguishable from a bug.
- **Alternative: silent** — literal reading of "as if the app was uninstalled everywhere" (an uninstall shows no notice). Cheaper; loses the honesty.
- **Impact:** Task 6 either posts a notice or does not. No mechanism changes either way.

### MD2 (maintainer): formerly-V1 device upgrading with local data + no stored generation

A device that was on V1, then upgrades to V2, first attaches with local schema-1 profiles and `establishmentGeneration = 0`. If the family has already wiped (zone at generation `N ≥ 1`), it fetches `generation N > 0`:

- **Recommend: adopt-and-discard** (the default under the `nil == 0 < N` rule — no special case). Completes the wipe; consistent with "as if uninstalled everywhere." Re-seeding would resurrect exactly the husks #310 exists to kill.
- **Caveat:** local-only profiles that never reached V2 are deleted on that device. The device did not necessarily participate in the wipe decision — this is the one place the wipe can surprise a user with local data loss. That is why it is a maintainer call.
- **Alternative: re-seed** (treat first-V2-launch local data as authoritative, push at generation `N`) — partially un-wipes; rejected by the recommendation but must be explicitly ruled out.

### MD3 (settled in-plan): variant 3 uses the establishment record as the **sole** adoption carrier

Variant 3 does **not** enqueue a `sync-reset-command`. Rationale: the reset command's job is the guaranteed **re-seed** carrier — exactly what the wipe inverts; and a live V1 peer hard-deletes command records (`release/v1 …:406`), so the command is unreliable across a mixed family anyway. The establishment record's higher generation is the guaranteed, V1-proof adoption signal (V1 never touches an unknown record type). The origin still drives the §8.1 delete→recreate lifecycle; only the `.seeding` arm and the completion condition change.

### MD4 (settled in-plan — **revised after the adversarial pass**): stamp `SyncedProfile`, `SyncedLocation`, `SyncedEmergencyEpoch`, `SyncedEmergencyUnblockEvent`

The first draft stamped only profiles/locations. The adversarial pass proved that leaves the **motivating case** (the exhausted emergency-unblock ledger) *uncovered on a multi-device family*: the emergency epoch record is max-merged and the unblock events are union-merged, both re-pushed by `restorableEmergencyRecordNames` on any `zoneNotFound`/seed recovery. A lagging peer re-pushing its epoch would drag an adopter's `currentResetEpoch` back up (`EmergencyUnblockManager.swift:120` — budget is `allowance − events-at-current-epoch`), re-exhausting the ledger. So **all four restorable, resurrection-bearing types carry the stamp and pass through the one gate.**

- **Not stamped / ungated:** `SyncedEmergencySettings` (device/parent **config** — period + `locked`; resetting `locked` on a peer via a data wipe would be a parental-control regression, so it survives adoption untouched) and `SyncedSession` (V2-only, ephemeral, owned by `SessionSyncService`; excluded from `restorableRecordNames`).
- **Residual (stated):** a *lagging* V2 peer could transiently re-push an ungated V2-only session stamped at the old generation before it adopts; it self-heals on adoption and is never the "husk resurrection" catastrophe (E-1).
- **Adoption clears the local ledger** via a **new narrow seam** `clearLedgerForGenerationAdoption()` (sets `currentResetEpoch = 0`, removes the events blob) — **not** `resetAllStateForAccountSwitch()`, which also flips `locked`/period/version (over-reset). The narrow seam plus gating the epoch record durably clears the exhausted ledger and keeps it clear against a lagging re-push.

---

## 3. Interleaving analysis & A1 corpus mapping

The wipe's adoption trigger is **presence of an explicit higher-generation record**, never absence of data. It therefore does **not** reintroduce A1 Class-A (deletion-by-absence) inference — that stays impossible-by-construction under #267.

### 3.1 The six interleavings #310/#328 require discharged

| # | Interleaving | Verdict | Mechanism |
|---|---|---|---|
| I1 | Offline peer with pending gen-`N` sends rejoins gen-`N+1` | safe | Adoption **explicitly nulls `engineState`** (Task 6) → the fresh engine has empty pending queues, so the queued saves vanish. (Reattach alone does **not** do this — §1.4 correction 5.) Any pre-adoption re-materialized save is stamped gen-`N` → discarded by adopters via the gate. |
| I2 | Wipe issued while a reset (variant 1/2) is in flight | safe | `beginReset` guards `store.resetIntent == nil` (`ResetController.swift:114`) → the two serialize; second caller warns and returns. A peer's in-flight reset command that re-seeds is covered by the one gate (§1.3). |
| I3 | Wipe racing a peer's mid-fetch (incl. skipped record earlier in the same batch) | safe **only with the forced re-fetch** | Records fetched with gen `>` mine are skipped; adoption **nulls `engineState`** so the re-bootstrap is a genuine token-less full re-fetch that redelivers them at the adopted generation (without the null, the change token skips them → permanent loss — the blocker the adversarial pass caught). `zoneNotFound`/T5 `seedZoneAndRecords` re-seed during the delete window is stamped at the peer's current generation → inert for adopters; the re-seeding peer converges once it fetches the establishment record and adopts (bounded transient). |
| I4 | Tombstones across generations | safe | Adoption clears tombstones + watermarks **+ `failedApplies`** (§Task 6). Scoped amendment to "tombstones survive resets," justified because the whole world is replaced; a stale tombstone would otherwise wrongly suppress a legitimately re-created record at the new generation, and a stale `failedApply` would retry-fetch a dead-world record every cycle forever. |
| I5 | V1 re-push racing the generation bump | accepted-residual (honest) | V1 output is always gen-`0`; after any wipe every V2 device at gen `≥ 1` discards it. Transient materialization only on a V2 device that has not yet fetched the establishment record; it adopts and wipes on the next fetch. **Server record persists while V1 keeps re-pushing** — never materialized on any V2 device; resolves when V1 upgrades. UI says so (Task 8). |
| I6 | Formerly-V1 device joins a newer generation with local data | **MD2** | Default = adopt-and-discard. |
| I7 | Emergency ledger re-exhausted on an adopter (a lagging peer re-pushes the epoch/events) | safe **after MD4 revision** | The epoch and unblock-event records are now stamped + gated (MD4); an adopter discards a gen-`N` epoch instead of max-merging it, so `currentResetEpoch` stays `0` and the ledger stays cleared. Was a blocker while only profiles/locations were gated. |
| I8 | Origin (or adopter) SIGKILL mid-wipe | safe (fail-toward-wipe) | Ordering is **delete entities (commit) → then bump generation** on both origin (Task 7) and adopter (Task 6). A crash after delete/before bump leaves the device at gen `N` with an empty local world → it re-fetches the establishment record (`N+1 > N`) and re-adopts (idempotent). A crash *after* the bump leaves an empty world already at `N+1` (`==` no-op). Never the fail-toward-resurrect order (bump-first) the draft had. |

### 3.2 A1 corpus addendum (Task 10 writes this into the corpus-mapping companion)

Every A1 ID whose class the wipe touches, with its verdict under this design:

- **Class A (deletion-by-absence, A-1…A-14):** *unchanged / impossible-by-construction.* Adoption is presence-triggered (explicit higher-generation record); the gate discards on **stamped** generation, never on absence. `zoneNotFound` recovery re-seeds are made inert by the gate rather than by any absence inference.
- **B-1 consume-on-first-read / B-3 concurrent resets:** the establishment record is a fixed-name, non-consumed record read by every device (unlike the hard-deleted V1 command); concurrent wipes collapse by `max(generation)` (B-8 supersession → monotonic convergence, no tie-break needed).
- **C-1…C-6 (clocks):** the generation is a client-written **integer merged by max**, never a date — skew-immune (the counter is ordinal, `establishedAt` is descriptive only, never compared for ordering).
- **D-1 (SIGKILL ordering):** the entity deletes (SwiftData `ModelContext`) and the `establishmentGeneration` bump (`SyncEngineStore` UserDefaults) are **two different stores and cannot be one atomic transaction** — so ordering, not atomicity, provides the guarantee: **delete entities and commit first, bump last** (Task 6/7). Any kill point then fails toward wipe (empty local at gen `N` → re-adopt on next establishment fetch; or empty local at gen `N+1` → `==` no-op). The bump-first order the draft implied would fail toward resurrection and is explicitly rejected.
- **D-3 (account switch):** `establishmentGeneration` is per-user namespaced like all §7 state; adoption routes through `reattachEngine` which already handles the namespace.
- **D-6 (zone deleted/recreated externally):** unchanged T5/T6; the gate adds no new full-requery path (adoption's re-fetch is bounded and generation-checked).
- **E-1 (husk resurrection = silent blocking failure):** this is the catastrophe the gate prevents — a resurrected husk (`needsAppSelection = true`, enforces nothing) is exactly what discarding dead-world records blocks.
- **E-3 (keep > delete asymmetry):** the wipe **deliberately inverts** E-3 for one explicitly-consented, origin-initiated action. Justification documented in §8 amendment: the destructive intent is user-consented at the origin (#203 replication model), and adoption fires only on an explicit higher-generation marker (never on ambiguity) — so the asymmetry is preserved everywhere **except** the consented wipe.

---

## 4. File structure

**Modified:**
- `Foqos/CloudKit/SyncModels.swift` — new `SyncedEstablishment` struct; add `generation` field (encode/decode, `?? 0`) to `SyncedProfile`, `SyncedLocation`, `SyncedEmergencyEpoch`, `SyncedEmergencyUnblockEvent`.
- `Foqos/CloudKit/SyncEngine/SyncPayloadEquality.swift` — **exclude `generation`** from equality (no push storm on a generation bump).
- `Foqos/CloudKit/SyncEngine/SyncEngineStore.swift` — `establishmentGeneration: Int` field + accessor; `clearGenerationScopedBookkeeping()` bulk-clear (tombstones, watermarks, systemFields, **`failedApplies`**; keeps `processedResetCommandIds`); `ResetIntent` gains `wipe: Bool` and a `.wiping` `Stage`.
- `Foqos/CloudKit/SyncEngine/RecordProvider.swift` — `establishmentRecord()`; stamp `store.establishmentGeneration` on the four stamped types; include establishment record in restorable names (only once `establishmentGeneration > 0`).
- `Foqos/CloudKit/SyncEngine/MutationFunnel.swift` — `enqueueEstablishmentSave()`.
- `Foqos/CloudKit/SyncEngine/SyncApplyService.swift` — the **one generation gate at the `applyFetchedModification` dispatch** (covers all stamped types); `applyEstablishmentModification`; `.skippedDeadWorld`/`.skippedNewerGeneration` outcomes; drop a `.skippedDeadWorld` `failedApply` as terminal.
- `Foqos/CloudKit/SyncEngine/SyncEngineController.swift` — establishment save-conflict `max` arm in `localIsStrictlyNewer`; fetched-establishment routing + `onFetchedEstablishment` hook; establishment in `restorableRecordNames`.
- `Foqos/CloudKit/SyncEngine/SyncEngineControlling.swift` — protocol additions (`enqueueEstablishmentSave`).
- `Foqos/CloudKit/SyncEngine/ResetController.swift` — `beginReset(wipe:)`; `handleZoneSaveConfirmed` wipe branch → `.wiping`; `resume()` `.wiping` arm (establishment-save only, never command/seedAll); wipe completion on establishment-save-confirmed; wipe `.deleting`-gate arm (fetch establishment, not command).
- `Foqos/CloudKit/SyncEngine/SyncEngineController+Reset.swift` — `enqueueEstablishmentSave` outbox seam; `resetEstablishmentSaveDidSucceed` hook.
- `Foqos/Utils/EmergencyUnblockManager.swift` — new narrow `clearLedgerForGenerationAdoption()` (epoch→0 + remove events; preserves `locked`/period/version).
- `Foqos/CloudKit/ProfileSyncManager.swift` — `resetSync(wipe:)` facade; `adoptEstablishmentGeneration(_:)` (serialized; stop sessions → delete entities → clear bookkeeping + `engineState = nil` → `reattachEngine`); a shared `wipeLocalSyncedEntitiesForGeneration()` (session-safe, local-only delete, narrow ledger clear) used by origin + adopter; wire `onFetchedEstablishment`.
- `Foqos/Views/SettingsView.swift` — third reset variant + two-step full-screen confirmation, child-mode lock gate.
- `docs/plans/2026-07-02-sync-engine-design.md` + `docs/plans/2026-07-02-sync-engine-corpus-mapping.md` — §8 amendment + corpus addendum.

**Created:**
- `FoqosTests/SyncedEstablishmentTests.swift`
- `FoqosTests/EstablishmentGenerationGateTests.swift`
- `FoqosTests/EstablishmentAdoptionTests.swift`
- `FoqosTests/WipeOriginSequenceTests.swift`
- `FoqosTests/WipeInterleavingTests.swift` (S-W1…S-W6)

---

## Task 0: Citation refresh (do first)

**Files:** none modified; produces a verified anchor list for all later tasks.

The `file:line` anchors below were captured at `origin/main = 1219027`; post-#341 several have already moved (notably #310's `:303-304`). Re-anchor by **symbol**, not line.

- [ ] **Step 1: Re-grep every load-bearing symbol and record its current location.**

```bash
UUID=$(xcrun simctl list devices available | grep -m1 "iPhone 17" | grep -oE '[0-9A-F-]{36}')  # boot once for later tasks
git -C . rev-parse HEAD   # confirm base
for s in SyncedEmergencyEpoch adoptRemoteEpoch restoredStateIsPoisoned performStrip \
         reattachEngine prepareForAccountSwitch handleZoneDeletions applyDecodedProfile \
         deleteWatermark seedZoneAndRecords restorableRecordNames handleFetchedRecordZoneChanges \
         localIsStrictlyNewer onFetchedResetCommand beginReset handleZoneSaveConfirmed namespaceGeneration; do
  echo "=== $s ==="; grep -rn "$s" Foqos --include='*.swift' | head -6
done
grep -n "case deleting\|case recreating\|case seeding\|struct ResetIntent" Foqos/CloudKit/SyncEngine/SyncEngineStore.swift
grep -n "family_foqos_syncengine" Foqos/CloudKit/SyncEngine/SyncEngineStore.swift
```

- [ ] **Step 2: Confirm the five §1.4 corrections still hold** (no physical establishment record; watermark already gates the create branch; V1 field-ignore; `#329` durable-suppress still absent; `performStrip` does not strip saves). If any has changed, stop and reconcile with the maintainer before proceeding.

- [ ] **Step 3: Boot the simulator once** (UUID from Step 1) and run the full suite green as a baseline. Record the pass count.

Run: `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination "platform=iOS Simulator,id=$UUID" | xcpretty`
Expected: PASS (baseline; note count).

No commit (read-only task).

---

## Task 1: `SyncedEstablishment` record model

**Files:**
- Modify: `Foqos/CloudKit/SyncModels.swift` (after `SyncedEmergencyEpoch`, ~`:609`)
- Test: `FoqosTests/SyncedEstablishmentTests.swift`

**Interfaces:**
- Produces: `struct SyncedEstablishment: Codable, Equatable { var generation: Int; var establishedAt: Date }`; `static let recordType = "SyncEstablishment"`, `static let recordName = "sync-establishment"`; `func toCKRecord(in zoneID:) -> CKRecord`; `init?(from record: CKRecord)`.

- [ ] **Step 1: Write the failing test.**

```swift
import CloudKit
import XCTest
@testable import Foqos

final class SyncedEstablishmentTests: XCTestCase {
  private let zoneID = CKRecordZone.ID(zoneName: "DeviceSync", ownerName: CKCurrentUserDefaultName)

  func testGivenRecord_WhenRoundTripped_ThenGenerationAndDatePreserved() {
    let now = Date()
    let model = SyncedEstablishment(generation: 3, establishedAt: now)
    let record = model.toCKRecord(in: zoneID)
    XCTAssertEqual(record.recordID.recordName, "sync-establishment")
    XCTAssertEqual(record.recordType, "SyncEstablishment")
    let decoded = SyncedEstablishment(from: record)
    XCTAssertEqual(decoded?.generation, 3)
    XCTAssertEqual(decoded?.establishedAt.timeIntervalSinceReferenceDate ?? 0,
                   now.timeIntervalSinceReferenceDate, accuracy: 0.001)
  }

  func testGivenRecordMissingGeneration_WhenDecoded_ThenNil() {
    let record = CKRecord(recordType: "SyncEstablishment",
                          recordID: CKRecord.ID(recordName: "sync-establishment", zoneID: zoneID))
    XCTAssertNil(SyncedEstablishment(from: record))  // no generation field ⇒ inert (undecodable, B-5 style)
  }
}
```

- [ ] **Step 2: Run — expect FAIL** (`SyncedEstablishment` undefined).

- [ ] **Step 3: Implement** (mirror `SyncedEmergencyEpoch`, `SyncModels.swift:575-609`).

```swift
/// The zone's establishment generation, synced as a single fixed-name record and merged by max()
/// so every device converges on one agreed generation boundary (generalizes the #221 epoch pattern
/// to the whole dataset). Written FIRST into a (re)created zone by the "totally delete" wipe (#310).
struct SyncedEstablishment: Codable, Equatable {
  var generation: Int
  var establishedAt: Date

  static let recordType = "SyncEstablishment"
  static let recordName = "sync-establishment"

  enum FieldKey: String { case generation, establishedAt }

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let record = CKRecord(
      recordType: Self.recordType,
      recordID: CKRecord.ID(recordName: Self.recordName, zoneID: zoneID))
    record[FieldKey.generation.rawValue] = generation
    record[FieldKey.establishedAt.rawValue] = establishedAt
    return record
  }

  init(generation: Int, establishedAt: Date) {
    self.generation = generation
    self.establishedAt = establishedAt
  }

  init?(from record: CKRecord) {
    guard record.recordType == Self.recordType,
      let generation = record[FieldKey.generation.rawValue] as? Int
    else { return nil }
    self.generation = generation
    self.establishedAt = (record[FieldKey.establishedAt.rawValue] as? Date) ?? Date(timeIntervalSinceReferenceDate: 0)
  }
}
```

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** — `feat(#310): SyncedEstablishment generation record`.

---

## Task 2: Durable `establishmentGeneration` in `SyncEngineStore`

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineStore.swift` (near `pendingSeedIntent`, `:144-147`)
- Test: `FoqosTests/EstablishmentGenerationGateTests.swift` (generation-store cases)

**Interfaces:**
- Produces: `var establishmentGeneration: Int { get set }` (default 0, namespaced key `establishment_generation`), transaction-safe.

- [ ] **Step 1: Failing test** — persistence, per-user isolation, default 0.

```swift
func testGivenNoValue_WhenRead_ThenZero() {
  let store = SyncEngineStore(userRecordName: "userA", defaults: makeDefaults())
  XCTAssertEqual(store.establishmentGeneration, 0)
}

func testGivenSet_WhenReloaded_ThenPersistsPerUser() {
  let defaults = makeDefaults()
  SyncEngineStore(userRecordName: "userA", defaults: defaults).establishmentGeneration = 2
  XCTAssertEqual(SyncEngineStore(userRecordName: "userA", defaults: defaults).establishmentGeneration, 2)
  XCTAssertEqual(SyncEngineStore(userRecordName: "userB", defaults: defaults).establishmentGeneration, 0)
}
```

- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** (copy the `pendingSeedIntent` scalar pattern; route writes through `locked`).

```swift
var establishmentGeneration: Int {
  get { defaults.integer(forKey: key("establishment_generation")) }
  set { locked { self.defaults.set(newValue, forKey: self.key("establishment_generation")) } }
}
```

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** — `feat(#310): durable establishmentGeneration in SyncEngineStore`.

---

## Task 3: Establishment record provider, enqueue, and save-conflict max-merge

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/RecordProvider.swift` (mirror `emergencyEpochRecord`, `:90-97`; route the fixed name, `:33-35`; add to restorable names)
- Modify: `Foqos/CloudKit/SyncEngine/MutationFunnel.swift` (mirror `enqueueEmergencyEpochSave`, `:107-113`)
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineControlling.swift` (protocol decl)
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineController.swift` (`localIsStrictlyNewer` establishment arm, mirror `:660-664`; `restorableRecordNames`, `:1039-1047`)
- Test: `FoqosTests/EstablishmentGenerationGateTests.swift`

**Interfaces:**
- Consumes: `store.establishmentGeneration` (Task 2), `SyncedEstablishment` (Task 1).
- Produces: `RecordProvider.establishmentRecord() -> CKRecord`; `MutationFunnel.enqueueEstablishmentSave()`; establishment arm in `localIsStrictlyNewer` returning `localGen > serverGen`.

- [ ] **Step 1: Failing test** — provider materializes current generation; save-conflict keeps local only when strictly newer.

```swift
func testProviderStampsCurrentGeneration() {
  let store = makeStore(); store.establishmentGeneration = 4
  let provider = makeProvider(store: store)
  let rec = provider.establishmentRecord()
  XCTAssertEqual(rec[SyncedEstablishment.FieldKey.generation.rawValue] as? Int, 4)
}

func testSaveConflictLocalWinsOnlyWhenStrictlyNewer() {
  // localGen 5 vs serverGen 6 ⇒ local does NOT win (adopt server's higher gen)
  XCTAssertFalse(controller.localIsStrictlyNewer(
    forRecordName: SyncedEstablishment.recordName, server: serverRecord(gen: 6)))  // local store at 5
}
```

- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement.**

`RecordProvider.establishmentRecord()`:

```swift
func establishmentRecord() -> CKRecord {
  SyncedEstablishment(generation: store.establishmentGeneration, establishedAt: Date())
    .toCKRecord(in: zoneID)
}
```

Route the fixed name in `record(forRecordName:)` (alongside `SyncedEmergencyEpoch.recordName`, `:33`) and add `SyncedEstablishment.recordName` to `restorableRecordNames()` (`SyncEngineController.swift:1039-1047`) **conditionally — only once `establishmentGeneration > 0`** (a family that never wiped writes no establishment record, so pre-wipe behaviour and record count are unchanged).

`MutationFunnel.enqueueEstablishmentSave()` — copy `enqueueEmergencyEpochSave` verbatim with the establishment recordName.

`localIsStrictlyNewer` establishment arm (`SyncEngineController.swift:660`):

```swift
case SyncedEstablishment.recordType:
  let localGen = store.establishmentGeneration
  let serverGen = server[SyncedEstablishment.FieldKey.generation.rawValue] as? Int ?? 0
  return localGen > serverGen   // adopt the server's higher generation (max-merge, #221 pattern)
```

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** — `feat(#310): establishment record provider/enqueue/max-merge`.

---

## Task 4: Per-record generation stamp on the four restorable types (+ equality exclusion)

**Files:**
- Modify: `Foqos/CloudKit/SyncModels.swift` — add `var generation: Int` (default 0; encode in `toCKRecord`, decode `?? 0`) to `SyncedProfile` (`:18-131`), `SyncedLocation` (`:370-416`), `SyncedEmergencyEpoch` (`:575-609`), `SyncedEmergencyUnblockEvent` (`:615-668`).
- Modify: `Foqos/CloudKit/SyncEngine/RecordProvider.swift` — stamp `store.establishmentGeneration` when materializing all four types (profile/location record builders; `emergencyEpochRecord()`; unblock-event builder).
- Modify: `Foqos/CloudKit/SyncEngine/SyncPayloadEquality.swift` — **do not** compare `generation` (add nothing referencing it, so a bump is not a payload change; `:30` region).
- Test: `FoqosTests/EstablishmentGenerationGateTests.swift`

**Interfaces:**
- Produces: `.generation: Int` on all four DTOs; a generation-less record decodes to `generation == 0`; `SyncPayloadEquality` ignores `generation`.

**Design note:** stamping the emergency epoch + unblock event is what closes I7 (§3.1) — the motivating exhausted-ledger case. `SyncedEmergencySettings` and `SyncedSession` are **not** stamped (MD4). Do **not** touch `profileSchemaVersion`.

- [ ] **Step 1: Failing test** — V2 stamps current generation on a profile AND an epoch record; a V1-shaped record (no field) decodes to 0; `profileSchemaVersion` unchanged; equality ignores a generation-only delta.

```swift
func testGenerationExcludedFromPayloadEquality() {
  let a = makeProfile(generation: 1), b = makeProfile(generation: 2)  // identical but for generation
  XCTAssertTrue(SyncPayloadEquality.profilesEqual(a, b))              // no push storm
}
func testEmergencyEpochStampedWithCurrentGeneration() {
  let store = makeStore(); store.establishmentGeneration = 3
  XCTAssertEqual(SyncedEmergencyEpoch(from: makeProvider(store: store).establishmentBearingEpochRecord())?.generation, 3)
}
```

- [ ] **Step 1b: Failing test** — V2 stamps current generation; a V1-shaped record (no field) decodes to 0; `profileSchemaVersion` unchanged.

```swift
func testV2ProfileStampedWithCurrentGeneration() {
  let store = makeStore(); store.establishmentGeneration = 2
  let ck = makeProvider(store: store).record(forRecordName: profileId.uuidString)!
  XCTAssertEqual(SyncedProfile(from: ck)?.generation, 2)
}

func testGenerationlessProfileDecodesToZero_AndSchemaVersionUntouched() {
  var ck = SyncedProfile(from: existingProfile, generation: 0).toCKRecord(in: zoneID)
  ck[SyncedProfile.FieldKey.generation.rawValue] = nil            // simulate a V1 re-push
  let decoded = SyncedProfile(from: ck)
  XCTAssertEqual(decoded?.generation, 0)
  XCTAssertEqual(decoded?.profileSchemaVersion, existingProfile.profileSchemaVersion)  // NOT bumped
}
```

- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** — add `generation` to both structs' `FieldKey`, `toCKRecord`, and `init?(from:)` (`... as? Int ?? 0`); thread `generation:` through the `RecordProvider` materialization sites. **Do not touch `profileSchemaVersion`.**
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** — `feat(#310): stamp establishment generation on profiles/locations`.

---

## Task 5: The materialization gate (the single choke point)

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/SyncApplyService.swift` — add the gate **once at the top of `applyFetchedModification` (`:61-81`), before the type dispatch**, applied to any record that carries a `generation` field (profiles, locations, emergency epoch, unblock events). It runs **before** the per-type apply logic (including the `#315` watermark check), so a dead-world record is labelled `.skippedDeadWorld`, never `.skippedStaleDelete` (resolves the draft's before/after-watermark ambiguity — **gate first**).
- Modify: the `ApplyOutcome` enum — add `.skippedDeadWorld`, `.skippedNewerGeneration`.
- Test: `FoqosTests/EstablishmentGenerationGateTests.swift`

**Interfaces:**
- Consumes: `store.establishmentGeneration`; the `generation` field on the four stamped types.
- Produces: a `generationGate(_ record: CKRecord) -> ApplyOutcome?` helper returning `.skippedDeadWorld` (recordGen `<` mine), `.skippedNewerGeneration` (recordGen `>` mine), or `nil` (recordGen `==` mine, or no `generation` field → dispatch normally).

- [ ] **Step 1: Failing tests** — the three-way table, plus pre-wipe no-op.

```swift
func testDeadWorldRecordDiscardedAfterWipe() {   // I5 core — drive the dispatch, not the per-type fn
  let store = makeStore(); store.establishmentGeneration = 1
  let ck = makeProfile(generation: 0).toCKRecord(in: zoneID)   // V1 / pre-wipe record
  XCTAssertEqual(apply.applyFetchedModification(ck), .skippedDeadWorld)
}

func testEqualGenerationMaterializes() {
  let store = makeStore(); store.establishmentGeneration = 1
  XCTAssertEqual(apply.applyFetchedModification(makeProfile(generation: 1).toCKRecord(in: zoneID)), .applied)
}

func testNewerGenerationSkipped() {               // I3
  let store = makeStore(); store.establishmentGeneration = 1
  XCTAssertEqual(apply.applyFetchedModification(makeProfile(generation: 2).toCKRecord(in: zoneID)),
                 .skippedNewerGeneration)
}

func testDeadWorldEmergencyEpochDiscarded() {     // I7 — the ungated-bypass this closes
  let store = makeStore(); store.establishmentGeneration = 1
  let staleEpoch = makeEpochRecord(epoch: 5, generation: 0)    // a lagging/V1-ish re-push
  XCTAssertEqual(apply.applyFetchedModification(staleEpoch), .skippedDeadWorld)
  XCTAssertEqual(emergencyManager.currentResetEpoch, 0)        // NOT max-merged to 5
}

func testEmergencySettingsPassUngated() {         // no generation field ⇒ dispatch normally
  let store = makeStore(); store.establishmentGeneration = 1
  XCTAssertNotEqual(apply.applyFetchedModification(makeSettingsRecord()), .skippedDeadWorld)
}

func testPreWipeWorldUnchanged() {                // gen 0 everywhere, incl. V1
  let store = makeStore()                          // establishmentGeneration == 0
  XCTAssertEqual(apply.applyFetchedModification(makeProfile(generation: 0).toCKRecord(in: zoneID)), .applied)
}
```

- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** — insert the gate once at the top of `applyFetchedModification`, before the `switch record.recordType` dispatch:

```swift
func applyFetchedModification(_ record: CKRecord) -> ApplyOutcome {
  if let gated = generationGate(record) { return gated }   // dead-world / newer-gen skip, before any type logic
  switch record.recordType { /* ... existing dispatch ... */ }
}

private func generationGate(_ record: CKRecord) -> ApplyOutcome? {
  guard let recordGen = record["generation"] as? Int else { return nil }  // ungated types (settings) pass
  let mine = store.establishmentGeneration
  if recordGen < mine { return .skippedDeadWorld }         // incl. V1's implicit 0 after any wipe
  if recordGen > mine { return .skippedNewerGeneration }   // adoption (via establishment record) re-fetches
  return nil                                               // == ⇒ dispatch normally (watermark, merge, create)
}
```

Both skip outcomes are terminal no-ops (no local mutation, no watermark write, no ledger merge). In `retryFailedApplies`, treat a `.skippedDeadWorld` result as a **terminal drop** of the `failedApply` entry (else a dead-world record a V1 peer keeps re-pushing retry-fetches forever). Log at `.debug` (`category: .sync`).

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** — `feat(#310,#328): generation gate at the fetched-record create boundary`.

---

## Task 6: Fetched-establishment routing + adoption (discard-and-adopt)

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/SyncApplyService.swift` — `applyEstablishmentModification(_:)` (max-merge on fetch; if higher, signal adoption).
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineController.swift` — divert `SyncEstablishment.recordType` in `handleFetchedRecordZoneChanges` (`:389-436`, alongside the `SyncResetRequest` divert `:400-402`) to a new `onFetchedEstablishment` hook.
- Modify: `Foqos/CloudKit/ProfileSyncManager.swift` — `adoptEstablishmentGeneration(_:)`; wire `onFetchedEstablishment` in `buildEngine` (`:226-276`, next to `onAccountChange` `:256`).
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineStore.swift` — `clearGenerationScopedBookkeeping()` bulk helper.
- Test: `FoqosTests/EstablishmentAdoptionTests.swift`

**Interfaces:**
- Consumes: `reattachEngine(userRecordName:forceSeed:)` (`ProfileSyncManager.swift:358-379`); the session-safe `deleteProfile(cleanup:)` path (`wipeLocalSyncedDataDirectly`, `:413-435`); `EmergencyUnblockManager.clearLedgerForGenerationAdoption()` (Task-6 new seam).
- Produces: `ProfileSyncManager.adoptEstablishmentGeneration(_ newGeneration: Int) async` (serialized); `ProfileSyncManager.wipeLocalSyncedEntitiesForGeneration()` (shared with Task 7); `SyncEngineStore.clearGenerationScopedBookkeeping()` (clears tombstones, watermarks, systemFields, **`failedApplies`**; **keeps** `processedResetCommandIds`).

**Design notes (all five fold the adversarial findings):**
- **Trigger / no wipe-loop:** adoption fires only when `fetched.generation > store.establishmentGeneration`. Equal/lower is a `==` no-op (own-echo included → no loop; mirrors the §8.3 own-origin skip).
- **Off the delegate stack:** the `onFetchedEstablishment` hook schedules `Task { await manager.adoptEstablishmentGeneration(n) }` (like `onFetchedResetCommand`), satisfying §1.1.
- **Serialized (fixes the double-adoption race):** an `isAdopting` guard (plus a `pendingMaxGeneration`) ensures only one adoption's `await reattachEngine` is in flight; a higher generation arriving mid-adoption is coalesced and run once the current one finishes (its re-fetch would redeliver the newest establishment record anyway). Two overlapping `reattachEngine` rebuilds would clobber `ownedEngineController`/`engineController` and can orphan a driver (violating the #341 orphan-ban).
- **Ordering (fixes fail-toward-resurrect; §3.2 D-1):** (1) **stop all active/remote sessions** for the affected profiles and clear live-activity refs (reuse the `stopRemoteSession` + `deleteProfile(cleanup:)` seams — never a bare `ModelContext.delete`, which reproduces the #285/#297 zombie-`@Model` crash); (2) **delete local synced entities and commit** the `ModelContext` (local-only — no `MutationFunnel` deletes); (3) `store.transaction { clearGenerationScopedBookkeeping(); establishmentGeneration = n; engineState = nil }` + `emergencyManager.clearLedgerForGenerationAdoption()`; (4) `await reattachEngine(userRecordName: attachedUserRecordName, forceSeed: false)`; (5) **MD1**: optionally post the one-time `.syncEnginePurged`-style notice. The **entities-before-bump** order means a crash after step 2 leaves the device at gen `N` with an empty world → re-adopts on the next establishment fetch (fail-toward-wipe).
- **`engineState = nil` is mandatory (fixes the silent data-loss blocker):** `reattachEngine` alone restores the change token and would **never redeliver** the `.skippedNewerGeneration` records (§1.4 correction 5). Nulling `engineState` in step 3 forces `driverFactory(nil)` → a token-less full re-fetch that redelivers the establishment record and all current-generation records (materialized at `==`) and re-discards old-gen ones (`<`).
- **`clearGenerationScopedBookkeeping()`** clears tombstones + watermarks + systemFields + **`failedApplies`** (I4; a stale `failedApply` would retry-fetch a dead-world record every cycle forever) and **keeps `processedResetCommandIds`** (I3: never pruned; old-incarnation ids cannot reappear in a fresh zone).
- **Emergency ledger:** cleared via the **narrow** `clearLedgerForGenerationAdoption()` (epoch→0 + remove events) — **not** `resetAllStateForAccountSwitch()`, which also flips `locked`/period (a parental-control regression). Combined with gating the epoch record (Task 4/5), this durably clears the motivating exhausted ledger and keeps it clear against a lagging re-push.

- [ ] **Step 1: Failing tests.**

```swift
func testHigherGenerationDiscardsForcesRefetchAndWipes() async {
  let store = makeStore(); store.establishmentGeneration = 1; store.engineState = Data([0x1])
  seedLocalProfiles(count: 2); store.setTombstone(recordName: "x", changeTag: "t")
  store.addFailedApply(.init(recordName: "y"))
  await manager.adoptEstablishmentGeneration(2)
  XCTAssertEqual(store.establishmentGeneration, 2)
  XCTAssertTrue(localProfiles().isEmpty)                 // local synced entities deleted
  XCTAssertNil(store.engineState)                        // FORCED full re-fetch (data-loss fix)
  XCTAssertTrue(store.deleteTombstones.isEmpty)          // I4
  XCTAssertTrue(store.failedApplies.isEmpty)             // stale-retry fix
  XCTAssertTrue(reattachSpy.calledWith(forceSeed: false))
}

func testAdoptionStopsActiveSessionBeforeDeletingProfile() async {
  let store = makeStore(); store.establishmentGeneration = 1
  let p = seedLocalProfiles(count: 1).first!; startActiveSession(on: p)
  await manager.adoptEstablishmentGeneration(2)
  XCTAssertTrue(sessionSpy.stoppedBeforeDelete)          // no zombie @Model (#285/#297)
}

func testAdoptionOrdering_DeleteBeforeBump_FailsTowardWipe() async {
  // Inject a fault after the ModelContext delete commit, before the generation bump.
  let store = makeStore(); store.establishmentGeneration = 1; seedLocalProfiles(count: 1)
  faultInjector.throwAfterEntityDelete = true
  await manager.adoptEstablishmentGeneration(2)          // aborts mid-way
  XCTAssertEqual(store.establishmentGeneration, 1)       // NOT bumped (bump is last)
  XCTAssertTrue(localProfiles().isEmpty)                 // empty local at gen 1 ⇒ re-adopts cleanly
}

func testLedgerClearedNarrowly_LockedPreserved() async {
  let store = makeStore(); store.establishmentGeneration = 1
  emergencyManager.exhaustLedger(); emergencyManager.setSettingsLocked(true)
  await manager.adoptEstablishmentGeneration(2)
  XCTAssertEqual(emergencyManager.currentResetEpoch, 0)  // ledger cleared (motivating case)
  XCTAssertTrue(emergencyManager.settingsLocked)         // parental lock NOT reset
}

func testConcurrentAdoptionsSerializeToMax() async {
  let store = makeStore(); store.establishmentGeneration = 1
  async let a: Void = manager.adoptEstablishmentGeneration(2)
  async let b: Void = manager.adoptEstablishmentGeneration(3)
  _ = await (a, b)
  XCTAssertEqual(store.establishmentGeneration, 3)       // coalesced, single winning generation
  XCTAssertLessThanOrEqual(reattachSpy.overlappingCalls, 0)  // never two reattach rebuilds at once
}

func testEqualGenerationIsNoOp_NoWipeLoop() async {
  let store = makeStore(); store.establishmentGeneration = 2
  seedLocalProfiles(count: 1)
  await manager.adoptEstablishmentGeneration(2)          // own echo
  XCTAssertEqual(localProfiles().count, 1)               // nothing wiped
  XCTAssertFalse(reattachSpy.called)
}

func testProcessedResetCommandIdsSurviveAdoption() async {
  let store = makeStore(); store.establishmentGeneration = 1
  store.markProcessed(UUID()); let before = store.processedResetCommandIds
  await manager.adoptEstablishmentGeneration(2)
  XCTAssertEqual(store.processedResetCommandIds, before) // I3 preserved
}
```

- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** per the design notes. `handleFetchedRecordZoneChanges` divert:

```swift
if record.recordType == SyncedEstablishment.recordType {
  onFetchedEstablishment?(record)        // Task { await manager.adoptEstablishmentGeneration(...) }
  continue
}
```

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** — `feat(#310): fetched-establishment adoption (discard+reattach+local wipe)`.

---

## Task 7: Wipe origin — variant 3 on the §8.1 reset machine

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineStore.swift` — `ResetIntent` gains `var wipe: Bool` (default false; keep `Codable` back-compat — decode `?? false`).
- Modify: `Foqos/CloudKit/SyncEngine/ResetController.swift` — `beginReset(wipe:clearRemoteAppSelections:now:)`; branch `handleZoneSaveConfirmed` (`:141`); wipe completion.
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineController+Reset.swift` — `enqueueEstablishmentSave()` outbox seam.
- Modify: `Foqos/CloudKit/ProfileSyncManager.swift` — `resetSync(wipe: Bool, clearRemoteAppSelections: Bool)` facade.
- Test: `FoqosTests/WipeOriginSequenceTests.swift`

**Interfaces:**
- Consumes: existing delete→recreate flow (`beginReset` `:113`, `handleZoneDeleteConfirmed` `:131`, `handleZoneSaveConfirmed` `:141`); `enqueueEstablishmentSave` (Task 3); `wipeLocalSyncedEntitiesForGeneration()` (Task 6, shared).
- Produces: `ResetController.beginReset(wipe:clearRemoteAppSelections:now:)`; a new `ResetIntent.Stage.wiping`; `resume()` `.wiping` arm; wipe completion on establishment-save-confirmed (`resetEstablishmentSaveDidSucceed` hook).

**Design notes (fold the crash-durability + funnel-delete findings):**
- The origin reuses steps 1–3 unchanged (delete zone → recreate). At **`handleZoneSaveConfirmed`** (zone recreated), branch on `resetIntent.wipe`:
  - **reseed (variants 1–2):** unchanged — stage → `.seeding`; `pendingSeedIntent = true`; `enqueueCommandSave`; `seeder.seedAll()`.
  - **wipe (variant 3):** **(a)** `wipeLocalSyncedEntitiesForGeneration()` — stop sessions, delete the origin's own synced entities **local-only (no `MutationFunnel` `.deleteRecord`** — the zone teardown already removed them server-side; funnelling deletes into the fresh zone would muddy the completion batch); **(b)** `store.transaction { establishmentGeneration += 1; stage = .wiping }`; **(c)** `outbox.enqueueEstablishmentSave()`. Entities before the bump (fail-toward-wipe); **no** command, **no** `seedAll()` (MD3).
- **Dedicated `.wiping` stage (not reused `.seeding`).** This is required: `resume()`'s generic `.seeding` arm (`ResetController.swift:254`) unconditionally runs `enqueueCommandSave()` + `seeder.seedAll()`. A wipe that crashed at `.seeding` would, on resume, publish a reset command (violating MD3) and re-seed — inverting the wipe. The `.wiping` arm re-enqueues **only** the establishment save (durably re-derived from `store.establishmentGeneration`, so it survives the `resetIntent != nil` `engineState` discard at `start():143`).
- **Completion:** clear `resetIntent` on **establishment-save-confirmed** (`resetEstablishmentSaveDidSucceed` hook, parallel to `resetCommandSaveDidSucceed` `:64/:197`). On `.serverRecordChanged` for the establishment save, `max`-adopt the server generation and clear the intent (a concurrent wipe won — monotonic convergence; both wanted the same outcome; surface nothing).
- **`.deleting`-resume gate wipe arm:** for `wipe` intents the gate fetches `SyncedEstablishment` by fixed ID (there is no command): `generation >= expected` ⇒ our/newer wipe already published ⇒ clear; `zoneNotFound`/none ⇒ re-enqueue delete; transient ⇒ keep. Mirror `runDeletingGate` (`:263`).

- [ ] **Step 1: Failing tests.**

```swift
func testWipeArmWritesOnlyEstablishment_BumpsGeneration_AdvancesToWiping() {
  store.establishmentGeneration = 1
  reset.beginReset(wipe: true, clearRemoteAppSelections: false, now: now)
  reset.handleZoneDeleteConfirmed()
  reset.handleZoneSaveConfirmed()
  XCTAssertEqual(store.establishmentGeneration, 2)
  XCTAssertEqual(store.resetIntent?.stage, .wiping)   // dedicated stage
  XCTAssertTrue(outbox.enqueuedEstablishmentSave)
  XCTAssertFalse(outbox.enqueuedCommandSave)          // MD3: no command
  XCTAssertEqual(seeder.seedAllCount, 0)              // no re-seed
  XCTAssertTrue(localProfiles().isEmpty)              // origin wipes its own data
  XCTAssertEqual(outbox.enqueuedRecordDeletes, 0)     // local-only delete, no funnel deletes into fresh zone
}

func testResumeAtWiping_ReenqueuesOnlyEstablishment_NoCommandNoSeed() {  // crash-durability (B3)
  store.establishmentGeneration = 2
  store.resetIntent = ResetIntent(id: UUID(), clear: false, wipe: true, stage: .wiping, priorCommandId: nil)
  reset.resume()
  XCTAssertTrue(outbox.enqueuedEstablishmentSave)
  XCTAssertFalse(outbox.enqueuedCommandSave)          // MUST NOT publish a reset command on resume
  XCTAssertEqual(seeder.seedAllCount, 0)
}

func testWipeCompletesOnEstablishmentSaveConfirmed() {
  reset.beginReset(wipe: true, clearRemoteAppSelections: false, now: now)
  reset.handleZoneDeleteConfirmed(); reset.handleZoneSaveConfirmed()
  reset.handleEstablishmentSaveResult(.saved)
  XCTAssertNil(store.resetIntent)
}

func testReseedVariantsUnchanged() {                 // regression: variants 1-2 still seed to .seeding
  reset.beginReset(wipe: false, clearRemoteAppSelections: true, now: now)
  reset.handleZoneDeleteConfirmed(); reset.handleZoneSaveConfirmed()
  XCTAssertEqual(store.resetIntent?.stage, .seeding)
  XCTAssertEqual(seeder.seedAllCount, 1)
  XCTAssertTrue(outbox.enqueuedCommandSave)
}
```

- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** the `wipe` field, the `.wiping` stage + `resume()` arm, the `handleZoneSaveConfirmed` wipe branch (local-only delete → bump → establishment save), the establishment-save completion hook, and the wipe `.deleting`-gate arm.
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** — `feat(#310): wipe variant on the reset state machine`.

---

## Task 8: Wipe UX — third variant + two-step confirmation + child lock

**Files:**
- Modify: `Foqos/Views/SettingsView.swift` — third reset entry (`:388-433` region); full-screen confirmation; child-mode gate.
- Test: `FoqosTests/` — a view-model/logic test for the gate + copy (snapshot optional, following the twin-view pattern used elsewhere).

**Interfaces:**
- Consumes: `profileSyncManager.resetSync(wipe:clearRemoteAppSelections:)` (Task 7); `appModeManager.currentMode`.

**Design notes (maintainer-decided 2026-07-12 — two-step flow):**
- **Step 1** = the wipe action entry (a distinct destructive row, separate from the existing two alert buttons).
- **Step 2** = a **full-screen** confirmation that (a) plainly states this deletes everything on **every** device, and (b) **always** includes the V1 caveat, **unconditionally** (no V1-detection): *"Devices still on the old app version won't be affected and should be updated — they can't interoperate with the new sync."*
- **Child-mode lock:** render/enable the wipe entry only when not blocked by the child lock: `appModeManager.currentMode == .child` ⇒ require lock verification (B1 pattern). Use `== .child`, never `!= .parent`.

- [ ] **Step 1: Failing test** — child mode gates the action; confirmation copy contains the unconditional V1 caveat.

```swift
func testWipeRequiresLockInChildMode() {
  let vm = makeSettingsModel(mode: .child, hasLockCode: true)
  XCTAssertTrue(vm.wipeRequiresLockVerification)
}
func testWipeConfirmationAlwaysStatesV1Caveat() {
  XCTAssertTrue(SettingsView.wipeConfirmationBody.contains("old app version"))
}
```

- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** the row, the full-screen confirmation (`.fullScreenCover` or a dedicated confirmation view), and the child gate.
- [ ] **Step 4: Run — expect PASS.** Optionally add twin-view snapshots (parent-enabled / child-locked) following the existing snapshot pattern.
- [ ] **Step 5: Commit** — `feat(#310): totally-delete UX with two-step confirmation + child lock`.

---

## Task 9: Interleaving scenarios (S-W1…S-W6)

**Files:**
- Create: `FoqosTests/WipeInterleavingTests.swift`

Encode §3.1's six interleavings as named, deterministic tests against the mocked engine (the `#267` `MockSyncEngineDriver` + `TestModelContainer` harness, pinned `now`).

- [ ] **S-W1 (I1):** offline peer with a pending gen-`N` `.saveRecord` adopts gen-`N+1` → assert `store.engineState == nil` after adoption and the rebuilt engine's pending queue is empty (the **explicit** discard, not incidental nil-materialization); a pre-adoption re-materialized save is stamped `N` and is `.skippedDeadWorld` on an adopter.
- [ ] **S-W2 (I2):** `beginReset(wipe:)` while `resetIntent != nil` → second call warns and returns; state unchanged.
- [ ] **S-W3 (I3) — the redelivery crux:** over a driver/fake that **honours the change token**, deliver `[profileP(gen N+1), establishment(gen N+1)]` in one batch to a peer at gen `N`. `profileP` → `.skippedNewerGeneration`; assert that **because adoption nulls `engineState`**, the forced token-less re-fetch redelivers `profileP` and it materializes at gen `N+1`. (This test must fail if adoption assumes redelivery without nulling the token.)
- [ ] **S-W4 (I4):** a tombstone (and a `failedApply`) for record X set at gen `N`; adopt gen `N+1`; a legitimately re-created X at gen `N+1` is **not** suppressed (both were cleared).
- [ ] **S-W5 (I5):** a gen-`0` (V1-shaped) profile after a wipe → `.skippedDeadWorld` on every V2 store at gen `≥ 1`; assert the server-record-persists residual is **documented**, not materialized.
- [ ] **S-W6 (I6 / MD2):** a store at gen `0` with local profiles fetches gen `N` → `adoptEstablishmentGeneration(N)` deletes local profiles (adopt-and-discard).
- [ ] **S-W7 (I7) — emergency ledger:** two-peer; A wipes (ledger cleared, gen 1). B (lagging, gen 0) re-pushes its exhausted-epoch record (epoch 5, gen 0) via a `zoneNotFound`/seed recovery → on A the epoch record is `.skippedDeadWorld`; assert `A.currentResetEpoch == 0` (ledger stays cleared, NOT max-merged to 5).
- [ ] **S-W8 (I8) — origin crash at `.wiping`:** origin reaches `.wiping` (gen bumped, establishment enqueued), then a fault before establishment-save-confirmed; on `resume()` assert only the establishment save is re-enqueued (no command, no `seedAll`) and, once confirmed, `resetIntent` clears.
- [ ] **Commit** — `test(#310,#328): wipe interleaving scenarios S-W1..S-W8`.

Run the full suite green on the booted simulator UUID before proceeding.

---

## Task 10: S0 contract amendment + corpus mapping

**Files:**
- Modify: `docs/plans/2026-07-02-sync-engine-design.md` — new `§8.6 "Totally delete all synced data" (wipe / establishment generation)`.
- Modify: `docs/plans/2026-07-02-sync-engine-corpus-mapping.md` — the §3.2 addendum.

- [ ] **Step 1:** Write §8.6 documenting: the establishment record, `establishmentGeneration`, the per-record stamp, the one materialization gate, adoption (discard+reattach+local wipe), the wipe origin arm, MD3 (no command), the scoped "tombstones die with the generation" amendment, and the E-3 inversion justification.
- [ ] **Step 2:** Add the §3.2 corpus-mapping rows (Class A unchanged; B/C/D/E verdicts; the I5 accepted-residual with honest preconditions).
- [ ] **Step 3: Commit** — `docs(#310,#328): S0 §8.6 wipe amendment + corpus mapping`.

*(These docs are tracked — `docs/plans` is **not** gitignored on this repo, verified at plan time. Commit normally.)*

---

## 5. Device verification (acceptance)

The acceptance run is the **delete-and-reinstall recovery scenario** — the escape hatch #310 restores. Boot the simulator once by UUID; device rows need real hardware.

| Row | Scenario | Devices | Pass criterion |
|---|---|---|---|
| DV-1 | On device A, Settings → *Totally delete all synced data* → confirm. Reinstall app on A. | 1 device | After reinstall, A shows an **empty** synced world (no resurrected profiles, emergency ledger reset). The wipe stuck through reinstall. |
| DV-2 | Two V2 devices A+B on one iCloud account, both with profiles. Wipe on A. | **2 devices** | B receives the higher generation, discards its local synced data (MD1 notice if surfaced), and does not re-seed. Both converge to empty. |
| DV-3 | A wipes; B is **offline** during the wipe, then comes online. | **2 devices** | B's queued pre-wipe edits do not resurrect data; B adopts and wipes on first fetch (I1/S-W1). |
| DV-4 | Exhausted emergency-unblock ledger (the motivating case): exhaust it on A, wipe, reinstall. | 1 device | Ledger is cleared; emergency unblock available again. |
| DV-5 | **Mixed V1/V2:** one V1 device + one V2 device on one account, both hold the same profiles. Wipe on V2. | **2 devices (one V1, one V2)** — device probe #326 | The V2 device stays empty (never materializes V1's re-pushed profiles). The server record may persist while V1 re-pushes (expected, honest — the confirmation warned). Update V1 → V2 and confirm it adopts-and-discards (MD2). |
| DV-6 | Wipe on A while B is mid-fetch (rapid edit on B during A's wipe). | **2 devices** | No husk resurrection on either device; both converge empty (I3/S-W3). |

DV-2, DV-3, DV-5, DV-6 require two devices; DV-5 specifically needs one V1 + one V2 (the #326 probe pair). DV-1 and DV-4 are single-device.

---

## 6. Self-review (run against the spec after writing)

- **Spec coverage:** #310 seed mechanism → Tasks 1–7; V1 coexistence + honest UX → Tasks 5,8 + DV-5; #328 convergence (generation-less discard) → Task 5/S-W5; the six interleavings + the two the adversarial pass added (I7 ledger, I8 crash) → Task 9 (S-W1..S-W8); S0 amendment → Task 10. ✔
- **No placeholders:** every code step shows real Swift grounded in a cited seam. ✔
- **Type consistency:** `establishmentGeneration` (store), `SyncedEstablishment` (record), `generation` (per-record field on 4 types), `generationGate`, `adoptEstablishmentGeneration`, `wipeLocalSyncedEntitiesForGeneration`, `clearGenerationScopedBookkeeping`, `clearLedgerForGenerationAdoption`, `enqueueEstablishmentSave`, `.skippedDeadWorld`/`.skippedNewerGeneration`, `.wiping`, `resetSync(wipe:)` — used identically across tasks. ✔
- **Invariant tensions resolved:** I3 (`processedResetCommandIds` kept), I4 (tombstones + `failedApplies` cleared on generation flip only — scoped), E-3 (inverted only for the consented wipe). ✔
- **Adversarial findings folded:** the five §1.6 defects are each addressed by an edited task and a named test. ✔
- **STOP-boundary:** no §8.1 protocol defect; all additive; the `.wiping` stage keeps variants 1–2's resume arm intact. ✔

---

## Execution Handoff

**Plan complete.** Implementation is a separate session (per the brief). When executing:
1. **Subagent-Driven (recommended)** — fresh subagent per task, two-stage review, Task 0 first.
2. **Inline** — executing-plans with checkpoints.

Confirm **MD1** and **MD2** with the maintainer before Task 6 / Task 8. Sequential bundle rules apply (one build/test stream per machine; branch from `main` after any prior PR merges).
