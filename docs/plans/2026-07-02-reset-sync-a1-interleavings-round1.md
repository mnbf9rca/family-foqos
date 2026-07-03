# A1 adversarial verification — round 1 findings (verbatim)

- **Target design:** rev 2 (persisted gate cleared on zero-failure push)
- **Context:** acceptance corpus for #267; see `2026-07-02-reset-sync-a1-acceptance-corpus.md`.
- **Provenance:** machine-extracted, unedited output of the independent verifier agents.

## Lens: interleavings — verdict: has-holes

**Verifier reasoning:**

> Method: read the spec (/Users/rob/Downloads/git/family-foqos/docs/superpowers/specs/2026-07-02-reset-sync-safety-design.md) and the pre-fix implementation it modifies (/Users/rob/Downloads/git/family-foqos/Foqos/CloudKit/ProfileSyncManager.swift — resetSync:823-877, pullResetRequests:373-417, pushSyncedProfile:430-465; /Users/rob/Downloads/git/family-foqos/Foqos/CloudKit/SyncCoordinator.swift — handleSyncedProfiles:104-209, handleSyncedLocations:423-507, handleSyncReset:529-560, rePushLocalSyncedData:563-593, pushLocalData:45-100, pushTask chaining; /Users/rob/Downloads/git/family-foqos/Foqos/CloudKit/SyncModels.swift — SyncResetRequest:543-599; SyncEventDelegate.swift; isNewerSchemaVersion at /Users/rob/Downloads/git/family-foqos/Foqos/Models/BlockedProfiles.swift:712). I then walked the POST-fix protocol (marker save → gate set → typed wipe → delegate → re-push → conditional gate clear → follow-up sync; and the classify loop) and at every await point injected: origin crash, concurrent performFullSync, a second reset from a third device, pre-existing in-flight push tasks, and clock skew, checking each of the spec's 18 interleaving rows.
> 
> The design's two guards (A2 empty-pull skip; A3 persistent gate) are individually correct for the cases the spec tables enumerate, but the composition has a structural flaw: THE GATE-CLEAR CONDITION IS UNSOUND. 'A complete local re-push finished with zero per-record failures' is treated as proof that this device's data is back in the zone, but a CloudKit push ack does not survive a concurrent snapshot-based wipe — the origin's deleteAllSyncedData (or a second origin's) can delete acked records after the ack. Every path that clears the gate while any wipe/re-push is in flight reopens exactly the #195 window the design set out to close: (1) receiver re-push racing the origin's own wipe — no second reset, no index lag, no crash needed; (3) a clean push attributed to reset N (or to a pre-reset pushLocalData task) clearing the gate reset N+1 just set — the spec specifies no CAS semantics. Additionally (2) spec row 6 is factually wrong: near-simultaneous resets mutually delete each other's markers (SyncResetRequest is wiped LAST, giving both markers time to be query-visible to the other wipe), leaving third devices with no marker, no gate, and a partial zone — mass local deletion plus a delivery/liveness break. (4) The isNewerSchemaVersion filter in both push paths means read-only newer-schema profiles are never re-pushed yet stay deletion-eligible, so a device's own 'clean' re-push disarms its gate and the follow-up pass deletes them — this also falsifies the spec's stated constraint that pushLocalData re-pushes ALL local profiles. (5) Row 12's accepted clock-skew outcome actually includes full data loss (a poisoned watermark classifies a later live reset .skipAlreadyProcessed, so no gate is set during its destructive window), not just a skipped selection-clear.
> 
> What survives: A1 (marker-before-wipe) genuinely kills the durable-landmine variant (#195.3); A2 is sound for truly-empty pulls; B1-B6 deliver-to-all/GC/no-loop liveness holds except for the mutual-marker-annihilation case in finding 2; rows 1-5, 7, 10-11, 13-15, 18 check out as claimed; the watermark-advance-before-task rule (B6) does prevent the reset loop.
> 
> Cross-cutting fix that closes findings 1, 3, and 5 with one rule: suppress deletion reconciliation in any pass whose pullResetRequests observed ANY within-TTL reset marker, regardless of classification — markers persist ≤7 days by design (B4), so protection spans the whole wipe+re-push window without depending on gate-clear timing; the cost (deletion propagation deferred ≤TTL after a reset) is the trade the spec's own safety asymmetry endorses. Finding 2 needs the wipe to exclude ALL non-expired markers (not just its own); finding 4 needs isNewerSchemaVersion profiles exempted from reconciliation deletion. Verdict: has-holes — four concrete safety-breaking interleavings against the post-fix design as written, two of which (1 and 2) require no exotic conditions at all.

### interleavings-1 [breaks-safety] Receiver's clean re-push races the origin's still-in-flight wipe: gate clears, next pass reconciles against a partial zone and deletes local profiles

**Violated:**

Safety property (P1 was never genuinely deleted anywhere; loss is not covered by exception (a) or (b)). Contradicts spec row 16 ('remoteIds non-empty partial + gate set ⇒ Skip (A3)') and A3's claim that the gate protects 'across the entire re-push window' — the design's own zero-failure clear rule removes the gate while the origin's wipe is still in flight. Root cause: a successful push ack does not mean the record is durably in the zone when a snapshot-based wipe is concurrent; 'zero per-record failures' is the wrong clear condition. This is NOT spec row 17's acknowledged index-lag residual — the marker was seen and processed; no index lag is required.

**Interleaving:**

Devices: A (origin), B (receiver). B owns profiles P1, P2, both previously synced (syncVersion > 0).
1. A: resetSync — saves marker M (CloudKit save ✓; the zone subscription push fires to B immediately). A sets its gate. A begins deleteAllSyncedData: fetches the SyncedProfile ID snapshot S = {P1, P2, ...} (await).
2. B: handleRemoteNotification → performFullSync pass k. pullResetRequests returns M (query index happens to be fresh — 'may lag' permits fresh), classify = .process → watermark := M.requestedAt; gate_B := M.requestedAt; didReceiveSyncReset → handleSyncReset spawns re-push task T1. Rest of pass k: gate set ⇒ upserts only. So far exactly per spec rows 9/16.
3. B/T1: pushSyncedProfile(P1) — fetch + save succeed (server ack).
4. A: its modifyRecords(deleting: S) now executes → deletes P1 and P2 records. Deletes by recordID succeed regardless of B's newer save; B's acked push of P1 is silently undone.
5. B/T1: pushSyncedProfile(P2) — fetch → .unknownItem → creates fresh record → save ✓ (survives; A's delete already ran).
6. B/T1: zero per-record failures ⇒ per A3 it CLEARS gate_B, then continues into its follow-up performFullSync (pass k+1).
7. B pass k+1: pullResetRequests sees M → .skipAlreadyProcessed (watermark equal) ⇒ gate NOT re-set. pullProfiles → remoteIds = {P2} (non-empty, so A2 does not fire). handleSyncedProfiles: remoteIds non-empty AND gate not set ⇒ deletion reconciliation runs → P1 (syncVersion > 0) ∉ remoteIds → BlockedProfiles.deleteProfile(P1) on B. Local P1 and its FamilyActivitySelection destroyed; when A's re-push later restores P1, B recreates it with needsAppSelection = true — silent blocking failure.
Timing is realistic: A's wipe is 6 record types × ≥2 round-trips (seconds); B is push-notified the instant M is saved, and each of B's pushes is only 2 round-trips.

**Verifier's suggested fix (historical; superseded by #267):**

Do not treat push acks as evidence the device's data is in the zone. Add a pass-level rule: whenever pullResetRequests observes ANY within-TTL SyncResetRequest (regardless of classification — .process, .skipAlreadyProcessed, or .skipOwnOrigin), suppress deletion reconciliation for that pass. Markers persist ≤7 days (B4), so this keeps devices safe through the whole wipe + re-push window at the cost of deferring deletion propagation for ≤TTL after a reset — the exact trade the spec's safety asymmetry already endorses (optionally use a shorter 'settling period' constant than the full 7-day TTL). Keep the persistent gate as defense-in-depth for the marker-not-yet-visible window.

### interleavings-2 [breaks-safety] Row 6 is wrong: two near-simultaneous resets can mutually delete each other's markers, leaving a third device with zero protection against the re-push window

**Violated:**

Spec row 6 claims 'At least the later wipe's marker survives; devices process the newest surviving request … Converges.' False: each wipe's SyncResetRequest snapshot can include the other origin's marker (the reset-request type is wiped last, giving the other marker ample time to be visible), so both markers are deleted. Safety property violated on D; liveness (delivery to every device) violated too. The spec also underestimates the marker's role: it is not just 'selection-clearing intent' — it is the trigger that sets receivers' gates.

**Interleaving:**

Devices: A and B both run resetSync near-simultaneously; D is a third device with synced profiles.
1. A: saves M_A ✓, sets gate_A, wipes types in order (SyncedProfile first). SyncResetRequest is the LAST type wiped, so by the time A's wipe reaches it, B's marker has had seconds to become query-visible: A's fetch returns {M_A, M_B} → A deletes M_B (excluding only its own M_A, per A1).
2. B: saves M_B ✓, sets gate_B, wipes; its SyncResetRequest fetch returns {M_A} (M_A still exists — only B ever deletes it) → B deletes M_A (excluding only M_B, which A already deleted).
3. Zone state: ZERO reset markers; all SyncedProfile records wiped. A and B start their re-pushes (each protected locally by its own gate).
4. D: performFullSync. pullResetRequests → no records at all → no gate set, watermark untouched, nothing to classify. pullProfiles → remoteIds = A's partially re-pushed set (say 2 of 6 profiles) → non-empty, so A2 does not fire; no gate ⇒ deletion reconciliation runs → D deletes every local synced profile not among those 2 — near-total local wipe on D, selections lost on later recreation (needsAppSelection = true).
Also breaks liveness: neither reset's marker survives to reach D at all, violating 'resets reach every device that syncs within the TTL'.

**Verifier's suggested fix (historical; superseded by #267):**

deleteAllSyncedData must exclude ALL non-expired SyncResetRequest records, not just the current one. Expired markers are still collected (cooperative GC, B3, handles cleanup), so #202's cleanup goal is preserved. With any live marker guaranteed to survive, D would classify it .process, set its gate, and be protected.

### interleavings-3 [breaks-safety] Gate clear has no CAS/freshness semantics: a clean push belonging to reset N (or to a pre-reset pushLocalData) clears the gate that reset N+1 just set

**Violated:**

Safety property; rows 9 and 11 implicitly assume the gate set for a reset stays set until THAT reset's re-push completes — the spec's clear rule doesn't distinguish which reset (or which pre-reset push) a completing task belongs to. This is the exact hole the spec's rev-1→rev-2 change was meant to close, reopened one level up.

**Interleaving:**

Devices: B (receiver), C (origin of reset N+1). B earlier processed reset N; its re-push task T1 (multi-profile, slow) is still in flight.
1. B, pass k: processed N → watermark = N, gate_B = N.requestedAt, T1 spawned on the pushTask chain.
2. C: resetSync N+1 — saves M_{N+1}, sets gate_C, wipes the zone (deleting the records B's T1 already pushed), starts C's own re-push.
3. B, pass k+1 (manual 'Sync Now', or the subscription push from M_{N+1}): pullResetRequests sees M_{N+1} → .process → watermark := N+1; gate_B := (N+1).requestedAt; spawns T2 (chained after T1 on pushTask). pullProfiles: gate set ⇒ skip. Correct so far.
4. B/T1 finishes its last push with zero per-record failures → clears gate_B. The spec ('Cleared when a complete local re-push finishes with zero per-record failures') specifies no comparison against the current gate value, so the clear lands even though the gate now belongs to N+1. T1 then runs its follow-up performFullSync — which executes BEFORE T2, because T2 is chained after T1 on pushTask.
5. B, T1's follow-up pass: pullResetRequests → M_{N+1} → .skipAlreadyProcessed (watermark already N+1) ⇒ no gate. pullProfiles → C's partial re-push (non-empty), missing B's profiles (wiped in step 2) → reconciliation deletes B's local profiles. T2's later re-push cannot restore them — they are gone from B's local store.
Variant needing no second manual pass: a pushLocalData task spawned in the pass BEFORE the reset was known (pushes still in flight when the marker is processed) completes cleanly after the gate is set and clears a gate whose reset it knows nothing about — same outcome within a single marker-processing pass.

**Verifier's suggested fix (historical; superseded by #267):**

Minimum: clear the gate only via compare-and-swap (record the gate value when the push task starts; clear only if unchanged) and never let a push task that started before the gate was set clear it. Note this only narrows the race — finding 1 shows a correctly-attributed clean push still can't witness a concurrent wipe — so the pass-level 'within-TTL marker visible ⇒ no deletion reconciliation' rule from finding 1 is the actually-sound layer; CAS is defense-in-depth.

### interleavings-4 [breaks-safety] Newer-schema (read-only) profiles are skipped by every re-push but remain deletion-eligible: 'zero failures' clears the gate without their data being in the zone, and reconciliation then deletes them

**Violated:**

Safety property. Also invalidates the spec's stated constraint 'pushLocalData re-pushes ALL local profiles' (it doesn't — it filters isNewerSchemaVersion) and A3's invariant 'gate set ⇒ no deletions until my data is back in the zone': schema-filtered profiles are never re-pushed yet remain fully deletion-eligible in reconciliation.

**Interleaving:**

Devices: V (newer app, profile schema S+1) owns profile P; B (current app) holds a read-only local copy (handleSyncedProfiles sets profileSchemaVersion = S+1 and syncVersion = synced.version > 0 — SyncCoordinator.swift:157-159; isNewerSchemaVersion is true, BlockedProfiles.swift:712).
1. Any device runs resetSync: marker M saved, zone wiped (P's record deleted), origin re-push begins (P re-pushed late, or the origin isn't V and doesn't push P at all — pushLocalData/rePushLocalSyncedData filter `where !profile.isNewerSchemaVersion`, SyncCoordinator.swift:64 and :567).
2. B syncs: M → .process → gate set → handleSyncReset → rePushLocalSyncedData SKIPS P (schema filter) and pushes B's other profiles; zero per-record failures — a skipped profile is not a failure — ⇒ gate cleared.
3. B's follow-up pass: M → .skipAlreadyProcessed; pullProfiles → remoteIds = B's re-pushed profiles + origin's partial set, P absent → non-empty, no gate ⇒ reconciliation deletes local P — a profile the schema logic explicitly treats as authoritative-elsewhere and read-only.
4. If V later re-pushes P, B recreates it with needsAppSelection = true (selection loss). If the reset was issued precisely because V was retired/replaced, P is lost on B permanently — no device ever re-pushes it.
Note this is near-deterministic once the precondition (mixed app versions, which the project's V1/V2 branch strategy explicitly anticipates) holds: B's own clean re-push is what disarms its gate.

**Verifier's suggested fix (historical; superseded by #267):**

Exempt isNewerSchemaVersion profiles from deletion reconciliation entirely (treat them like syncVersion == 0 — they are read-only on this device, so this device must never infer their deletion). Alternatively/additionally, count schema-skipped profiles as non-clean for gate-clear purposes, but the reconciliation exemption is the correct-by-construction fix.

### interleavings-5 [weakens] Row 12 understates clock-skew impact: a poisoned watermark disarms the A3 gate for a later legitimate reset — data loss, not just a skipped selection-clear

**Violated:**

Spec row 12 claims the cost is only that 'a legit reset issued in that window could be skipped … self-heals; accepted.' Skipping a live reset does not merely miss its selection-clearing — it removes the A3 gate exactly when the destructive wipe/re-push window is open, leaving only A2, which does not cover the partial (non-empty) re-push state. The accepted row therefore accepts silent data loss, not a UX miss.

**Interleaving:**

1. Device C's clock is 30 days fast. C issues reset R1 (requestedAt = T+30d; per row 12, future requestedAt is treated as within TTL and processed). Every device processes R1 and advances its watermark to T+30d.
2. At real time T+2d, device A (correct clock) issues a legitimate reset R2 (requestedAt = T+2d): marker saved, zone wiped, A's re-push begins.
3. Device B syncs during R2's wipe/re-push window: pullResetRequests sees R2 → requestedAt < watermark → .skipAlreadyProcessed ⇒ NO gate set, no selection handling. pullProfiles → A's partial re-push (non-empty) → reconciliation deletes B's local profiles absent from the partial set — the full #195 outcome, on every device in the family with the poisoned watermark, for the whole 30-day skew window.

**Verifier's suggested fix (historical; superseded by #267):**

Cap the watermark advance at min(requestedAt, now + small slack) so a skewed request cannot poison future classification; the pass-level 'within-TTL marker visible ⇒ suppress deletion reconciliation' rule (finding 1) independently protects the wipe window regardless of watermark state, since R2's marker IS visible to B.

### interleavings-6 [nit] Gate-set vs watermark-advance write order is unspecified; row 8's guarantee silently depends on gate-first

**Violated:**

Spec row 8 ('crash before/during handleSyncReset … gate is persisted') — only true under gate-before-watermark ordering, which the spec never states.

**Interleaving:**

B6 says the watermark is advanced 'synchronously, in the same loop iteration' that classifies .process; A3 says the gate is set 'before invoking didReceiveSyncReset'. Neither pins their relative order. If an implementation writes watermark-then-gate and the process is killed between the two writes (both are synchronous SharedData/UserDefaults writes — a SIGKILL between adjacent statements is real even though it is outside the stated 'kills at await points' model, and UserDefaults persistence on kill is itself not guaranteed), relaunch classifies the request .skipAlreadyProcessed with NO persisted gate — row 8's 'but gate is persisted ⇒ no reconciliation' claim fails, and a partial (non-empty) pull then reconciles destructively.

**Verifier's suggested fix (historical; superseded by #267):**

Pin the order in the spec: set resetRePushPendingSince FIRST, then advance lastProcessedResetAt, then dispatch didReceiveSyncReset. A kill between the writes then leaves gate-set/watermark-old → the request is reprocessed (idempotent) instead of skipped-unprotected.

## Lens: crashRecovery — verdict: has-holes

**Verifier reasoning:**

> Human Meatbag — adversarial verification of /Users/rob/Downloads/git/family-foqos/docs/superpowers/specs/2026-07-02-reset-sync-safety-design.md against the pre-fix code in /Users/rob/Downloads/git/family-foqos/Foqos/CloudKit/ProfileSyncManager.swift, /Users/rob/Downloads/git/family-foqos/Foqos/CloudKit/SyncCoordinator.swift, /Users/rob/Downloads/git/family-foqos/Foqos/CloudKit/SyncModels.swift (SyncResetRequest:543), /Users/rob/Downloads/git/family-foqos/Foqos/CloudKit/SyncEventDelegate.swift, plus SharedData.swift (flock model), FoqosApp.swift (relaunch ordering: setModelContext → setupSync → performFullSync, and the modelContext-less background-notification path at line 352), and BlockedProfiles.deleteProfile (confirms reconcile-deletion also destroys sessions and the enforcement snapshot).
> 
> The design is a genuine improvement — A1 ordering kills the durable-landmine variant, A2 kills the primary empty-pull wipe, B1–B6 fix delivery/GC — but it does not meet the stated safety property. The root defect is one wrong witness used twice: the gate's clear condition treats push ACKNOWLEDGEMENT as proof that 'my data is back in the zone', while the spec's own stated assumption (and its Constraints section) says CKQuery reads lag writes arbitrarily. Finding 1 (gate cleared, immediate follow-up performFullSync pulls a stale index missing the just-re-pushed records, reconciliation deletes them) breaks rows 8/9 under the spec's own assumptions and is practically likely, since the follow-up pull runs milliseconds after the pushes. Finding 4 is the same root via pushTask chaining with no compare-and-clear. Finding 2 breaks row 13 and row 8's convergence claim through the crash-recovery lens specifically requested: the TTL backstop clears the gate at pull-time within a pass whose push runs after the pulls, so a device killed mid-re-push and left unlaunched >7 days reconcile-deletes its own only-copy data on relaunch (resets inherently make the pushing device the sole holder of any profile the origin hadn't pulled) — and the spec's test plan enshrines that deletion as a regression test. Finding 3 shows row 6's 'at least the later marker survives' is simply false for overlapping wipes (SyncResetRequest is wiped LAST in the type loop, maximizing mutual visibility), which also breaks delivery liveness. Findings 5–8 are narrower: the diagram's watermark-before-gate write order contradicts B6's own crash justification (real SIGKILL between two persisted writes, outside the stated await-only kill model); receiver-side clock skew lets one device GC a live marker for the whole family; unpushable isNewerSchemaVersion profiles can never satisfy the gate invariant; and 'clean run'/gate-read-freshness are implementation traps (notably the modelContext-nil background-launch path).
> 
> Answers to the specific lens questions: gate freshness is fine on MainActor iff read inside the reconciliation branch (pinned as finding 8b); SharedData's flock is moot for the new keys — only the main app's MainActor writes them, no extension runs sync code (verified by grep); disable/re-enable mid-window is safe because both markers persist in SharedData, EXCEPT that early-return paths must not clear the gate (finding 8a) and a >TTL disabled span collapses into finding 2; context.save failure after selection-clearing leaves the enforcement snapshot cleared while the model keeps selections — a pre-existing wart outside A1 scope and covered by exception (b), so noted but not filed. Acknowledged residuals I did NOT double-count: row 17 (marker-invisible index lag, punted to #219) is honestly labeled; B6's crash-skips-selection-clearing UX miss is real but is only a UX miss as claimed; row 4's 'Origin's SwiftData never touched' is inaccurate when clearAppSelections=true (handleSyncReset clears selections synchronously before the re-push Task), but the behavior is excepted by (b). Liveness otherwise holds: watermark+B4 deliver to every device within TTL, .expiredCollect is checked first so origins GC their own requests, and gate suppression is TTL-bounded — except where findings 3 and 6 destroy live markers.
> 
> Verdict: has-holes — four concrete breaks-safety interleavings, two of which (findings 1 and 2) are single-fault and realistic, and three of which falsify rows the spec claims converge (6, 8/9, 13). The good news: one repair closes most of it — clear the gate by read-verification (pulled remoteIds ⊇ local synced ids, reconcile with that same set) instead of push-ack, never wipe live foreign markers, set the gate before the watermark, and set it to max(now, requestedAt) with expiry deferring reconciliation to the pass after a clean push.

### crashRecovery-1 [breaks-safety] Gate cleared on push-ack, but follow-up pull is not read-your-writes: reconciliation deletes the profiles that were just re-pushed

**Violated:**

Safety property (local BlockedProfiles/SavedLocation deleted with an unexpired reset in flight — neither exception applies); spec rows 8 and 9 ('Converges', 'Closes the rev-1 hole'); A3's invariant 'gate set ⇒ no deletions until my data is back in the zone' — the spec forbids relying on query freshness for the marker (Constraints §3) but its gate-clear condition relies on exactly that for the re-pushed data.

**Interleaving:**

Devices A (origin) and B; B holds P1..Pn with syncVersion>0. (1) A: resetSync — saves marker, sets gate_A, wipes zone (P1..Pn CK records deleted), re-pushes its own set cleanly. (2) B pass 1: pullResetRequests classifies marker .process → watermark advanced, gate_B set → handleSyncReset spawns Task_R; pass 1's pulls skip reconciliation (gate set). (3) Task_R: rePushLocalSyncedData pushes P1..Pn, every save server-acked, zero failures → per A3 clears gate_B → immediately calls performFullSync (pass 2), exactly the ordering in the spec's data-flow diagram ('on zero failures: clear gate ──► performFullSync'). (4) Pass 2 pullProfiles runs milliseconds after the saves; the CKQuery index has not ingested P1..Pn yet (stated assumption: 'CKQuery results may lag writes arbitrarily'), so the result is A's profiles only — remoteProfileIds non-empty, gate_B cleared. (5) handleSyncedProfiles reconciliation: P1..Pn are local, syncVersion>0, absent from remoteIds → BlockedProfiles.deleteProfile each (SyncCoordinator.swift:186-197; deleteProfile also destroys all sessions and the SharedData snapshot, BlockedProfiles.swift:469-494). (6) Later passes re-pull the still-existing CK records and recreate husks via createLocalProfile with needsAppSelection=true — selections and session history lost even on a 'Keep App Selections' reset. Same interleaving applies verbatim to pushLocalData's end-of-pass gate clear followed by a manual 'Sync Now' seconds later, and to handleSyncedLocations.

**Verifier's suggested fix (historical; superseded by #267):**

Clear the gate by READ, not write-ack: while the gate is set, a pass that pulls remoteProfileIds ⊇ {local ids with syncVersion>0} (and the location analogue) clears the gate and reconciles using that same pulled set (deletions are then vacuous by construction); a clean push alone never clears. Equivalently: keep the gate through the follow-up pass and clear it only after a pull self-verifies the device's records are query-visible.

### crashRecovery-2 [breaks-safety] TTL backstop resumes reconciliation at pull-time, before the same pass's push — a device dark >7 days after processing a reset deletes its own only-copy profiles permanently

**Violated:**

Safety property (deletion not covered by exception (a) — the item was never deleted by a user — nor (b)); row 13's characterization ('suppression only delays deletions; the backstop bounds the delay' — it does not merely delay foreign deletions, it deletes this device's own never-re-pushed data); row 8's 'Converges'; test-plan item 2 bullet 4 ('non-empty partial + gate expired ⇒ missing one deleted (backstop regression)') encodes the destructive outcome as desired behavior.

**Interleaving:**

(1) Device B creates profile P and pushes it (syncVersion=1); origin A has not pulled P yet. (2) A: resetSync — marker saved, zone wiped: P's CK record is deleted, so B now holds the ONLY copy (inherent to reset-as-re-seed: every not-yet-pulled profile's remote copy is destroyed). A re-pushes its own set cleanly. (3) B syncs same day: marker .process → watermark advanced, gate_B set to requestedAt, handleSyncReset spawns re-push Task; app is killed at an await inside rePushLocalSyncedData before P is pushed — this is spec row 8's exact scenario, claimed 'Converges' via the persisted gate. (4) B's app is not launched for 8 days (> defaultTTL); no pass runs. (5) Day-8 relaunch: FoqosApp.onAppear → setupSync → performFullSync. pullResetRequests: marker now .expiredCollect (GC'd, not reprocessed). pullProfiles: remote = A's set, non-empty; gate_B is older than TTL ⇒ per A3 'ignored (reconciliation resumes) and cleared'. (6) Reconciliation deletes P locally. pushLocalData runs AFTER the pulls in the pass and no longer contains P. P is gone from every device and from CloudKit — unrecoverable. Aggravator: the gate is set to the request's requestedAt, not to when this device set it — a device that legitimately processes a 6.9-day-old reset gets a gate that expires ~2 hours later, so even a short crash-then-relaunch gap reproduces this. Same hole for a device whose one record persistently fails to push for 7 days (row 13): after the backstop, reconciliation deletes exactly the record that could not be pushed.

**Verifier's suggested fix (historical; superseded by #267):**

On gate expiry: skip deletion reconciliation for that pass, clear the gate only after that pass's clean full push (or the read-verified clear from finding 1, which subsumes this). Set the gate to max(now, requestedAt) — or simply now — so its TTL runs from when THIS device entered the window.

### crashRecovery-3 [breaks-safety] Row 6 is wrong: near-simultaneous resets can annihilate BOTH markers, leaving third devices ungated against the double-wiped zone

**Violated:**

Row 6 ('At least the later wipe's marker survives ... Converges'); safety property; liveness claim 'resets reach every device that syncs within the 7-day TTL'.

**Interleaving:**

Devices A, B, C. C pushed profile P_C yesterday; A and B have not pulled it. (1) t1: A saves marker m_A, sets gate_A. (2) t2: B saves marker m_B, sets gate_B. Both markers are query-visible by t3 (deleteAllSyncedData wipes SyncResetRequest LAST in its 6-type loop, leaving ample time). (3) A's wipe reaches the SyncResetRequest type at t5: fetch sees {m_A, m_B}, excludes only its own m_A (A1: 'Excluding only the current request') → deletes m_B. P_C's record was already deleted in the SyncedProfile pass. (4) B's wipe reaches SyncResetRequest at t6: sees {m_A} → deletes m_A. The zone now contains NO reset marker. (5) A and B re-push their local sets; neither contains P_C. (6) C's next pass: pullResetRequests returns nothing → no watermark change, no gate. pullProfiles: remote = A∪B, non-empty, no marker, no gate → reconciliation deletes P_C locally (syncVersion>0, absent). P_C's CK record was already wiped → lost everywhere, permanently. C also never receives either reset (delivery liveness broken). The spec's claim 'At least the later wipe's marker survives' only holds if the two resets are strictly serialized; row 6's own premise is 'near-simultaneously'.

**Verifier's suggested fix (historical; superseded by #267):**

Never wipe live foreign markers: deleteAllSyncedData should delete only SyncResetRequest records past TTL. Live foreign markers are inert to re-processing (B1 watermark) and are GC'd by B3, so leaving them costs nothing and each origin then processes the other's reset (idempotent double re-push, as row 6 already accepts).

### crashRecovery-4 [breaks-safety] No compare-and-clear on the gate: a pre-reset pushLocalData task straddling the wipe completes 'clean' and clears the gate a later reset set

**Violated:**

A3's clear condition and row 9's claim that the gate 'cleared only on clean re-push completion' closes the concurrent-pass hole — here a clean run of a PRE-reset push clears the POST-reset gate; safety property.

**Interleaving:**

Device B. (1) Pass 0 (no reset): pushLocalData synchronously snapshots P1..Pn and chains Task_P0 on pushTask (SyncCoordinator.swift:72-96); network is slow, Task_P0 pushes one record at a time. (2) Task_P0 pushes P1 (server-acked). Origin A now runs resetSync: marker saved, wipe's SyncedProfile fetch runs after P1's save → P1's record is deleted; P2..Pn haven't been pushed yet. (3) B pass 1: marker .process → watermark advanced, gate_B set → handleSyncReset chains Task_R AFTER Task_P0 on pushTask. Pass 1's pulls skip reconciliation (gate). (4) Task_P0 resumes: pushes P2..Pn, which land after the wipe fetch and survive. Task_P0 finishes with zero per-record failures → per A3 ('pushLocalData ... clear the flag on a clean run') it clears gate_B — while the zone lacks P1 and Task_R has not yet run. (5) User taps Sync Now (pass 2) before Task_R executes (MainActor interleaves at Task_R's awaits): pullProfiles → remote non-empty, missing P1; gate cleared → reconciliation deletes P1 locally. (6) Task_R then runs rePushLocalSyncedData, fetches profiles at execution time — P1 is already gone locally, its CK record wiped → never restored. Permanent loss of P1, its sessions, and its selection.

**Verifier's suggested fix (historical; superseded by #267):**

Compare-and-clear: capture the gate value (or an epoch counter) when the push task's snapshot is taken; on clean completion clear only if the gate still equals the captured value AND the snapshot was taken after the gate was set. The read-verified clear from finding 1 subsumes this entirely.

### crashRecovery-5 [weakens] Spec-internal contradiction: data-flow diagram advances the watermark BEFORE setting the gate, but B6's crash argument assumes the gate is 'already set'

**Violated:**

B6's stated justification vs the data-flow diagram ordering; under real (non-model) kills, the safety property.

**Interleaving:**

Per the diagram ('.process ⇒ advance watermark; set gate; didReceiveSyncReset'), pullResetRequests performs two separate persisted SharedData writes: (w1) lastProcessedResetAt := requestedAt, then (w2) resetRePushPendingSince := requestedAt. A SIGKILL/jetsam lands between w1 and w2 (no await separates them, so this is outside the stated 'kills at await points' model — but real kills do not respect that model, and B6 explicitly claims crash coverage: 'A crash between watermark advance and re-push completion is covered by the A3 gate (already set, persisted)', which is only true if the gate is written FIRST, contradicting the diagram). Relaunch while origin's re-push is still incomplete: pullResetRequests → .skipAlreadyProcessed (watermark persisted); gate is nil; pullProfiles returns the partial, non-empty zone → reconciliation deletes local not-yet-re-pushed profiles — the exact wipe A3 exists to prevent.

**Verifier's suggested fix (historical; superseded by #267):**

Pin the order: set resetRePushPendingSince BEFORE advancing lastProcessedResetAt (a kill between them then re-processes the reset idempotently — safe direction), ideally as one flock-guarded compound SharedData write. One sentence in A3/B6 fixes the spec.

### crashRecovery-6 [weakens] A receiver with a fast clock (>TTL skew) classifies a live reset expired: it skips protection for itself AND GC-deletes the marker for every other device

**Violated:**

B3's safety claim for cooperative GC; safety property and delivery liveness under a single skewed device.

**Interleaving:**

Devices A (origin), B (clock +8 days — user-set wrong date or dead RTC battery), C. (1) A resets: marker saved, zone wiped, A mid-re-push. (2) B syncs first: classify(now_B) → requestedAt appears 8 days old → .expiredCollect: B does not process (no gate, no watermark advance) and DELETES the live marker (B3: 'a past-TTL request is globally inert, so deletion is always safe' — false under clock skew). (3) B's same pass: pullProfiles returns A's partial re-push, non-empty; B has no gate → reconciliation deletes B's local profiles absent from the partial set. (4) C syncs later: the marker no longer exists → C never gates, never processes the reset, and reconciles against whatever partial state it pulls — same exposure; delivery liveness to C is broken. Row 12 considers only ORIGIN-side skew (future requestedAt); receiver-side fast clocks are unexamined and are strictly worse because .expiredCollect is checked first and destroys the marker for everyone.

**Verifier's suggested fix (historical; superseded by #267):**

GC foreign markers only when expired by a margin (e.g., 2×TTL); a merely-expired-looking foreign marker is skipped but not deleted. Optionally compare against the CKRecord's server-set creationDate instead of the client-written requestedAt to remove origin skew from classification.

### crashRecovery-7 [weakens] isNewerSchemaVersion profiles are excluded from every push but not from deletion reconciliation — the gate invariant is unsatisfiable for them

**Violated:**

Safety property (deletion during an unexpired reset, no exception applies); A3's invariant, which assumes a clean push restores everything the device holds.

**Interleaving:**

(1) Device B holds P_new received from newer-app device D: isNewerSchemaVersion=true, syncVersion>0 (set at SyncCoordinator.swift:159). (2) Any reset wipes P_new's CK record. (3) B processes the reset: gate set; rePushLocalSyncedData and pushLocalData both filter `!isNewerSchemaVersion` (SyncCoordinator.swift:64, 567), so P_new is never pushed; the push of the remaining set completes with zero failures → gate cleared ('my data is back in the zone' is structurally false for P_new). (4) D has not synced yet (offline for days, or retired). (5) B's next pass: remote non-empty, P_new absent → reconciliation deletes P_new locally (only syncVersion>0 is checked, SyncCoordinator.swift:189). If D never returns, the profile is lost permanently; if D returns, B gets a needsAppSelection husk.

**Verifier's suggested fix (historical; superseded by #267):**

Skip profiles with isNewerSchemaVersion in deletion reconciliation — they are read-only holdings whose authoritative copy lives on the newer device, symmetric with the existing push-side filter.

### crashRecovery-8 [nit] 'Clean run' and gate-read timing are underspecified — early-return paths must not count as zero-failure pushes, and the gate must be read at reconcile time

**Violated:**

A3's clear condition as written ('zero per-record failures') and test-plan item 4's coverage gap.

**Interleaving:**

(a) Background CloudKit push launches the app without the SwiftUI scene appearing: handleRemoteNotification → performFullSync runs before FoqosApp.onAppear ever calls syncCoordinator.setModelContext (FoqosApp.swift:227 vs 352), so pushLocalData hits `guard let context ... return` (SyncCoordinator.swift:51) having pushed nothing with zero recorded failures; same shape for `guard syncManager.isEnabled` after a mid-window sync disable, and for fetchProfiles throwing in rePushLocalSyncedData's outer catch. If 'zero per-record failures' is implemented as failures==0 ⇒ clear, the gate clears with nothing pushed and the next pass reconciles against the partial zone. (b) If a pass captures the gate value at pass start instead of reading SharedData inside handleSyncedProfiles/handleSyncedLocations at reconciliation time, a concurrent pass's freshly-set gate is missed; MainActor only guarantees freshness for a late read. Neither is pinned by the spec; test-plan item 4 covers zero-failure vs partial-failure but not zero-attempt, and item 2 doesn't pin read placement.

**Verifier's suggested fix (historical; superseded by #267):**

Define clean run as 'the full local synced set was enumerated and every record acked' (early returns are not clean); require the gate check to be a fresh SharedData read inside the reconciliation branch; add tests for the zero-attempt paths.

## Lens: cloudkit — verdict: has-holes

**Verifier reasoning:**

> Human Meatbag: I attacked the post-fix protocol through the CloudKit-semantics lens as instructed, verifying each mechanism against the actual code (ProfileSyncManager.swift, SyncCoordinator.swift, SyncModels.swift, SyncEventDelegate.swift) and the spec's data flow. The design's two big ideas — A2 (empty pull is never authoritative) and the persisted A3 gate — are sound as far as they go, and most table rows hold: rows 1-5 (origin failure ladder), row 8 (crash mid-re-push), row 10 (fresh device), row 18 (normal propagation), the B1/B6 watermark loop-prevention, and the marker-save-notification-vs-throttle interaction all survived attack. limitExceeded is also data-safe post-A1, exactly as claimed.
> 
> The load-bearing flaw is the gate's CLEAR condition. The spec's own rationale states the invariant as 'no deletions until my data is back in the zone', but the mechanism clears on 'my re-push reported zero failures' — a strictly weaker fact. Three independent gaps exploit the difference: (a) the origin's wipe deletes by recordID with no conflict check, and pushSyncedProfile reuses profileId-keyed record IDs, so a receiver's completed, 'clean' re-push is silently destroyed by a wipe still in flight (app suspension of the origin between marker save and wipe stretches this race from seconds to minutes — well within the stated fault model); (b) the receiver's own follow-up query is not read-your-writes (the spec concedes this), so fresh re-creates can be invisible while wipe deletions are ingested; (c) deterministically, isNewerSchemaVersion profiles are never pushed but have syncVersion>0, so 'zero failures' is satisfied while their absence from the rebuilt zone is guaranteed. In all three, the design's own follow-up performFullSync then reconciles ungated against a genuinely-partial zone and deletes local profiles/locations — including selection loss when clearRemoteAppSelections=false (outside exception (b)) and permanent loss of victim-only items (outside exception (a)). This falsifies the coverage claimed by rows 9 and 16.
> 
> Secondary breaks: row 6's 'at least the later wipe's marker survives' is provably wrong — SyncResetRequest is wiped last and each wipe excludes only its OWN marker, so overlapping resets mutually annihilate both markers, leaving third devices to reconcile ungated against a partially-reseeded zone. Row 17's accepted residual is real but its acceptance rationale is false on both counts: the window is an ordinary independent per-type index-lag combination (not a 'narrow inverted index order'), and the self-heal claim fails for victim-only data, which is permanently destroyed because reconciliation deletes it before the end-of-pass push. On liveness: a >400-record type makes the single-call wipe deterministically un-completable after the marker is already broadcast (selection-clearing fires family-wide on every retry), and cooperative GC trusts per-device clocks, so one fast-clocked device deletes a live marker for everyone — reintroducing the consume-before-delivery defect (#202.1) this design exists to fix.
> 
> Verdict: has-holes. The gating architecture is salvageable — the fixes are localized (evidence-based gate clearing, don't wipe other markers, chunked deletes, server-timestamp TTL) — but as specified the design still loses data under interleavings inside its own stated fault model, and four of its table rows (6, 9, 16, 17) claim outcomes the design does not deliver.

### cloudkit-1 [breaks-safety] Gate cleared on 'clean re-push' while the reset is still in flight — follow-up pass reconciles against a genuinely partial zone and mass-deletes local data

**Violated:**

SAFETY PROPERTY exceptions (a)/(b) — deletion during an in-flight reset with clearRemoteAppSelections=false; spec rows 9 and 16 ('gate still set ⇒ skips reconciliation' — here the gate is legitimately cleared by the design's own rule); A3's stated invariant 'gate set ⇒ no deletions until my data is back in the zone' — the mechanism actually tests 'my push once reported success', which is strictly weaker: the origin's still-in-flight wipe can delete the re-pushed records afterward, and skipped (newer-schema) profiles were never pushed at all.

**Interleaving:**

Devices: O (origin) and B, both hold profiles p1..p6 (syncVersion>0); B also holds B-only profile p7, pushed 2 days ago while O was offline (O never pulled it). Reset uses clearRemoteAppSelections=false. (1) O: resetSync saves marker M(T); iOS suspends O's app at the very next await (user locked the phone — milder than the crash-at-await the spec's model allows). (2) B receives the zone push fired by the marker save itself; last sync >5 min ago so the throttle passes. performFullSync#1: pullResetRequests sees M, classifies .process → watermark_B:=T, gate_B set, handleSyncReset spawns TaskA={rePush; performFullSync}. (3) Pass#1 pullProfiles sees the full pre-wipe set (O hasn't wiped yet); gate set → no reconciliation; fine. (4) TaskA rePushLocalSyncedData: p1..p7 fetch+save all succeed (records still exist — these are updates to the SAME record IDs, since pushSyncedProfile keys records by profileId). Zero failures → per spec A3/data-flow, gate_B is CLEARED. (5) O resumes 10 minutes later: sets gate_O, deleteAllSyncedData fetches SyncedProfile IDs {p1..p7} and modifyRecords-deletes them — deletes are by recordID with no change-tag check, so B's just-re-pushed records are destroyed too. Wipe finishes; O begins its sequential re-push and has saved only p1,p2,p3 so far. (6) B: user taps Sync Now (or a zone push arrives; throttle window has passed). performFullSync: pullResetRequests → M is .skipAlreadyProcessed (watermark_B=T). pullProfiles → the zone GENUINELY contains only {p1,p2,p3} — no index lag needed — remoteIds non-empty, gate_B cleared → reconciliation deletes local p4,p5,p6,p7 via BlockedProfiles.deleteProfile (session history cascades, selections destroyed). (7) O finishes re-pushing p4..p6; B recreates them with needsAppSelection=true → app selections silently lost on B although clearRemoteAppSelections was FALSE (outside exception (b)); p7 is PERMANENTLY lost — its CK record was wiped in step 5 and B deleted its only local copy in step 6, before B's end-of-pass push. Two independent variants reach the same state without app suspension: (i) own-write query-index lag — B's follow-up pull simply doesn't yet index B's fresh post-wipe re-creates (the spec itself disclaims query read-your-writes) while the wipe deletions are indexed → same partial remoteIds; (ii) deterministic, no race at all: a profile with isNewerSchemaVersion is skipped by rePushLocalSyncedData yet has syncVersion>0, so the 'zero per-record failures' clear condition is met while that profile is guaranteed absent from the rebuilt zone → the follow-up pass always deletes it locally. pushLocalData clearing the gate has the identical flaw (spec says both sites clear it).

**Verifier's suggested fix (historical; superseded by #267):**

Make the gate-clear condition evidence-based instead of push-based: clear only when, within a single pass, the pull's remoteProfileIds/remoteLocationIds are a superset of this device's own pushable local synced IDs (proof the zone currently reflects this device's data), optionally AND the triggering marker is older than a short quarantine so the origin's wipe has landed. Independently, exempt isNewerSchemaVersion profiles (never pushable by this device) from reconciliation deletion, since re-push can never restore them.

### cloudkit-2 [breaks-safety] Row 6 is wrong: two near-simultaneous resets can mutually annihilate BOTH markers, leaving a wiped/partially-reseeded zone with no reset marker for third devices

**Violated:**

Spec row 6 ('At least the later wipe's marker survives; devices process the newest surviving request... Converges') and the SAFETY PROPERTY — a third device deletes local BlockedProfiles/SavedLocation data during an in-flight reset with no marker visible, outside exceptions (a)/(b).

**Interleaving:**

(1) O1: resetSync saves M1(T1), begins deleteAllSyncedData — SyncResetRequest is the LAST type in the recordTypes array, so its fetch runs latest. (2) 30s later O2: resetSync saves M2(T2), begins its wipe. (3) O1's wipe reaches the SyncResetRequest type: fetch returns M1 (excluded, per A1 'excluding only the current request') and M2 (saved 30s earlier, index-visible) → deletes M2. (4) O2's wipe reaches SyncResetRequest: fetch returns M2 (excluded) and M1 → deletes M1. Both deletes are unconditional by recordID; both succeed. Zone now contains ZERO reset markers while both origins' wipes have destroyed all SyncedProfile/SyncedLocation records; both origins start re-pushing. (5) Device C, which had not synced since before step 1 (throttled/asleep) and holds C-only profile P (pushed last week, syncVersion>0; neither origin pulled it recently): performFullSync → pullResetRequests finds nothing → no gate, no watermark change. pullProfiles → zone contains O1's partially-re-pushed subset → remoteIds NON-EMPTY (A2 does not fire) → reconciliation deletes every C-local profile absent from the subset, including P. P's CK record was wiped in steps 1-2 and neither origin holds it, so P is permanently lost; C's copies of the origins' not-yet-re-pushed profiles are deleted and later recreated with needsAppSelection=true (selection loss even if both resets had clearRemoteAppSelections=false). Row 6's claimed outcome — 'At least the later wipe's marker survives' — is refuted: each wipe's reset-request fetch runs after the other's marker save whenever the two resetSync calls overlap within the wipe duration, which is exactly the 'near-simultaneous' case the row claims to handle.

**Verifier's suggested fix (historical; superseded by #267):**

Never delete other devices' within-TTL SyncResetRequest records in deleteAllSyncedData — exclude the whole SyncResetRequest type from the wipe (expired ones are already handled by cooperative GC B3, fresh ones by watermarks B1). Old markers being superseded is exactly what the watermark already handles; wiping them buys nothing and creates the annihilation window.

### cloudkit-3 [breaks-liveness] >400 records of one type makes the wipe deterministically fail AFTER the marker is live: reset can never complete, yet every attempt clears app selections family-wide

**Violated:**

LIVENESS ('resets reach every device' presumes a reset can complete; here the wipe never can) and the spec's partial-failure table, which analyzes limitExceeded only as a one-shot transient (rows 1, 3) — it never considers that a >400-record type makes the failure deterministic and repeatable after the marker is already broadcast.

**Interleaving:**

(1) Zone contains 450 records of one type — e.g. LegacySyncedSession from a long-time v1 user whose per-record legacy cleanup (ProfileSyncManager.cleanupLegacySessionsIfNeeded) was interrupted and never completed for this account. (2) O: resetSync(clearRemoteAppSelections: true) → saves marker M (zone push fans out to the family) → sets gate → deleteAllSyncedData: SyncedProfile deletes fine, then LegacySyncedSession: fetchAllRecords returns 450 IDs and ONE modifyRecords(saving:[], deleting: 450 IDs) is issued — over CloudKit's 400-records-per-operation limit → CKError.limitExceeded, atomic op deletes nothing, resetSync throws; UI shows 'Reset failed'. (3) Meanwhile every family device processes M (it is a genuine, unexpired marker): clears selectedActivity on ALL profiles, sets needsAppSelection=true, re-pushes, advances watermark. (4) User retries → new marker M2 → identical deterministic failure at the same type → selections cleared family-wide AGAIN; the wipe NEVER succeeds no matter how many retries. Data converges (rows 1/3 hold), but the reset operation itself is permanently un-completable while its most disruptive side effect fires on every attempt.

**Verifier's suggested fix (historical; superseded by #267):**

Chunk deleteAllSyncedData into batches of ≤400 record IDs per modifyRecords call (CK's documented guidance for limitExceeded is to split). The spec's constraint section already states the gates must hold 'even if a within-type partial state somehow occurred', so per-batch atomicity is compatible with the rest of the design.

### cloudkit-4 [breaks-safety] Row 17's residual is mischaracterized: the window is not 'narrow' and the self-heal claim is false for victim-only data (permanent loss, not selection loss)

**Violated:**

SAFETY PROPERTY (deletion during in-flight reset, outside exceptions (a)/(b)) — acknowledged by the spec as a residual, but row 17's claimed outcome ('narrow... self-heals: origin's re-push recreates them; app selections lost') is WRONG on both the window characterization and the recovery claim.

**Interleaving:**

(1) O: resetSync saves marker M, then wipes SyncedProfile. (2) B syncs during the wipe window: pullResetRequests queries the SyncResetRequest type — M is a seconds-old record whose query index has not ingested it yet, so B sees no reset (this does NOT require 'inverted index order' within one index, as the spec claims: SyncResetRequest and SyncedProfile live in independent per-type query indexes, and a fresh write lagging its index while a different type's deletions are already ingested is an ordinary, uncorrelated combination — not a narrow inversion). (3) B's pullProfiles returns a non-empty partial set (wipe deletions partially ingested) → no gate, no A2 → reconciliation deletes B's local profiles absent from the partial view — including B-only profile P (created on B, pushed, syncVersion>0, never pulled by O). (4) The spec's claimed self-heal — 'origin's re-push recreates them' — cannot apply to P: O never held P, and B deleted its only local copy in step 3, BEFORE B's end-of-pass pushLocalData runs, so nothing ever re-pushes it. P and its session history are permanently destroyed, and the same holds for B-only SavedLocations. The row's accepted-risk rationale ('narrow window, self-heals with only selection loss') rests on two false claims; the actual exposure is a common-case index-lag combination with permanent-loss outcomes.

**Verifier's suggested fix (historical; superseded by #267):**

If full tombstones stay out of scope (#219), at minimum bound the blast radius: treat a pull in which previously-seen remote IDs shrink by more than a small fraction (e.g. >50%) in a single pass as reset-suspect and skip deletion reconciliation for that pass (a shrink-rate circuit breaker), and re-word row 17 to state the true impact so the risk acceptance is honest.

### cloudkit-5 [weakens] TTL/GC decisions trust per-device wall clocks: one fast-clocked device GC-deletes a live marker for the whole family; a slow origin clock disables the receiver gate

**Violated:**

B3's claim 'a past-TTL request is globally inert, so deletion is always safe and self-healing'; LIVENESS ('resets reach every device that syncs within the 7-day TTL'); and, downstream, the SAFETY PROPERTY via the ungated wipe window in cases A/B.

**Interleaving:**

Case A: device D's clock is 7+ days fast (manually set date — a known failure mode on user devices). (1) O: resetSync saves M(requestedAt = real now), wipes, starts re-pushing. (2) D syncs first: classify(M) computes age = now_D - requestedAt > 7d → .expiredCollect → D DELETES the fresh marker (B3: 'a past-TTL request is globally inert, so deletion is always safe' — false: inertness is judged on each device's clock). (3) Devices B, C sync minutes later: no marker → no gate, no watermark → they hit the mid-re-push zone exactly as in finding 2 step 5: non-empty partial remoteIds → reconciliation deletes local profiles → needsAppSelection loss, permanent loss of any B/C-only items; additionally the reset never 'reaches every device' (liveness claim broken by consume-before-delivery, the very #202.1 defect this design set out to fix). Case B: origin's clock is 7+ days slow → every receiver classifies M .expiredCollect immediately, GCs it, and syncs through the wipe/re-seed window entirely ungated (deterministic row-17 exposure). Case C (sub-TTL skew): origin 6d23h slow → receivers process M but set gate := requestedAt, which their local clock judges ~1h from the 7-day cutoff — the gate's intended 7-day backstop shrinks to minutes if the re-push stalls. Row 12 considers only a future-skewed origin; none of these three cases appear in the tables.

**Verifier's suggested fix (historical; superseded by #267):**

Base expiry and GC on the server-assigned CKRecord.creationDate (systemFields metadata, immune to device clocks) instead of the client-written requestedAt, and only GC at a slack multiple (e.g. 2x TTL) of the processing cutoff so borderline skew can never delete a marker other devices still need. Set the receiver gate to the receiver's own now at processing time, not the origin's requestedAt.

### cloudkit-6 [nit] Spec does not pin gate-set before watermark-advance ordering

**Violated:**

B6's own justification ('covered by the A3 gate (already set, persisted)') — an assumption the spec never mandates.

**Interleaving:**

A3 says the gate is set 'before invoking didReceiveSyncReset'; B6 says the watermark advances 'synchronously, in the same loop iteration'; their mutual order is unspecified, yet B6's crash argument parenthetically assumes the gate is 'already set'. If an implementer writes watermark-first and the process dies between the two SharedData writes (outside the stated awaits-only fault model, but a real kill -9 can land between any two statements), relaunch classifies the request .skipAlreadyProcessed with NO gate → the device reconciles ungated against the mid-reset zone.

**Verifier's suggested fix (historical; superseded by #267):**

State explicitly in A3/B6: persist resetRePushPendingSince BEFORE advancing lastProcessedResetAt, so any kill between the two writes fails safe (reprocessing is idempotent; an unwatermarked-but-gated state is harmless, the reverse is not).

## Lens: specReview — verdict: has-holes

**Verifier reasoning:**

> Read the full spec (325 lines). It is unusually disciplined for cross-referencing (issue-number tags #195.x/#202.x match consistently between the Problem section and every later citation; interleaving-table rows 1-18 mostly track the mechanism definitions correctly; test-plan items 1-3 correctly mirror A2/A3's stated logic). No literal TODO/TBD/placeholder markers exist. However, systematic cross-checking of every interleaving row against the mechanism text, the data-flow diagram, and the test plan surfaced seven real issues: one edge case that plausibly defeats the core safety mechanism (A3 gate anchored to `requestedAt` rather than local processing time, so a device that comes back online near the 7-day TTL boundary gets almost no protected re-push window — exactly the deferred-sync scenario the rev-2 gate was introduced to cover); an underspecified 'zero per-record failures' clearing condition for a gate shared by two unrelated data types; a critical liveness-preventing ordering guarantee (B6, 'prevents an infinite reset loop') that has no dedicated test and falls outside the explicit code-inspection disclaimer's named scope; two interleaving-table rows (6, 7) that are asserted safe/harmless but have no corresponding test item and aren't listed under 'Out of scope' the way row 17 is; a documentation overclaim in 'Interplay' ('delivery reach every device exactly once') that directly contradicts A1's own text and B4's own caveat about a later reset's wipe deleting an unprocessed request; a diagram-vs-prose ambiguity about whether `performFullSync` runs unconditionally after a failed re-push (A4 says yes, the diagram's arrow notation reads as conditional, and row 13 requires the unconditional reading); and an undefined 'partial' vs 'complete' remote-set vocabulary used only in the interleaving table / test plan that has no counterpart in the Part A mechanism definitions (which only ever branch on `.isEmpty` and gate state, never on any partial/complete distinction). None of these amount to the design being fundamentally broken — the accepted-risk framing (row 17, the safety-asymmetry principle) is honest and mostly closes the loop — but several are more than nits: finding 1 in particular can reintroduce data loss + lost app selections through an everyday scenario (a device that was offline for most of the TTL window), not just the 'narrow' index-lag race the spec believes is its only residual risk.

### specReview-1 [breaks-safety] A3 gate is anchored to the request's requestedAt, not to local processing time — TTL backstop can expire the gate almost immediately for a delayed-sync device

**Violated:**

Contradicts the rev-2 rationale given at lines 134-140 ('the destructive window is not one pass wide... A persisted gate closes the whole window: process-crash-relaunch, concurrent manual sync, and the origin's own crash-after-wipe all land in gate set ⇒ no deletions until my data is back in the zone') and undermines the 'Converges' outcome claimed for row 8 (line 251), which assumes the gate stays set 'until pushLocalData completes cleanly.' Also widens interleaving row 17's 'narrow' residual-risk description (line 265) far beyond what the spec believes is the only unclosed gap.

**Interleaving:**

Quote (line 118): "Set (to the request's requestedAt) synchronously before the reset is applied". Quote (lines 128-129): "TTL backstop: a pending flag older than SyncResetRequest.defaultTTL (7 days) is ignored (reconciliation resumes) and cleared." Concrete scenario: Day 0, origin creates SyncResetRequest R1 (requestedAt = Day 0), TTL = 7 days. Device D is offline until Day 6.9. At Day 6.9, D runs pullResetRequests; classify(R1, watermark=.distantPast, now=Day6.9, ttl=7d) is not expired (age 6.9d < 7d) so returns .process. Per A3, D sets resetRePushPendingSince = R1.requestedAt = Day 0 (not Day 6.9). D begins clearing selections and re-pushing its (possibly many) local profiles/locations. At Day 7.0 — only ~2.4 hours later — the backstop check computes gate age = now - gate = 7.0d ≥ 7d TTL and treats the gate as expired, re-enabling deletion reconciliation, even though D's re-push may still be incomplete (network delay, large profile count, transient failures). A subsequent pull in that ~2.4-hour window with a non-empty-but-partial remote set (because D's own data isn't fully re-pushed yet) now reconciles instead of skipping, deleting D's own not-yet-repushed local profiles — exactly the catastrophic outcome (lost profiles, needsAppSelection=true, silent blocking failure) the whole design exists to prevent.

**Verifier's suggested fix (historical; superseded by #267):**

Clarify in the spec whether the gate should store requestedAt (as written) or local now-at-set-time; if requestedAt is intentional, add an interleaving row and a test case for a device processing a within-TTL-but-near-expiry request, and state the resulting (reduced) protection window explicitly.

### specReview-2 [weakens] "Zero per-record failures" clearing condition is underspecified: scope of 'per-record' and cross-type coupling of the single gate are both ambiguous

**Violated:**

No explicit row or test resolves either question; A3's own bullet (lines 124-127) is the only source and doesn't disambiguate.

**Interleaving:**

Quote (lines 124-127): "Cleared when a complete local re-push finishes with zero per-record failures — both rePushLocalSyncedData (the reset path) and pushLocalData (runs at the end of every full sync pass) report success/failure counts and clear the flag on a clean run. If some pushes failed, the flag stays set and the next pass's push retries." Two concrete ambiguities: (a) row 7 (line 250) describes 'GC delete of an expired other fails' as merely 'harmless; retried next pass' — but it is unspecified whether a failed cooperative-GC deletion counts toward the 'per-record failure' total that keeps the single shared gate set, i.e. whether an unrelated stale record from a third device could indefinitely block this device's own gate from clearing. (b) A3 states there is one resetRePushPendingSince flag gating both handleSyncedProfiles and handleSyncedLocations (line 122); if pushLocalData's profile-push succeeds cleanly but its location-push keeps failing (or vice versa), it is unspecified whether the single flag's clear condition requires BOTH to be clean (blocking the unrelated, successfully-pushed data type's reconciliation too) or clears per-type independently despite there being only one flag.

**Verifier's suggested fix (historical; superseded by #267):**

State explicitly that GC-delete failures never count toward the push failure total, and either split the gate per data-type or state explicitly that a failure in one type's push blocks reconciliation for both types until resolved.

### specReview-3 [weakens] B6's watermark-advance-before-Task-spawn ordering (the sole fix for the infinite reset loop) has no dedicated test and falls outside the named code-inspection scope

**Violated:**

Test-plan completeness relative to a fix explicitly framed (line 189 heading) as preventing 'an infinite reset loop' — the single most severe liveness property in Part B.

**Interleaving:**

B6 (lines 189-199) states this ordering is the *only* thing preventing an infinite reprocessing loop: "Advancing the watermark inside the async re-push Task instead would race the follow-up pass and can loop." The Test Plan's item 4 (lines 307-309) is titled 'Gate lifecycle' and only covers resetRePushPendingSince timing ("set-on-process happens before delegate dispatch; cleared on zero-failure push..."), never lastProcessedResetAt's ordering relative to the async Task spawn. Item 5 (lines 310-311) is a bare persistence round-trip test. The closing disclaimer (lines 313-314) says 'CloudKit-plumbing (resetSync ordering, pullResetRequests loop) verified by code inspection; their decisions are covered by the pure classifier (1) and gate lifecycle (4)' — B6's watermark-advance timing is neither a classify 'decision' (classify takes watermark as an input, per B5's signature, and never mutates it) nor part of item 4's gate-lifecycle scope, so it is left uncovered by both the automated tests and the explicit inspection commitment.

**Verifier's suggested fix (historical; superseded by #267):**

Add an explicit test-plan line (or an explicit code-inspection callout naming B6 specifically) asserting that lastProcessedResetAt is advanced synchronously in the same loop iteration, before the re-push Task is spawned.

### specReview-4 [weakens] Interleaving rows 6 and 7 are asserted safe but have no corresponding test item and are not listed under 'Out of scope' (unlike row 17)

**Violated:**

Test-plan completeness relative to the interleaving-analysis table's own claims (Part 'resetSync (origin)' and 'pullResetRequests (receiver)' sections).

**Interleaving:**

Row 6 (line 244): "Two devices reset near-simultaneously | Each saves its own marker first; each wipe deletes the other's marker... Converges." Row 7 (line 250): "GC delete of an expired other fails | Harmless; retried next pass." Row 17 (line 265) is the only interleaving explicitly carried into the 'Out of scope' section (line 318-319: "Per-delete tombstones for the general (non-reset) deletion path (interleaving #17 residual...)"). Rows 6 and 7 receive no equivalent treatment: they aren't exercised by any of the five test-plan items (1-5, lines 292-311), and they aren't declared out of scope, leaving their claimed outcomes ('Converges' / 'Harmless') asserted but unverified by either the pure-function tests or the stated code-inspection commitment.

**Verifier's suggested fix (historical; superseded by #267):**

Add a test (e.g. simulate two SyncResetRequest saves each excluding only its own recordID) for row 6's marker-survival logic, and either add a GC-delete-failure test or explicitly list row 7 as accepted/out of scope alongside row 17.

### specReview-5 [weakens] "Interplay" section overclaims delivery guarantee that A1 and B4 themselves qualify

**Violated:**

Line 207 vs. lines 104-105, 179-180, and row 6 (line 244) — direct textual tension between a summary claim and the mechanism's own documented exception.

**Interleaving:**

Quote (line 207): "B1–B6 make delivery reach every device exactly once and make cleanup independent of any single device's survival." This is stated unconditionally. But A1 (lines 104-105) states: "Excluding only the current request means older SyncResetRequest records are still wiped by the reset itself (part of #202 cleanup)" and B4 (lines 179-180) explicitly concedes within-TTL requests are "removed later by cooperative TTL-GC (B3) or by the next reset's wipe (A1)" — i.e. a second reset can delete a first reset's still-live, not-yet-delivered request. Row 6 (line 244) directly confirms the consequence: "Selection-clearing intent of a deleted marker can be lost — last reset wins; accepted." So delivery to every device is only guaranteed absent an intervening reset; the Interplay bullet states the guarantee without that qualification.

**Verifier's suggested fix (historical; superseded by #267):**

Qualify line 207, e.g. 'assuming no intervening reset wipes the request first (see A1, row 6)', or cross-reference the caveat explicitly.

### specReview-6 [weakens] Data-flow diagram's "on zero failures: clear gate ──► performFullSync" arrow is ambiguous about whether performFullSync runs unconditionally after re-push

**Violated:**

A4's prose (lines 142-146) and row 13's outcome (line 256) vs. the diagram notation (lines 215-216).

**Interleaving:**

Diagram (lines 215-216 and 226): "rePush(local) └► on zero failures: clear gate ──► performFullSync" and "pushLocalData ──► on zero failures: clear gate" (no explicit continuation after this one). A4 (lines 142-146) states unconditionally: "handleSyncReset already chains rePushLocalSyncedData then performFullSync inside one Task; keep that ordering" — implying performFullSync always follows re-push, success or not. Row 13 (line 256) requires this: "Re-push permanently failing... Upserts and pushes of other records continue throughout," which is only true if the follow-up performFullSync (and its own end-of-pass pushLocalData) keeps running despite failures. But the diagram's linear arrow places performFullSync directly after 'on zero failures: clear gate,' which a reader can plausibly interpret as performFullSync being gated behind the success branch rather than running regardless.

**Verifier's suggested fix (historical; superseded by #267):**

Redraw or annotate the diagram to show performFullSync as unconditional (e.g. 'rePush(local) [always]──► performFullSync; separately, on zero failures ⇒ clear gate') so it can't be read as conditional.

### specReview-7 [nit] "Partial" vs "complete" remote-set terminology used in the interleaving table and test plan is never defined by the Part A mechanism, which only branches on isEmpty + gate state

**Violated:**

Test-plan/interleaving-table vocabulary vs. mechanism definitions in Part A (A2/A3) — the algorithm has no 'partial vs complete' input, only isEmpty + gate.

**Interleaving:**

Test item 2 (lines 298-304) lists, as apparently distinct scenario categories: "non-empty partial + gate set ⇒ retained", "non-empty partial + gate expired... ⇒ deleted (backstop regression)", and "non-empty complete + no gate, one missing ⇒ that one deleted (regression guard)". Row 18 (line 266) likewise uses "Non-empty, complete, no reset, no gate, one profile deleted remotely." But Part A's actual mechanism definitions (A2, line 108-112, and A3, lines 114-132) only ever check `remoteProfileIds.isEmpty` and the gate's set/expired state — there is no code-level notion of a remote set being 'partial' vs 'complete' (both 'partial' and 'complete, one missing' describe the identical shape of data: a non-empty remote array missing one profile the local side has). The word 'complete' never appears anywhere in Part A's mechanism text at all.

**Verifier's suggested fix (historical; superseded by #267):**

Replace 'partial'/'complete' with the actual determining factor (gate state) in the test-plan bullets and row 18, or add a one-line definition in Part A clarifying that these terms describe test-scenario setup only, not an algorithmic input.
