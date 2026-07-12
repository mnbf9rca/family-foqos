# V1→V2 Family Upgrade Safety Audit

> Recovered from workflow `wf_00ee0b71-aa0` (`v1-v2-family-upgrade-audit`), status: **completed**, 9 agents, 18.6 min. Synthesis ran on the session model (Fable 5); output is reproduced here verbatim from the workflow result file.

## Audit Scope & Permutations (inputs)

The audit was a 3-phase fan-out (Ground → Attack → Synthesize) run **read-only** against the checkout at `/Users/rob/Downloads/git/family-foqos`, reading other branches via `git show`. Branches compared: **`main`** = V2 (trigger profiles, CKSyncEngine transport with tombstones / delete watermarks / reset commands / emergency event ledger+epoch, family layer) vs **`release/v1`** = V1 track (old CKQuery-based sync coordinator, bridge release **v1.31.2** adding schema-version awareness). Two independent sync planes were treated as separate throughout: the **same-user profile plane** (private `DeviceSync` zone) and the **family plane** (lock codes, FamilyCommand, heartbeats, FamilyRoot share).

**Dimensions crossed to form each permutation:**

| Dimension | Values |
|-----------|--------|
| Topology | 1P1C, 1P2C, 2P1C, 2P2C (P = parent/adult account, C = child) |
| Upgrade order | Parent-first (P=V2, C=V1), Child-first (C=V2, P=V1), and mixed children (one V1, one V2) |
| Same-user split | Any one member's *own* 2+ devices straddling V1/V2 — treated both as its own row and as an override on any otherwise-SAFE row |
| Share ownership | Single-owner vs two-owner (both adults share-owners) — the D5 divergence |
| V1 build age | Bridge (≥v1.31.2, schema-aware) vs pre-bridge (≤v1.31.1, zero schema awareness) |

That cross-product is what the [safety matrix](#combination-safety-matrix) enumerates as 12 rows.

### Phase 1 — Ground (3 agents, opus)

| Slice | Question established |
|-------|---------------------|
| `ground:migration` | main's V1→V2 profile migration (`migrateToV2IfNeeded`): triggers, atomicity, active-session deferral, `profileSchemaVersion` stamping, fate of `blockingStrategyId`; whether the bridge actually shipped to `release/v1`; whether the old "V2 auto-heals by force-push" mechanism survived the S0 rewrite |
| `ground:sync-plane` | Same-user private-DB `DeviceSync` zone under mixed engines (V1 CKQuery vs V2 CKSyncEngine): which V2-only record types V1 queries would see, deletion-semantics collisions & resurrection paths, field-clobber on profile edits, reset sync from either side |
| `ground:family-plane` | Whether `release/v1` contains any family layer (FamilyRoot, FamilyLockCode, FamilyCommand, DeviceHeartbeat, child/parent modes, locked/managed profiles); what a V2 parent sees for a V1 child; enrollment/share acceptance during a mixed window; who owns locked-profile records |

### Phase 2 — Attack (5 adversarial slices, opus)

| Slice | Focus | Scenarios probed |
|-------|-------|------------------|
| A `same-user-split` | Private-DB plane, one user's split-version devices | A1 concurrent edit; A2 V1 edits a migrated trigger profile; A3 delete vs tombstone/watermark (both directions); A4 V2-only records seen by V1 queries; A5 reset from V2 side; A6 reset from V1 side; A7 upgrade completes mid-operation |
| B `p2-c1` | Parent-first (P=V2, C=V1), family plane | B1 lock code never enforced on V1 child; B2 locked profile owned by child on V1; B3 Reset/Emergency commands unprocessed; B4 heartbeats absent on dashboard; B5 emergency-unblock ledger never written; B6 child enrolls while still V1 |
| C `p1-c2` | Child-first (C=V2, P=V1), family plane | C1 V2 child expects commands a V1 parent can't send; C2 child-mode UI promises with no parent counterpart; C3 emergency ledger/epoch with no parent visibility; C4 parent later upgrades — clean converge or double-init; C5 V2 child writes a V1 parent might mangle |
| D `multi-adult` | 2P1C / 2P2C, split versions between adults | D1 P1=V2 sets lock code, P2=V1 override/corrupt; D2 both parents command one child; D3 multi-parent share support (verify not dead code); D4 second adult upgrades mid-enrollment; D5 split-version own devices composed with slice A |
| E `destructive-mixed` | Destructive/global ops during any mixed window | E1 cross-version profile delete; E2 reset sync / total-delete; E3 emergency-unblock budget divergence; E4 the upgrade itself as destructive event (bridge vs pre-bridge); E5 restore of a V1 backup onto an upgraded device; E6 app-group SharedData & DeviceActivity registrations across the update window |

### Phase 3 — Synthesize (1 agent, session model)

Consumed the grounding facts + all five slices' verdicts and produced: the combination matrix below, deduplicated root-cause gaps, proposed issues (release-blocking vs acceptable documented residual), and the minimal device-probe list for UNKNOWNs — resolving slice disagreements by re-reading code, not by vote.

## Combination Safety Matrix

## Combination matrix — topology x upgrade order

Verdict rule: a combination is SAFE only if EVERY applicable scenario is SAFE with a cited mechanism. Two planes apply to every row: the **family plane** (FamilyPolicies shared zone: lock codes, commands, heartbeats) and the **same-user profile plane** (private DeviceSync zone, applies whenever ONE person's own devices straddle V1/V2). The same-user split is listed both as its own row and as a dimension that overrides any otherwise-SAFE row.

| # | Topology | Upgrade order / split | Verdict | Binding scenarios (worst first) |
|---|----------|----------------------|---------|--------------------------------|
| 1 | 1P1C | Parent first (P=V2, C=V1) | **UNSAFE (critical)** | B1 Leave-Family fail-open voids all parental locks on the V1 child (release/v1:ChildDashboardView.swift:537,571-575) + no PIN throttle; B3 false-success reset commands; B4 child invisible in Device Status; B5 no emergency ledger |
| 2 | 1P1C | Child first (P=V1, C=V2) | **SAFE** | C1–C5 all SAFE: FamilyLockCode wire-identical (whitespace-only diff), V2 child fail-closed (origin/main:LockCodeManager.swift:203-232), child mode entered autonomously (ModeSelectionView.swift:16), FamilyRoot fixed-name/owner-only (no double-init, C4). Residual: V1 parent lacks FamilyCommand — throttle auto-expires ≤15 min, so no wedge |
| 3 | 1P2C | Parent first (both C=V1) | **UNSAFE (critical)** | B1 on each V1 child (children's planes are independent; defect applies per child) |
| 4 | 1P2C | Children first (both C=V2) | **SAFE** | Superposition of row 2 per child; no child-child interaction (separate private DBs, separate share participants) |
| 5 | 1P2C | Mixed children (one V1, one V2) | **UNSAFE (critical)** | B1 on the V1 child; the V2 child is row-2-safe |
| 6 | 2P1C | Any order, child stays V1 | **UNSAFE (critical)** | B1; co-parent adds nothing new — D1–D4 SAFE because a participant parent's lock-code/command writes land in its OWN private zone, never the owner's shared zone (origin/main:CloudKitNetworkService+LockCodes.swift:21,51; release/v1:CloudKitManager.swift:326-381), so it cannot corrupt or duplicate |
| 7 | 2P1C | Child upgrades to V2, two adults both share-OWNERS | **UNKNOWN (high if reachable)** | D5: V2 child reads ONE shared zone (`zones.first`, origin/main:CloudKitNetworkService.swift:52-58) vs V1 aggregating ALL zones (release/v1:CloudKitManager.swift:436-447); if the codeless owner's zone is picked, empty-connected is treated as "code cleared" (LockCodeManager.swift:200-206) → silent lock-gating drop. Needs probe P1 |
| 8 | 2P1C | Child upgrades to V2, single-owner + participant co-parent | **SAFE** | Reduces to row 2 (C1–C5) + D1–D4 SAFE (inert participant) |
| 9 | 2P2C | Any | Worst of rows 3/5/7 per child | UNSAFE (critical) if any child V1 (B1); UNKNOWN (D5) on any child upgrade under a two-owner topology; SAFE only when all children V2 + single-owner |
| 10 | **Same-user split** (any household member's OWN devices on V1+V2 — guaranteed at release) | Steady-state edit/delete | **UNSAFE (high)** | A3/E1c: V2 delete + concurrent V1 edit resurrects the profile on all other V2 devices (local-only tombstones, SyncEngineStore.swift:149-179; suppress-only skippedPendingDelete). E3: emergency budget forks per version group (3+3=6). A1/A2/E1a/E1b/E4-bridge/E5/E6 are SAFE (schema gate + field preservation + auto-heal + new-key-wins, all cited in slices) |
| 11 | Same-user split | Reset Sync used, either direction | **UNSAFE (high)** | A5/E2a: V2 deleteZone → V1 zoneNotFound early-return skips reconciliation, re-pushes, resurrects (release/v1:ProfileSyncManager.swift:492-495, verified verbatim); V1 hard-deletes V2's fixed-name reset command, starving sibling V2 devices (:406). A6/E2b: V1 reset leaves V2-only Emergency records and V2 reseeds, undoing the wipe |
| 12 | Same-user split | Any device still pre-bridge (≤v1.31.1) | **UNSAFE (high)** | E4-prebridge: zero schema awareness (grep profileSchemaVersion on v1.31.1 = empty) + NO min-version gate in either branch → V2 profiles fully editable with V1 semantics |

**Settled by code-read (was UNKNOWN A1b):** the equal-version tie-break divergence on a deferred-migration (schema-1, active-session) profile is unreachable via the V2 edit form — `ProfileEditGate.editingDisabled` includes `isBlocking` (origin/main:Foqos/Utils/ProfileEditGate.swift:8-16), `isBlocking` = global active session (BlockedProfileView.swift:115-117), and the save button renders only `if !editingDisabled` (:668). The deferred profile is by definition the one with the active session. Verified this session, not by vote.

**Net:** the only unconditionally SAFE paths are child-first upgrades with single-owner families AND no member running split-version own devices AND nobody touching Reset Sync. Since the premise guarantees split windows, rows 10–12 make the release unsafe as-is; the bridge (confirmed shipped in v1.31.2) protects steady-state profile EDITS as designed, but was never built to protect DELETES, RESETS, or the family plane.

## Root-Cause Gaps

Seven deduplicated root causes behind every UNSAFE/UNKNOWN:

**G1 — Deletion intent never reaches the server.** V2 tombstones are device-local UserDefaults (origin/main:Foqos/CloudKit/SyncEngine/SyncEngineStore.swift:149-179, verified this session); `applyFetchedModification` suppresses a resurrected record locally but never re-deletes the server copy. Any V1 fetch-then-save re-push resurrects deleted profiles fleet-wide. Drives A3/E1c.

**G2 — Destructive ops (Reset Sync) assume a homogeneous engine.** Three sub-failures, one root cause: (a) V2's deleteZone hits V1's zoneNotFound early-return (release/v1:ProfileSyncManager.swift:492-495, verified this session) so reconciliation never runs and V1 re-pushes into the reset zone; (b) V1 hard-deletes V2's fixed-name 'sync-reset-command' record (:406), starving sibling V2 devices; (c) V1's reset enumerates only the 4 record types it knows, leaving V2 Emergency records, and V2's applyCommand reseeds, undoing the wipe. Drives A5/A6/E2a/E2b.

**G3 — V1's Leave-Family fail-open + no PIN throttle (pre-existing, LIVE today).** `hasLockCode = !sharedLockCodes.isEmpty` on a non-persisted in-memory array that is empty on offline cold-launch or any fetch failure → no PIN required to leave the family and drop all isManaged enforcement (release/v1:ChildDashboardView.swift:537,571-575); verifyCode has no attempt limit. V2 fixed both (#197 fail-closed-with-cache; throttle). Not caused by the mixed window, but it is the universal escape hatch from every V2 parent's locks while any child stays on V1. Drives B1 and poisons rows 1/3/5/6/9.

**G4 — Family plane has no version/capability signal, and the parent UI reports success at save-time.** FamilyCommand and DeviceHeartbeat are V2-only record types with no V1 counterpart; `showResetSuccess = true` fires when the CKRecord saves (origin/main:ParentDashboardView.swift:1114-1119), not when consumed; V1 children never heartbeat so they render as "No Devices" with copy implying no child activated a profile (:550-558). Drives B3/B4/B5 — dishonest-degraded, not data loss.

**G5 — Emergency-unblock accounting forked per version.** V1: local AppStorage counter, self-resetting (release/v1:StrategyManager.swift:39-42,576); V2: synced ledger. A split fleet gets double the budget and the parent has zero oversight of V1 consumption. Drives E3/B5.

**G6 — No minimum-version / forced-upgrade gate anywhere.** Pre-bridge v1.31.1 has zero schema awareness (grep empty) and nothing stops it participating; the entire "V2 read-only on V1" contract silently evaporates on holdouts. The bridge itself DID ship in v1.31.2 (verified: tag contains the guards, v1.31.1 does not) — the gap is enforcement of the floor, not the bridge. Drives E4-prebridge.

**G7 — V2 child reads ONE shared FamilyPolicies zone where V1 read ALL (UNKNOWN).** `zones.first { zoneName == "FamilyPolicies" }` (origin/main:CloudKitNetworkService.swift:52-58, verified this session) vs V1's for-loop aggregation (release/v1:CloudKitManager.swift:436-447, verified). Combined with empty-connected="cleared" semantics, a two-owner child that upgrades could silently lose lock gating. Reachability of the two-owner topology and zone ordering both unconfirmed — probe P1. Drives D5.

Where slices disagreed: the incoming premise "V1 never enforces" was wrong — slice B's correction stands (V1 DOES gate isManaged edit/delete, fail-closed, release/v1:BlockedProfileView.swift:122-124); the real hole is G3. Slice A's A1b UNKNOWN was settled SAFE this session by reading ProfileEditGate. No remaining inter-slice contradictions.

## Proposed Issues

### 1. Reset Sync never converges while any V1 device is signed in (both directions)

**Severity:** RELEASE-BLOCKING (high)

Pressing Reset Sync on a V2 device wipes the shared zone, but a V1 device treats the missing zone as 'nothing to sync' and quietly re-uploads everything it has — deleted and stale profiles come back on every device. In the other direction, a reset from a V1 device leaves V2-only emergency records untouched and V2 devices re-seed their profiles, undoing the wipe. V1 also deletes V2's reset-command record after reading it, so other V2 devices may never learn a reset happened.

Evidence: origin/main:Foqos/CloudKit/SyncEngine/ResetController.swift:112-127 (deleteZone), :77/:190 (fixed-name command); release/v1:Foqos/CloudKit/ProfileSyncManager.swift:492-495 (zoneNotFound early-return skips reconciliation — verified verbatim this session), :406 (command hard-delete), deleteAllSyncedData :729-782 (only 4 known record types); origin/main:SyncEngineController.swift:357 (no recordName filter on inbound reset commands).

Scope: same-user split-version fleets — guaranteed at V2 release. Scenarios A5/A6/E2a/E2b.

Suggested fix direction: gate or warn on Reset Sync while any same-user device was last seen writing schema<2 records (a lightweight version-presence record in the zone would give V2 that signal); alternatively make V2's reset delete records individually instead of the zone so V1's reconciliation path still runs.

### 2. Deleting a profile on V2 can silently bring it back on other devices while a V1 device is in the fleet

**Severity:** RELEASE-BLOCKING (high)

Delete a profile on a V2 device while a V1 device is editing it: the V1 device re-saves the record to CloudKit. The deleting device hides it forever (local tombstone) but never deletes the server copy again, so every OTHER V2 device recreates the profile. A profile a parent deleted comes back on the child-facing devices and stays gone only on the device that deleted it.

Evidence: origin/main:Foqos/CloudKit/SyncEngine/SyncEngineStore.swift:149-179 (tombstones are device-local UserDefaults — verified verbatim this session); SyncApplyService applyFetchedModification returns .skippedPendingDelete (suppress-only, no re-delete); release/v1:ProfileSyncManager pushSyncedProfile fetch-then-save resurrects.

Scope: same-user split-version fleets; worst when the resurrected profile is parent-managed. Scenarios A3/E1c.

Suggested fix direction: when a fetched modification matches a tombstoned recordName, re-enqueue .deleteRecord instead of only suppressing — the tombstone already stores the recordName and changeTag needed.

### 3. V1 child can drop all parental locks with no PIN (Leave Family fail-open) and brute-force PINs without limit — live in the App Store today

**Severity:** RELEASE-BLOCKING (critical) — fix ships in V1, before V2

On a V1 child device, launch offline (or any iCloud fetch hiccup): the lock-code list is an in-memory array that starts empty, so the 'Remove Parental lock and switch to Individual Mode' button asks for NO PIN. The child leaves the family and every managed-profile restriction disappears. Separately, V1 PIN entry has no attempt limit, so a 4-digit code can be brute-forced. V2 fixed both (#197 fail-closed-with-cache; throttle) — but every family with a V1 child inherits the bypass, making it the universal escape hatch from a V2 parent's locks during the mixed window.

Evidence: release/v1:Foqos/Views/Child/ChildDashboardView.swift:537 (hasLockCode = !sharedLockCodes.isEmpty), :571-575 (no-PIN leave path); release/v1:Foqos/CloudKit/CloudKitManager.swift:32 (non-persisted @Published array); release/v1:Foqos/Utils/LockCodeManager.swift:206-238 (no throttle). Probe P3 confirms in the shipping binary.

Scope: any topology with a V1 child (matrix rows 1/3/5/6/9); pre-existing V1 defect, not caused by V2.

Suggested fix direction: V1 point release backporting V2's fail-closed-with-cache resolve logic and requiring the PIN whenever a code was EVER cached; ship and reach adoption BEFORE V2 releases.

### 4. No minimum-version gate: pre-bridge V1 installs (v1.31.1 and older) treat V2 profiles as fully editable

**Severity:** RELEASE-BLOCKING pending adoption data (high)

The v1.31.2 bridge DID ship and works as designed (verified: the tag contains the schema guards; v1.31.1 does not). But nothing forces devices onto it: a v1.31.1 device has zero schema awareness, shows a V2 trigger-based profile as an ordinary editable V1 profile, and pushes schema-1 edits back. There is no minimum-version, forced-upgrade, or kill-switch mechanism in either branch (grep empty on both).

Evidence: git show v1.31.1:Foqos/Models/BlockedProfiles.swift has no profileSchemaVersion; v1.31.2:.../SyncCoordinator.swift:110/:197/:460/:481 carry the guards.

Scope: pre-bridge holdout installs only. Probe P2 (App Store version-adoption) decides: near-zero holdouts → downgrade to documented residual; otherwise a version floor must ship before V2.

Suggested fix direction: add a minimum-supported-version record/check to the sync zone that pre-V2 releases can honor going forward, plus an App Store phased-release plan that confirms bridge saturation before V2 rollout.

### 5. Parent dashboard misleads about V1 children: resets show success but do nothing; active children show as 'No Devices'

**Severity:** Fix-before-release (medium) — UI honesty, no data loss

A V2 parent's 'Reset PIN Attempts' / 'Reset Emergency Count' shows a green success checkmark the moment the command record saves — but a V1 child has no command reader, so nothing happens, ever. The same child never sends heartbeats, so the Device Status section shows 'No Devices' with copy implying no child has activated a profile, even while the child is actively blocking. The parent cannot tell enforcement state at all.

Evidence: origin/main:Foqos/Views/Parent/ParentDashboardView.swift:1114-1119 (success on save), :550-558 (No Devices empty state); FamilyCommand/DeviceHeartbeat absent from release/v1 (git ls-tree); commands orphaned unprocessed.

Scope: parent=V2 + child=V1 window (matrix rows 1/3/5/6/9). Per our residual rule, degraded behavior is acceptable only if honest — this currently is not.

Suggested fix direction: show commands as 'sent — not yet confirmed by device' until consumed (child deletes the record on processing, which V2 children already do); change the empty Device Status copy to say the device may be on an older app version; both are UI-only changes.

### 6. Emergency-unblock allowance doubles across a mixed V1/V2 fleet

**Severity:** Documented residual (medium)

V1 counts emergency unblocks in a local on-device counter; V2 counts them in a synced ledger. A person with one V1 and one V2 device gets two independent allowances (3+3), and a parent sees none of the V1 usage. The counter does carry over correctly when a single device upgrades (no refill), so this is strictly the split-fleet window and self-heals once all devices are on V2.

Evidence: release/v1:Foqos/Utils/StrategyManager.swift:39-42/:576 (local AppStorage counter, never synced); origin/main:Foqos/Utils/UserDefaultsMigration.swift:16 (counter carried over on upgrade); V1 never queries Emergency record types.

Scope: same-user split fleets; a self-limit tool, not a lock bypass of parent-owned locks.

Suggested fix direction: accept and document in release notes ('emergency unblock limits are per-device until all your devices update'); no code change proposed.

### 7. Child on V2 may lose lock enforcement if enrolled by two separate parent accounts (needs device probe)

**Severity:** UNKNOWN — high if reachable; probe P1 before triage

V1 read lock codes from ALL family zones shared to the child; V2 reads exactly ONE (first zone named FamilyPolicies). If two adults each independently created a family and both enrolled the same child device, and only one set a code, a child upgrading to V2 could have the codeless zone picked — and an empty-but-connected result is treated as 'parent cleared the code', silently removing managed-profile gating. Unconfirmed: whether the two-owner setup is reachable through supported flows, and whether CloudKit can order the codeless zone first.

Evidence: origin/main:Foqos/CloudKit/CloudKitNetworkService.swift:52-58 (zones.first — verified this session); release/v1:Foqos/CloudKit/CloudKitManager.swift:436-447 (all-zone aggregation — verified this session); origin/main:Foqos/Utils/LockCodeManager.swift:200-206 (empty-connected clears cache).

Scope: 2-parent topologies where both adults are share OWNERS (matrix rows 7/9); scenario D5.

Suggested fix direction: make V2's child read aggregate codes across ALL shared FamilyPolicies zones (matching V1) — cheap, safe, and worth doing even if the probe shows the topology is hard to reach.

## Device Probes (to settle UNKNOWNs)

Minimal probe set (A1b probe REMOVED — settled by code-read of ProfileEditGate this session):

**P1 — settles G7/D5 (the only verdict-flipping UNKNOWN).** Two distinct parent iCloud accounts each create a family and enroll the SAME physical child device (this also answers whether the two-owner topology is reachable via supported flows — if it isn't, D5 downgrades to low). Set a lock code on parent A only. Run the V2 child build; log `sharedDatabase.allRecordZones()` ordering, the zone `findSharedZoneByName` picks, and resulting `cachedLockCodes`; then attempt to edit a managed profile without a code. If the codeless zone can be picked and gating drops → D5 = UNSAFE/high. Note: aggregating all FamilyPolicies zones on V2 (matching V1) is a cheap fix worth shipping regardless of the probe outcome.

**P2 — settles G6 exposure (data check, not a device).** App Store Connect version-adoption: what fraction of live installs is ≤v1.31.1 (pre-bridge)? If effectively zero, issue 4 downgrades from release-blocking to documented residual; if non-trivial, a min-version gate must ship before V2.

**P3 — confirms G3 in the shipping binary (pre-filing sanity, expected to confirm).** On the actual App Store V1 build: enroll a child device, then cold-launch it in airplane mode and tap "Remove Parental lock and switch to Individual Mode". Branch code says no PIN is requested; confirm on the binary since branch tip (v1.31.3/589bee9) may be ahead of what shipped.

**P4 — optional, cannot flip any verdict (C5 residual).** With a V1 parent-created share, check the V2 child participant's CKShare permission (readOnly vs readWrite). If readOnly, child heartbeat/FamilyMember writes fail silently — both fire-and-forget, so worst case is a monitoring blind spot already covered by issue 5.

Explicitly NOT needed: probes for reset non-convergence (G2), tombstone resurrection (G1), or edit-form gating (A1b) — all mechanisms were verified line-by-line on both branches this session.

## Adversarial Slice Summaries

### Slice: same-user-split

- SAFE:low A1 — Concurrent edit of the SAME profile on V1 and V2 during a split window (nor
- UNKNOWN:medium A1b — Equal-version concurrent edit of a still-schema-1 (deferred-migration, act
- SAFE:low A2 — V1 edits a V2-migrated (trigger-based) profile: triggers lost / clobbered /
- UNSAFE:high A3 — Delete on one side vs the other side's tombstone/watermark: resurrection in
- SAFE:none A4 — V2-only records (EmergencySettings, EmergencyResetEpoch, EmergencyUnblockEv
- UNSAFE:high A5 — Reset sync issued from the V2 side (deleteZone + reseed) while a V1 device 
- UNSAFE:medium A6 — Reset issued from the V1 side against V2 engine state (does V1 have resetSy
- SAFE:low A7 — Upgrade completes mid-anything: migration runs on a device that had pending

### Slice: p2-c1

- UNSAFE:critical B1 — V2 parent sets/changes lock code; does the V1 child enforce it, and what do
- SAFE:none B2 — V2 parent marks a profile isManaged/locked; the V1 child owns the profile r
- UNSAFE:medium B3 — V2 parent issues Reset PIN / Reset Emergency Count commands against the V1 
- UNSAFE:medium B4 — V1 child writes no heartbeats. What does the V2 parent's Device Status dash
- UNSAFE:medium B5 — V2 parent expects an emergency-unblock event ledger the V1 child never writ
- SAFE:none B6 — V1 child enrolls / accepts the family share while still on V1.

### Slice: p1-c2

- SAFE:low C1: V2 child expects lock codes/commands from a V1 parent that cannot send them 
- SAFE:low C2: child-mode UI promises (locked profiles, PIN dialogs) with no parent-side co
- SAFE:low C3: child emergency-unblock ledger/epoch with no parent visibility
- SAFE:none C4: parent on V1 later upgrades to V2 — does family state converge cleanly or do
- SAFE:low C5: anything the V2 child WRITES to the shared plane that a V1 parent build migh

### Slice: multi-adult

- SAFE:medium D1 — P1=V2 sets a family lock code (P1 is the family/share OWNER), P2=V1 is a co
- SAFE:medium D2 — Both parents issue commands (e.g. resetEmergencyCount / resetLockCodeThrott
- SAFE:low D3 — Is multi-parent actually supported on main, or is parent-share acceptance d
- SAFE:none D4 — A second adult (co-parent) upgrades V1→V2 mid-enrollment of a child (partwa
- UNKNOWN:high D5 — Each adult also owns split-version devices. TWO independent parent OWNERS e
- SAFE:low D-adjacent — Owner's participant-sync reconciliation deleting a co-parent's Fami

### Slice: destructive-mixed

- SAFE:none E1a — Profile delete V2→V1 (steady mixed window). V2 device deletes a profile; d
- SAFE:none E1b — Profile delete V1→V2 (steady mixed window).
- UNSAFE:medium E1c — Concurrent V1 edit + V2 delete of the same profile: resurrection / husk ac
- UNSAFE:high E2a — Reset sync issued by a V2 device (deleteZone) during a mixed window; effec
- UNSAFE:high E2b — Reset / totally-delete issued by a V1 device during a mixed window; effect
- UNSAFE:medium E3 — Emergency unblock consumed on a V1 device vs V2 synced ledger: budget diver
- SAFE:none E4-bridge — The upgrade as the destructive event: a V2 device migrates profiles 
- UNSAFE:high E4-prebridge — Same upgrade, but a remaining V1 device is PRE-bridge (v1.31.1 or
- SAFE:low E5 — Restoring a V1 device backup onto a device that then runs V2 (iCloud/iTunes
- SAFE:none E6 — App-group SharedData + DeviceActivity registrations across the upgrade wind

## Post-audit corrections (2026-07-12 backlog cross-reference)

A second pass (7 independent verification agents re-checking every load-bearing citation, plus maintainer input) corrected the following before backlog integration:

- **Population fact (lowers several severities):** v1.31.3 has been the live App Store build for ~6 months at ~200 downloads/90 days. Pre-bridge installs (≤v1.31.1) are believed near-zero, so E4-prebridge / matrix row 12 drops from "build a min-version mechanism" to a pre-release App Store Connect analytics check (epic #263, release readiness).
- **Rows 10–11 narrowing:** the v1.31.2+ bridge refuses edits/re-pushes of schema-2 profiles, so mixed-window resurrection is limited to **schema-1 records** — i.e. profiles V2 defers migrating while a session is active (which are precisely the in-use ones), plus reset-command starvation (no schema guard). Still real; narrower than the matrix states.
- **G4 undercount:** the save-time-success defect exists on BOTH command paths — `resetEmergencyCount` (ParentDashboardView.swift:1114/1118) AND `resetLockCodeThrottle` (:1154/:1158).
- **Emergency-budget correction:** "counter carries over on upgrade" is wrong — `family_foqos_emergency_unblocks_remaining` is read only by the migration and tests; an upgraded device starts a fresh ledger allowance.
- **D5 severity overstated:** `acceptCloudKitShare` (FoqosApp.swift:462) blocks joining a second family whenever a FamilyPolicies zone exists, and both share-entry points funnel through it; the residual is a TOCTOU double-accept race (guard not re-checked in `completeShareAcceptance`, :514). Downgraded to a device probe + cheap aggregate-all-zones hardening (tracked on #326).
- **B1 sharpening:** the CKShare leave requires connectivity, so "offline = no PIN" overstates; the dependable window is the online cold-launch race before the async lock-code fetch lands (the PIN gate is bypassed either way).
- **Backlog disposition (2026-07-12):** #328 (reset convergence), #329 (delete resurrection, stacked on #315), #330 (V1 fail-open — accepted risk, no V1 release), #331 (dashboard honesty), #332 (emergency-budget release note); #310 gained a V1-coexistence constraint; #326 gained mixed-version device rows; min-version gate became an epic release-readiness checklist row. Maintainer decisions: no further V1 releases; epic #263 completes before V2 ships.
